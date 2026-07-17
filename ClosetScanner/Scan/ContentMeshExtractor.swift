import ARKit
import RoomPlan
import simd

/// A chunk of the LiDAR scene mesh, in world space, that survived architecture
/// filtering — i.e. the closet's *contents* (clothes, bins, shelving clutter).
///
/// RoomPlan's `CapturedRoom.objects` only lists furniture it can classify
/// (tables, storage units, beds…), which misses almost everything actually in
/// a closet. The scene mesh sees every physical surface, so filtering out the
/// architecture leaves the real contents regardless of what they are.
struct ContentMesh {
    let vertices: [SIMD3<Float>]
    let indices: [Int32]        // triangles, 3 indices per face
}

/// Raw per-anchor mesh data copied out of the ARSession the moment Finish is
/// tapped — RoomPlan tears the session down during post-processing, so the
/// snapshot has to happen before `stop()`.
struct MeshSnapshot {
    struct Anchor {
        let vertices: [SIMD3<Float>]      // world space
        let faces: [Int32]                // 3 per triangle
        let classifications: [UInt8]?     // ARMeshClassification raw value, per face
    }
    let anchors: [Anchor]
}

enum ContentMeshExtractor {

    // Sensitivity tunables. A mesh triangle counts as *contents* unless it is
    // within `wallClearance` of a captured wall/door/window/opening/floor
    // surface, or hugs the floor/ceiling, or falls outside the footprint.
    //
    // Maximum-sensitivity preset: clearances pushed to (and past) the noise
    // floor so essentially everything that isn't the architecture itself is
    // kept — wall-hugging clothes, flat shoes, thin shelf items. Expect some
    // wall/floor mesh skin to survive as fake contents; the LiDAR skin sits
    // ~1–2 cm off the true surface, so this trades noise for recall.
    private static let wallClearance: Float = 0.02     // 2 cm — the leak threshold
    private static let floorClearance: Float = 0.01    // 1 cm — keeps the flattest items
    private static let ceilingClearance: Float = 0.03
    private static let bboxInset: Float = 0.01         // fallback clip when no closed footprint exists

    // Protrusion filter tunables (dense point-cloud path, `extractContentPoints`).
    // Contents are positive space that stands *off* the architecture, so we drop
    // only a thin skin around each wall/floor/ceiling and keep everything else
    // inside the closet volume. A flat painted wall's depth samples sit within a
    // couple cm of its fitted plane and get dropped; a bumpy garment surface
    // scatters well past `pointWallSkin`, so most of it survives even when
    // RoomPlan fit the "wall" to the front face of packed clothes.
    private static let pointWallSkin: Float = 0.03       // 3 cm around vertical planes
    private static let pointRectMargin: Float = 0.10     // tolerance past a plane's edges
    private static let pointFloorStandoff: Float = 0.04  // keep points ≥4 cm above the floor (shoes)
    private static let pointCeilingClearance: Float = 0.05
    private static let pointContentReach: Float = 0.10   // keep points this far outside the wall bbox

    // MARK: Snapshot

