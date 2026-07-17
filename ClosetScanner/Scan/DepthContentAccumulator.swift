import ARKit
import simd
import CoreVideo

/// Accumulates a dense world-space point cloud from per-frame LiDAR `sceneDepth`
/// across a RoomPlan scan.
///
/// RoomPlan's reconstructed `ARMeshAnchor` mesh is decimated and tends to
/// shrink-wrap soft, complex geometry — hanging clothes get absorbed into the
/// back wall, low shoes into the floor — so the subtractive mesh filter loses
/// exactly the contents we care about. The raw per-pixel depth map keeps those
/// surfaces; sampling it over the whole scan and folding the points into a voxel
/// set dedupes overlapping views and bounds memory.
final class DepthContentAccumulator {

    /// Voxel leaf size — points inside one cube collapse to a single sample.
    private let leaf: Float = 0.015             // 1.5 cm
    /// Only trust depth pixels at/above this confidence (0 low, 1 med, 2 high).
    private let minConfidence: UInt8 = 1        // medium and high
    /// Skip pixels to keep per-frame cost down; 2 → a quarter of the depth map.
    private let pixelStride = 2
    /// Reject implausible depths (m): holes/reflections read as 0 or very large.
    private let minDepth: Float = 0.15
    private let maxDepth: Float = 5.0
    /// Hard cap on retained voxels so a long scan can't grow unbounded.
    private let maxVoxels = 600_000

    private var voxels = Set<Int64>()
    private let queue = DispatchQueue(label: "com.closetscanner.depth-accumulator")

    /// The data needed from one `ARFrame`, copied on the caller's thread so we
    /// never retain the frame itself — its pixel buffers belong to a small pool
    /// ARKit recycles, and holding them stalls the session.
    struct Sample {
        let depth: [Float]
        let confidence: [UInt8]
        let width: Int
        let height: Int
        let fx: Float, fy: Float, cx: Float, cy: Float    // intrinsics at depth res
        let cameraToWorld: simd_float4x4
    }

    /// Pull a `Sample` out of the current frame on the calling thread. Returns
    /// nil until the LiDAR depth stream is available.
    static func sample(from frame: ARFrame) -> Sample? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var depth = [Float](repeating: 0, count: w * h)
        for r in 0..<h {
            let row = base.advanced(by: r * rowBytes).assumingMemoryBound(to: Float.self)
            for c in 0..<w { depth[r * w + c] = row[c] }
        }

        // Confidence is a separate UInt8 buffer at the same resolution; if the
        // frame lacks it, treat every pixel as trustworthy.
        var confidence = [UInt8](repeating: 2, count: w * h)
        if let confMap = sceneDepth.confidenceMap {
            CVPixelBufferLockBaseAddress(confMap, .readOnly)
            if let cbase = CVPixelBufferGetBaseAddress(confMap) {
                let crow = CVPixelBufferGetBytesPerRow(confMap)
                for r in 0..<h {
                    let row = cbase.advanced(by: r * crow).assumingMemoryBound(to: UInt8.self)
                    for c in 0..<w { confidence[r * w + c] = row[c] }
                }
            }
            CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
        }

        // Intrinsics are expressed for the full camera image; scale them to the
        // (smaller) depth-map resolution. Both are in the sensor's native
        // landscape orientation, so no rotation is needed regardless of UI.
        let intr = frame.camera.intrinsics
        let imageRes = frame.camera.imageResolution
        let sx = Float(w) / Float(imageRes.width)
        let sy = Float(h) / Float(imageRes.height)

        return Sample(depth: depth, confidence: confidence, width: w, height: h,
                      fx: intr[0][0] * sx, fy: intr[1][1] * sy,
                      cx: intr[2][0] * sx, cy: intr[2][1] * sy,
                      cameraToWorld: frame.camera.transform)
    }

    /// Unproject a sample to world space and fold it into the voxel set. Runs on
    /// a private queue so the ~10 Hz sampling never blocks the main thread.
    func add(_ s: Sample) {
        queue.async {
            guard self.voxels.count < self.maxVoxels else { return }
            for r in stride(from: 0, to: s.height, by: self.pixelStride) {
                for c in stride(from: 0, to: s.width, by: self.pixelStride) {
                    let i = r * s.width + c
                    guard s.confidence[i] >= self.minConfidence else { continue }
                    let d = s.depth[i]
                    guard d > self.minDepth, d < self.maxDepth else { continue }
                    // CV pinhole model (z forward, y down) → ARKit camera space
                    // (y up, z toward the viewer), then camera → world.
                    let x = (Float(c) - s.cx) / s.fx * d
                    let y = (Float(r) - s.cy) / s.fy * d
                    let world = s.cameraToWorld * SIMD4<Float>(x, -y, -d, 1)
                    self.voxels.insert(self.voxelKey(world.x, world.y, world.z))
                }
                if self.voxels.count >= self.maxVoxels { return }
            }
        }
    }

    /// World-space centers of every occupied voxel.
    func pointCloud() -> [SIMD3<Float>] {
        queue.sync {
            voxels.map { key in
                let (ix, iy, iz) = unpack(key)
                return SIMD3<Float>((Float(ix) + 0.5) * leaf,
                                    (Float(iy) + 0.5) * leaf,
                                    (Float(iz) + 0.5) * leaf)
            }
        }
    }

    var count: Int { queue.sync { voxels.count } }

    func reset() { queue.sync { voxels.removeAll(keepingCapacity: true) } }

    // MARK: Voxel key packing

    /// Pack three 21-bit signed voxel indices into one Int64 (±1M voxels/axis,
    /// ~±15 km at a 1.5 cm leaf — far beyond any room).
    private func voxelKey(_ x: Float, _ y: Float, _ z: Float) -> Int64 {
        let ix = Int64((x / leaf).rounded(.down))
        let iy = Int64((y / leaf).rounded(.down))
        let iz = Int64((z / leaf).rounded(.down))
        let mask: Int64 = 0x1F_FFFF                 // 21 bits
        return ((ix & mask) << 42) | ((iy & mask) << 21) | (iz & mask)
    }

    private func unpack(_ key: Int64) -> (Int64, Int64, Int64) {
        func signed(_ v: Int64) -> Int64 {
            let x = v & 0x1F_FFFF
            return x >= 0x10_0000 ? x - 0x20_0000 : x    // sign-extend 21 bits
        }
        return (signed(key >> 42), signed(key >> 21), signed(key))
    }
}
