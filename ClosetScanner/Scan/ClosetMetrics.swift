import RoomPlan
import simd

/// User-selected capture mode. Auto resolves to reach-in or walk-in after the
/// scan (see `resolveKind`), and the user can always override by picking a mode.
enum ClosetMode: String, CaseIterable, Identifiable {
    case reachIn = "Reach-in"
    case walkIn = "Walk-in"
    case autoDetect = "Auto"

    var id: String { rawValue }

    /// Shown on the start screen under the picker.
    var detail: String {
        switch self {
        case .reachIn:
            return "A shallow closet you scan from the doorway. Reported as width × depth × height."
        case .walkIn:
            return "A small room you stand inside — L/U shapes, returns, and angled corners supported. Reported as a floor plan with per-wall lengths."
        case .autoDetect:
            return "Scans first, then decides: if you were inside the floor outline (or it's room-sized), it's a walk-in."
        }
    }

    /// Live coaching text while scanning.
    var coaching: String {
        switch self {
        case .reachIn:
            return "Stand at the doorway. Slowly pan across the back wall, both side walls, the floor, and the ceiling."
        case .walkIn:
            return "Walk slowly around the inside. Keep walls in view and cover every corner, return, and the doorway."
        case .autoDetect:
            return "Pan slowly across every wall, the floor, and the ceiling. For a walk-in, circle the interior."
        }
    }
}

/// What the scan actually was, after auto-detection or manual override.
enum ResolvedClosetKind {
    case reachIn, walkIn

    var title: String {
        switch self {
        case .reachIn: return "Reach-in closet"
        case .walkIn: return "Walk-in closet"
        }
    }
}

/// Everything we derive from a captured room: bounding box, per-wall segments
/// (ordered around the footprint when possible), doors/windows/openings, the
/// floor footprint polygon and its area, and completeness diagnostics.
///
/// Footprint sources, in preference order:
///   1. RoomPlan's captured floor polygon (`polygonCorners`, iOS 17) — handles
///      L/U shapes and angled corners directly.
///   2. Chaining the wall segments end-to-end (tolerance 25 cm). If the chain
///      doesn't return to its start the outline is "open" — expected for a
///      reach-in scanned from outside, a warning sign for a walk-in.
struct ClosetMetrics {
    struct Wall: Identifiable {
        let id: Int                 // 1-based label, matches the floor plan
        let a: SIMD2<Float>         // world XZ endpoints
        let b: SIMD2<Float>
        let lengthM: Float
        let heightM: Float
    }

    struct Portal: Identifiable {
        enum Kind: String { case door = "Door", window = "Window", opening = "Opening" }
        let id: Int
        let kind: Kind
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        let widthM: Float
    }

    let walls: [Wall]
    let portals: [Portal]

    // Axis-aligned bounding box over all wall corners (meters).
    let bboxWidthM: Float    // X extent
    let bboxDepthM: Float    // Z extent
    let bboxHeightM: Float   // Y extent

    // Per-wall height range; differs under a sloped ceiling.
    let minWallHeightM: Float
    let maxWallHeightM: Float

    /// Closed floor outline in world XZ, when one could be established.
    let footprint: [SIMD2<Float>]?
    /// Shoelace area of the footprint (m²); nil when no closed outline exists.
    let footprintAreaM2: Double?
    /// Whether the wall chain (or captured floor) forms a closed loop.
    let outlineClosed: Bool
    /// Wall segments that couldn't be connected into the outline chain.
    let unconnectedWallCount: Int

    /// Footprint area × mean wall height when the outline is closed (m³).
    var volumeM3: Double? {
        footprintAreaM2.map { $0 * Double((minWallHeightM + maxWallHeightM) / 2) }
    }