    /// Copies every `ARMeshAnchor` out of the session's current frame.
    /// (RoomPlan runs LiDAR scene reconstruction internally; the accumulated
    /// mesh anchors are visible through the shared `arSession`.)
    static func snapshot(from session: ARSession) -> MeshSnapshot {
        let meshAnchors = (session.currentFrame?.anchors ?? []).compactMap { $0 as? ARMeshAnchor }
        let anchors: [MeshSnapshot.Anchor] = meshAnchors.compactMap { anchor in
            let g = anchor.geometry
            guard g.vertices.format == .float3 else { return nil }

            // Vertices → world space. Read as 3 packed floats: the buffer is
            // tightly packed float3 (12 bytes), not SIMD3's padded 16.
            var verts = [SIMD3<Float>]()
            verts.reserveCapacity(g.vertices.count)
            let vBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
            for i in 0..<g.vertices.count {
                let f = vBase.advanced(by: i * g.vertices.stride).assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4<Float>(f[0], f[1], f[2], 1)
                verts.append(SIMD3(world.x, world.y, world.z))
            }

            // Triangle indices (uint16 or uint32 depending on mesh size).
            let indexCount = g.faces.count * g.faces.indexCountPerPrimitive
            var idx = [Int32]()
            idx.reserveCapacity(indexCount)
            let fBase = g.faces.buffer.contents()
            for i in 0..<indexCount {
                switch g.faces.bytesPerIndex {
                case 2:
                    idx.append(Int32(fBase.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee))
                default:
                    idx.append(Int32(fBase.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee))
                }
            }

            // Per-face classification, when the session provides it.
            var cls: [UInt8]?
            if let c = g.classification, c.count == g.faces.count {
                let cBase = c.buffer.contents().advanced(by: c.offset)
                var arr = [UInt8]()
                arr.reserveCapacity(c.count)
                for i in 0..<c.count {
                    arr.append(cBase.advanced(by: i * c.stride).assumingMemoryBound(to: UInt8.self).pointee)
                }
                cls = arr
            }

            return MeshSnapshot.Anchor(vertices: verts, faces: idx, classifications: cls)
        }
        return MeshSnapshot(anchors: anchors)
    }

    // MARK: Filtering

    /// Keeps the triangles that are inside the closet but not part of its
    /// architecture. Returns one mesh per anchor (empty anchors dropped).
    static func extractContents(from snapshot: MeshSnapshot,
                                room: CapturedRoom,
                                metrics: ClosetMetrics?) -> [ContentMesh] {
        guard !room.walls.isEmpty else { return [] }   // no bounds to clip against

        // Architecture planes: point is "on" one if, in the surface's local
        // frame, it lies within the rect (plus clearance) and close to z = 0.
        struct Plane { let inv: simd_float4x4; let hx: Float; let hy: Float }
        let allSurfaces = room.walls + room.doors + room.windows + room.openings + room.floors
        let planes = allSurfaces.map {
            Plane(inv: $0.transform.inverse, hx: $0.dimensions.x / 2, hy: $0.dimensions.y / 2)
        }

        // Vertical band + horizontal clip from the wall bounding box.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for wall in room.walls {
            let hw = wall.dimensions.x / 2, hh = wall.dimensions.y / 2
            for sx in [-hw, hw] {
                for sy in [-hh, hh] {
                    let c = wall.transform * SIMD4<Float>(sx, sy, 0, 1)
                    lo = simd_min(lo, SIMD3(c.x, c.y, c.z))
                    hi = simd_max(hi, SIMD3(c.x, c.y, c.z))
                }
            }
        }
        let footprint = metrics?.footprint

        func isArchitecture(_ p: SIMD3<Float>) -> Bool {
            for plane in planes {
                let local = plane.inv * SIMD4<Float>(p, 1)
                if abs(local.x) < plane.hx + wallClearance,
                   abs(local.y) < plane.hy + wallClearance,
                   abs(local.z) < wallClearance {
                    return true
                }
            }
            return false
        }

        func isInsideCloset(_ p: SIMD3<Float>) -> Bool {
            guard p.y > lo.y + floorClearance, p.y < hi.y - ceilingClearance else { return false }
            if let poly = footprint {
                return ClosetMetrics.polygonContains(poly, SIMD2(p.x, p.z))
            }
            return p.x > lo.x + bboxInset && p.x < hi.x - bboxInset
                && p.z > lo.z + bboxInset && p.z < hi.z - bboxInset
        }

        // ARMeshClassification.floor = 2, .ceiling = 3 — catches sloped or
        // uncaptured ceilings the surface list doesn't cover.
        let horizontalArchitecture: Set<UInt8> = [2, 3]

