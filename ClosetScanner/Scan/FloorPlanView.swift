import SwiftUI
import simd

/// Top-down 2D floor plan of the captured closet: footprint fill, numbered wall
/// segments (numbers match the wall-length list), doors/windows/openings in
/// distinct styles, and a 1-foot scale bar. Essential for walk-ins, where a
/// single W × D can't describe an L- or U-shaped footprint.
struct FloorPlanView: View {
    let metrics: ClosetMetrics

    var body: some View {
        Canvas { context, size in
            var points: [SIMD2<Float>] = []
            points.append(contentsOf: metrics.walls.flatMap { [$0.a, $0.b] })
            points.append(contentsOf: metrics.portals.flatMap { [$0.a, $0.b] })
            if let fp = metrics.footprint { points.append(contentsOf: fp) }
            guard points.count >= 2 else { return }

            var lo = points[0], hi = points[0]
            for p in points {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            let extent = hi - lo
            guard extent.x > 0.01 || extent.y > 0.01 else { return }

            let pad: CGFloat = 30
            let scale = min((size.width - 2 * pad) / CGFloat(max(extent.x, 0.01)),
                            (size.height - 2 * pad) / CGFloat(max(extent.y, 0.01)))
            let drawnW = CGFloat(extent.x) * scale
            let drawnH = CGFloat(extent.y) * scale
            let ox = (size.width - drawnW) / 2
            let oy = (size.height - drawnH) / 2

            func pt(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: ox + CGFloat(p.x - lo.x) * scale,
                        y: oy + CGFloat(p.y - lo.y) * scale)
            }

            // Footprint fill.
            if let fp = metrics.footprint, fp.count >= 3 {
                var path = Path()
                path.move(to: pt(fp[0]))
                for p in fp.dropFirst() { path.addLine(to: pt(p)) }
                path.closeSubpath()
                context.fill(path, with: .color(.teal.opacity(0.10)))
            }

            // Walls.
            for wall in metrics.walls {
                var path = Path()
                path.move(to: pt(wall.a))
                path.addLine(to: pt(wall.b))
                context.stroke(path, with: .color(.teal), lineWidth: 3.5)
            }

            // Portals drawn over the walls: door solid orange, window blue,
            // opening dashed gray.
            for portal in metrics.portals {
                var path = Path()
                path.move(to: pt(portal.a))
                path.addLine(to: pt(portal.b))
                switch portal.kind {
                case .door:
                    context.stroke(path, with: .color(.orange), lineWidth: 5)
                case .window:
                    context.stroke(path, with: .color(.blue), lineWidth: 5)
                case .opening:
                    context.stroke(path, with: .color(.gray),
                                   style: StrokeStyle(lineWidth: 5, dash: [5, 4]))
                }
            }

            // Wall number badges, nudged outward from the footprint centroid so
            // they don't sit on the line.
            let centroid = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
            for wall in metrics.walls {
                let mid = (wall.a + wall.b) / 2
                var dir = mid - centroid
                let len = simd_length(dir)
                dir = len > 0.001 ? dir / len : SIMD2<Float>(0, -1)
                let at = CGPoint(x: pt(mid).x + CGFloat(dir.x) * 13,
                                 y: pt(mid).y + CGFloat(dir.y) * 13)

                let badge = Path(ellipseIn: CGRect(x: at.x - 9, y: at.y - 9, width: 18, height: 18))
                context.fill(badge, with: .color(.teal))
                context.draw(Text("\(wall.id)").font(.caption2.bold()).foregroundStyle(.white), at: at)
            }

            // 1-foot scale bar, bottom-left.
            let footPx = CGFloat(0.3048) * scale
            let barY = size.height - 14
            var bar = Path()
            bar.move(to: CGPoint(x: 12, y: barY))
            bar.addLine(to: CGPoint(x: 12 + footPx, y: barY))
            context.stroke(bar, with: .color(.secondary), lineWidth: 2)
            context.draw(Text("1 ft").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 12 + footPx / 2, y: barY - 9))
        }
        .background(Color(.secondarySystemBackground))
    }
}
