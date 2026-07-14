import RoomPlan
import simd

/// Overall closet dimensions derived from the captured walls.
///
/// We build an axis-aligned bounding box (AABB) over every wall corner. RoomPlan
/// orients the room's coordinate frame to gravity, so `height` (Y) is reliable.
/// For a roughly rectangular closet scanned square-on, the X/Z extents give
/// width and depth. (For a closet rotated relative to the world axes the AABB
/// can slightly over-report width/depth — for exact spans use the Ruler tab,
/// and see the per-wall lengths below.)
struct RoomDimensions {
    let width: Float   // meters, X extent
    let length: Float  // meters, Z extent (depth)
    let height: Float  // meters, Y extent
    let wallLengths: [Float]   // individual wall spans, longest first (meters)

    init?(from room: CapturedRoom) {
        let walls = room.walls
        guard !walls.isEmpty else { return nil }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var lengths: [Float] = []

        for wall in walls {
            lengths.append(wall.dimensions.x)
            let hw = wall.dimensions.x / 2      // half width  (along local X)
            let hh = wall.dimensions.y / 2      // half height (along local Y)
            let localCorners = [
                SIMD4<Float>(-hw, -hh, 0, 1),
                SIMD4<Float>( hw, -hh, 0, 1),
                SIMD4<Float>(-hw,  hh, 0, 1),
                SIMD4<Float>( hw,  hh, 0, 1),
            ]
            for corner in localCorners {
                let world = wall.transform * corner
                let p = SIMD3<Float>(world.x, world.y, world.z)
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }

        let extent = hi - lo
        width = extent.x
        height = extent.y
        length = extent.z
        wallLengths = lengths.sorted(by: >)
    }
}