        var out: [ContentMesh] = []
        for anchor in snapshot.anchors {
            var kept: [Int32] = []
            let faceCount = anchor.faces.count / 3
            for f in 0..<faceCount {
                let i0 = Int(anchor.faces[f * 3])
                let i1 = Int(anchor.faces[f * 3 + 1])
                let i2 = Int(anchor.faces[f * 3 + 2])
                guard i0 < anchor.vertices.count, i1 < anchor.vertices.count, i2 < anchor.vertices.count
                else { continue }
                let centroid = (anchor.vertices[i0] + anchor.vertices[i1] + anchor.vertices[i2]) / 3

                guard isInsideCloset(centroid) else { continue }
                if let cls = anchor.classifications, horizontalArchitecture.contains(cls[f]) { continue }
                if isArchitecture(centroid) { continue }

                kept.append(contentsOf: [anchor.faces[f * 3], anchor.faces[f * 3 + 1], anchor.faces[f * 3 + 2]])
            }
            if !kept.isEmpty {
                out.append(compacted(vertices: anchor.vertices, indices: kept))
            }
        }
        return out
    }

    // MARK: Protrusion filter (dense point cloud)

    /// Keeps the accumulated LiDAR depth points that are inside the closet but
    /// stand off its architecture — the positive-space counterpart to
    /// `extractContents`. Unlike the mesh path this never trusts a per-face
    /// classification (a dense depth cloud has none) and never clips to the
    /// footprint polygon, so shoes the mesh merged into the floor and clothes
    /// RoomPlan buried in the back wall both survive.
    static func extractContentPoints(points: [SIMD3<Float>],
                                     room: CapturedRoom,
                                     metrics: ClosetMetrics?) -> [SIMD3<Float>] {
        guard !room.walls.isEmpty, !points.isEmpty else { return [] }

        // Vertical architecture only — floor/ceiling are handled by the height
        // band below, so a low object resting on the floor is never mistaken
        // for the floor plane itself.
        struct Plane { let inv: simd_float4x4; let hx: Float; let hy: Float }
        let verticalSurfaces = room.walls + room.doors + room.windows + room.openings
        let planes = verticalSurfaces.map {
            Plane(inv: $0.transform.inverse, hx: $0.dimensions.x / 2, hy: $0.dimensions.y / 2)
        }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for wall in room.walls {
            let hw = wall.dimensions.x / 2, hh = wall.dimensions.y / 2
            for sx in [-hw, hw] {
                for sy in [-hh, hh] {
                    let c = wall.transform * SIMD4<Float>(sx, sy, 0, 1)
                    lo = simd_min(lo, SIMD3(c.x, c.y, c.z))
                    hi = simd_max(hi, SIMD3(c.x, c.y, c.z))
                }
            }
        }

        func isWallSkin(_ p: SIMD3<Float>) -> Bool {
            for plane in planes {
                let local = plane.inv * SIMD4<Float>(p, 1)
                if abs(local.z) < pointWallSkin,
                   abs(local.x) < plane.hx + pointRectMargin,
                   abs(local.y) < plane.hy + pointRectMargin {
                    return true
                }
            }
            return false
        }

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(points.count)
        for p in points {
            // Above the floor skin, below the ceiling.
            guard p.y > lo.y + pointFloorStandoff, p.y < hi.y - pointCeilingClearance else { continue }
            // Inside the wall bbox, inflated outward so clothes sitting behind a
            // wall RoomPlan fit to their front face are still kept.
            guard p.x > lo.x - pointContentReach, p.x < hi.x + pointContentReach,
                  p.z > lo.z - pointContentReach, p.z < hi.z + pointContentReach else { continue }
            if isWallSkin(p) { continue }
            out.append(p)
        }
        return out
    }

    /// Drops unreferenced vertices and remaps indices.
    private static func compacted(vertices: [SIMD3<Float>], indices: [Int32]) -> ContentMesh {
        var remap = [Int32: Int32]()
        var outVerts = [SIMD3<Float>]()
        var outIdx = [Int32]()
        outIdx.reserveCapacity(indices.count)
        for i in indices {
            if let mapped = remap[i] {
                outIdx.append(mapped)
            } else {
                let mapped = Int32(outVerts.count)
                remap[i] = mapped
                outVerts.append(vertices[Int(i)])
                outIdx.append(mapped)
            }
        }
        return ContentMesh(vertices: outVerts, indices: outIdx)
    }
}
