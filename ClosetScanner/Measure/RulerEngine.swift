import SwiftUI
import RealityKit
import ARKit
import simd

/// High-precision point-to-point measurement using ARKit + LiDAR.
///
/// Accuracy strategy (see VALIDATION.md for the full rationale):
///   1. A fixed screen-center crosshair, so the user's aim is a single stable pixel.
///   2. Every AR frame we raycast from that pixel and push the world hit into a
///      rolling buffer.
///   3. When the user commits a point we take the **component-wise median** of the
///      last N samples. Median rejects the LiDAR's transient depth outliers far
///      better than a mean.
///   4. We report the sample **spread** (mean distance from the median) in mm as a
///      live confidence figure, so the operator knows when the reading is stable
///      enough to trust at 1/16" (≈1.6 mm).
final class RulerEngine: NSObject, ObservableObject, ARSessionDelegate {
    @Published var hasLiveHit = false
    @Published var pointA: SIMD3<Float>?
    @Published var pointB: SIMD3<Float>?
    @Published var liveDistanceMeters: Double?     // A → current crosshair, while placing B
    @Published var finalDistanceMeters: Double?    // committed A → B (raw, uncalibrated)
    @Published var confidenceMM: Double?           // spread of the committed sample
    @Published var liveSpreadMM: Double?           // current live stability of the crosshair
    @Published var trackingOK = false
    @Published var statusText = "Aim the crosshair at the first point, then tap Set A."

    weak var arView: ARView?

    private var sampleBuffer: [SIMD3<Float>] = []
    private let bufferCapacity = 60          // ~1 s at 60 fps
    private let commitWindow = 30            // samples averaged on commit
    private var markerAnchors: [AnchorEntity] = []

    // MARK: Session lifecycle

    /// LiDAR-backed measurement configuration: scene mesh, dense depth, planes.
    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }

    /// Pause when the tab disappears so this session doesn't fight the Scan
    /// tab's RoomPlan session for the camera.
    func pauseSession() {
        arView?.session.pause()
        sampleBuffer.removeAll()
        hasLiveHit = false
        liveSpreadMM = nil
        liveDistanceMeters = nil
    }

    func resumeSession() {
        guard let arView else { return }
        arView.session.run(Self.makeConfiguration())
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let arView else { return }

        // Use the view's own-bounds center (UIView.center is in *superview* space).
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard
            let query = arView.makeRaycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
            let hit = session.raycast(query).first
        else {
            // Drain the buffer while off-surface so a commit can't be backed by
            // stale samples from wherever the crosshair pointed last.
            sampleBuffer.removeFirst(min(3, sampleBuffer.count))
            DispatchQueue.main.async {
                self.hasLiveHit = false
                if self.sampleBuffer.isEmpty { self.liveSpreadMM = nil }
            }
            return
        }

        let t = hit.worldTransform.columns.3
        let p = SIMD3<Float>(t.x, t.y, t.z)
        sampleBuffer.append(p)
        if sampleBuffer.count > bufferCapacity { sampleBuffer.removeFirst() }

        let live = pointA.map { Double(simd_distance($0, p)) }
        let spread = currentSpreadMM()
        DispatchQueue.main.async {
            self.hasLiveHit = true
            self.liveDistanceMeters = live
            self.liveSpreadMM = spread
        }
    }

    /// Live stability of the crosshair: mean deviation of the recent buffer from
    /// its median, in mm. Low value == steady enough to commit at 1/16".
    private func currentSpreadMM() -> Double? {
        guard sampleBuffer.count >= 5 else { return nil }
        let recent = Array(sampleBuffer.suffix(commitWindow))
        let median = medianPoint(recent)
        return recent.map { Double(simd_distance($0, median)) }.reduce(0, +) / Double(recent.count) * 1000
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let ok: Bool
        switch camera.trackingState {
        case .normal: ok = true
        default: ok = false
        }
        // World positions shift when tracking degrades/relocalizes — samples
        // gathered before the change are no longer trustworthy.
        if !ok { sampleBuffer.removeAll() }
        DispatchQueue.main.async { self.trackingOK = ok }
    }

    // MARK: Commit points

    func setPointA() {
        guard let sample = stableSample() else {
            statusText = "Hold steady — not enough surface detected yet."
            return
        }
        clearMarkers()
        pointA = sample.point
        pointB = nil
        finalDistanceMeters = nil
        confidenceMM = sample.spreadMM
        statusText = String(format: "Point A set (±%.1f mm). Aim at B, then tap Set B.", sample.spreadMM)
        addMarker(at: sample.point, color: .systemGreen)
    }

    func setPointB() {
        guard let a = pointA else { setPointA(); return }
        guard let sample = stableSample() else {
            statusText = "Hold steady — not enough surface detected yet."
            return
        }
        pointB = sample.point
        finalDistanceMeters = Double(simd_distance(a, sample.point))
        confidenceMM = sample.spreadMM
        statusText = "Measured. Log it in Validation, or tap Reset."
        addMarker(at: sample.point, color: .systemRed)
        addLine(from: a, to: sample.point)
    }

    func reset() {
        pointA = nil
        pointB = nil
        finalDistanceMeters = nil
        liveDistanceMeters = nil
        confidenceMM = nil
        statusText = "Aim the crosshair at the first point, then tap Set A."
        clearMarkers()
    }

    // MARK: Sampling

    /// Robust committed sample: take the recent window, reject depth outliers
    /// using a median-absolute-deviation gate, then return the median of the
    /// inliers plus their residual spread in mm.
    private func stableSample() -> (point: SIMD3<Float>, spreadMM: Double)? {
        guard sampleBuffer.count >= 12 else { return nil }
        let recent = Array(sampleBuffer.suffix(commitWindow))

        // First-pass median and per-sample distance to it.
        let firstMedian = medianPoint(recent)
        let dists = recent.map { Double(simd_distance($0, firstMedian)) }

        // MAD-based inlier gate (floor of 2 mm so we never over-trim a steady hand).
        let mad = medianOfDoubles(dists)
        let threshold = max(0.002, mad * 3.0)
        let inliers = recent.filter { Double(simd_distance($0, firstMedian)) <= threshold }
        let use = inliers.count >= 5 ? inliers : recent

        let median = medianPoint(use)
        let spreadMM = use
            .map { Double(simd_distance($0, median)) }
            .reduce(0, +) / Double(use.count) * 1000
        return (median, spreadMM)
    }

    private func medianPoint(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
        func median(_ values: [Float]) -> Float {
            let s = values.sorted()
            let n = s.count
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        }
        return SIMD3<Float>(median(pts.map(\.x)), median(pts.map(\.y)), median(pts.map(\.z)))
    }

    private func medianOfDoubles(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    // MARK: AR annotations

    private func addMarker(at p: SIMD3<Float>, color: UIColor) {
        guard let arView else { return }
        let anchor = AnchorEntity(world: p)
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.006),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        markerAnchors.append(anchor)
    }

    private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        guard let arView else { return }
        let mid = (a + b) / 2
        let length = simd_distance(a, b)
        let anchor = AnchorEntity(world: mid)
        let beam = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.0025, 0.0025, length)),
            materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)]
        )
        anchor.addChild(beam)
        anchor.look(at: b, from: mid, relativeTo: nil)   // aligns local -Z toward B
        arView.scene.addAnchor(anchor)
        markerAnchors.append(anchor)
    }

    private func clearMarkers() {
        guard let arView else { return }
        markerAnchors.forEach { arView.scene.removeAnchor($0) }
        markerAnchors.removeAll()
    }
}