    init?(from room: CapturedRoom) {
        guard !room.walls.isEmpty else { return nil }

        // Wall segments projected to the floor plane (XZ).
        var segments: [(a: SIMD2<Float>, b: SIMD2<Float>, length: Float, height: Float)] = []
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for wall in room.walls {
            let hw = wall.dimensions.x / 2
            let hh = wall.dimensions.y / 2
            let e0 = wall.transform * SIMD4<Float>(-hw, 0, 0, 1)
            let e1 = wall.transform * SIMD4<Float>( hw, 0, 0, 1)
            segments.append((SIMD2(e0.x, e0.z), SIMD2(e1.x, e1.z),
                             wall.dimensions.x, wall.dimensions.y))

            for sx in [-hw, hw] {
                for sy in [-hh, hh] {
                    let c = wall.transform * SIMD4<Float>(sx, sy, 0, 1)
                    lo = simd_min(lo, SIMD3(c.x, c.y, c.z))
                    hi = simd_max(hi, SIMD3(c.x, c.y, c.z))
                }
            }
        }

        let extent = hi - lo
        bboxWidthM = extent.x
        bboxHeightM = extent.y
        bboxDepthM = extent.z
        minWallHeightM = segments.map(\.height).min() ?? 0
        maxWallHeightM = segments.map(\.height).max() ?? 0

        // Chain the wall segments into an ordered outline.
        let chain = Self.chainSegments(segments.map { ($0.a, $0.b) })
        unconnectedWallCount = chain.unusedCount

        // Number walls in chain order so the floor plan reads naturally;
        // unchained walls come last.
        var orderedIndices = chain.order
        for i in segments.indices where !chain.order.contains(i) { orderedIndices.append(i) }
        walls = orderedIndices.enumerated().map { label, idx in
            let s = segments[idx]
            return Wall(id: label + 1, a: s.a, b: s.b, lengthM: s.length, heightM: s.height)
        }

        // Doors, windows, openings — labeled separately from walls.
        var found: [Portal] = []
        var portalID = 1
        for (kind, surfaces) in [(Portal.Kind.door, room.doors),
                                 (.window, room.windows),
                                 (.opening, room.openings)] {
            for surface in surfaces {
                let hw = surface.dimensions.x / 2
                let e0 = surface.transform * SIMD4<Float>(-hw, 0, 0, 1)
                let e1 = surface.transform * SIMD4<Float>( hw, 0, 0, 1)
                found.append(Portal(id: portalID, kind: kind,
                                    a: SIMD2(e0.x, e0.z), b: SIMD2(e1.x, e1.z),
                                    widthM: surface.dimensions.x))
                portalID += 1
            }
        }
        portals = found

        // Footprint: prefer RoomPlan's captured floor polygon (handles L/U
        // shapes exactly); fall back to the chained wall outline.
        if let floor = room.floors.first, floor.polygonCorners.count >= 3 {
            let poly = floor.polygonCorners.map { corner -> SIMD2<Float> in
                let world = floor.transform * SIMD4<Float>(corner, 1)
                return SIMD2(world.x, world.z)
            }
            footprint = poly
            footprintAreaM2 = Self.polygonArea(poly)
            outlineClosed = true
        } else if chain.closed, chain.path.count >= 3 {
            footprint = chain.path
            footprintAreaM2 = Self.polygonArea(chain.path)
            outlineClosed = true
        } else {
            footprint = nil
            footprintAreaM2 = nil
            outlineClosed = false
        }
    }

    // MARK: Auto-detection

    /// Resolve the capture mode to a concrete kind. Auto prefers the strongest
    /// signal — the device was physically inside the closed floor outline when
    /// the scan finished — then falls back to a room-sized-footprint heuristic.
    static func resolveKind(mode: ClosetMode,
                            metrics: ClosetMetrics?,
                            deviceXZ: SIMD2<Float>?) -> ResolvedClosetKind {
        switch mode {
        case .reachIn: return .reachIn
        case .walkIn: return .walkIn
        case .autoDetect:
            guard let m = metrics else { return .reachIn }
            if let poly = m.footprint, let p = deviceXZ, polygonContains(poly, p) {
                return .walkIn
            }
            if let area = m.footprintAreaM2, area >= 2.3 { return .walkIn }   // ≈ 25 sq ft
            if Double(m.bboxWidthM * m.bboxDepthM) >= 3.0 { return .walkIn }
            return .reachIn
        }
    }

    // MARK: Geometry helpers

    /// Greedy end-to-end chaining of unordered wall segments into an outline.
    private static func chainSegments(_ segs: [(a: SIMD2<Float>, b: SIMD2<Float>)],
                                      tolerance: Float = 0.25)
        -> (order: [Int], path: [SIMD2<Float>], closed: Bool, unusedCount: Int) {
        guard let first = segs.first else { return ([], [], false, 0) }
        var used = [Bool](repeating: false, count: segs.count)
        used[0] = true
        var order = [0]
        var path = [first.a, first.b]

        var extended = true
        while extended {
            extended = false
            guard let tail = path.last else { break }
            for i in segs.indices where !used[i] {
                if simd_distance(segs[i].a, tail) < tolerance {
                    path.append(segs[i].b); used[i] = true; order.append(i); extended = true; break
                }
                if simd_distance(segs[i].b, tail) < tolerance {
                    path.append(segs[i].a); used[i] = true; order.append(i); extended = true; break
                }
            }
        }

        var closed = false
        if let firstPt = path.first, let lastPt = path.last,
           path.count > 3, simd_distance(firstPt, lastPt) < tolerance {
            closed = true
            path.removeLast()   // drop duplicated closing vertex
        }
        return (order, path, closed, used.filter { !$0 }.count)
    }

    /// Shoelace formula.
    static func polygonArea(_ poly: [SIMD2<Float>]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var sum = 0.0
        for i in poly.indices {
            let p = poly[i]
            let q = poly[(i + 1) % poly.count]
            sum += Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
        }
        return abs(sum) / 2
    }

    /// Ray-casting point-in-polygon test.
    static func polygonContains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
