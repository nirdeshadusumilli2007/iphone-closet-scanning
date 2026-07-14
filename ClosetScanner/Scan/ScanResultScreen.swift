import SwiftUI
import SceneKit
import RoomPlan

/// Post-scan summary, adapted to the closet kind:
///   • Reach-in: W × D × H to 1/16" (+ decimal inches), opening width, area, volume.
///   • Walk-in: 2D floor plan with numbered wall segments, footprint area,
///     bounding box, per-wall lengths, ceiling min/max, labeled doors/openings.
/// Both get the orbitable 3D reconstruction with the show/hide-contents toggle,
/// completeness warnings, and an architecture-only USDZ export.
struct ScanResultScreen: View {
    let result: ScanResult

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var calibration: CalibrationStore

    @State private var showContents = false
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    EmptyRoomSceneView(room: result.room, showContents: showContents)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottomLeading) {
                            Text("Drag to orbit · pinch to zoom")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(8)
                        }

                    Toggle(isOn: $showContents) {
                        Label(showContents ? "Showing existing contents" : "Contents removed (empty space)",
                              systemImage: showContents ? "shippingbox.fill" : "shippingbox")
                    }
                    .tint(.orange)

                    if let m = result.metrics {
                        if !warnings(for: m).isEmpty {
                            warningsCard(warnings(for: m))
                        }
                        if result.kind == .walkIn || m.walls.count > 2 {
                            floorPlanCard(m)
                        }
                        dimensionsCard(m)
                    } else {
                        Text("Not enough walls were captured to compute dimensions. Re-scan and make sure each wall is fully covered.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: exportEmptyUSDZ) {
                        Label("Export empty room (USDZ)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(6)
                    }
                    .buttonStyle(.bordered)

                    if let exportError {
                        Text(exportError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Empty Closet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showShare) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label(result.kind.title,
                  systemImage: result.kind == .walkIn ? "figure.walk" : "rectangle.portrait.arrowtriangle.2.inward")
                .font(.subheadline.bold())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.teal.opacity(0.2), in: Capsule())

            if result.requestedMode == .autoDetect {
                Text("auto-detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Warnings

    /// Completeness diagnostics, filtered by kind: an open outline is expected
    /// for a reach-in scanned from the doorway, but a red flag for a walk-in.
    private func warnings(for m: ClosetMetrics) -> [String] {
        var out: [String] = []
        if result.kind == .walkIn {
            if !m.outlineClosed {
                out.append("The floor outline doesn't close — a wall segment was probably missed. Re-scan, covering every corner and return.")
            }
            if m.unconnectedWallCount > 0 {
                out.append("\(m.unconnectedWallCount) wall segment(s) couldn't be connected to the outline (an island or a gap in coverage).")
            }
        } else if m.walls.count < 3 {
            out.append("Only \(m.walls.count) wall(s) captured — width or depth may be incomplete. Pan across the back and both side walls.")
        }
        if m.portals.isEmpty {
            out.append("No door or opening was detected. Include the doorway in the scan if you need its width.")
        }
        return out
    }

    private func warningsCard(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Floor plan

    private func floorPlanCard(_ m: ClosetMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Floor plan (top-down)").font(.headline)
            FloorPlanView(metrics: m)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Numbered badges match the wall list below. Orange = door, dashed = opening, blue = window.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Dimensions

    /// Calibrated length in meters.
    private func cal(_ meters: Double) -> Double { calibration.corrected(meters) }
    /// Areas scale with k², volumes with k³.
    private var k: Double { calibration.scaleFactor }

    private func dimensionsCard(_ m: ClosetMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.kind == .walkIn ? "Walk-in dimensions" : "Interior dimensions")
                    .font(.headline)
                Spacer()
                if calibration.isCalibrated {
                    Text(String(format: "cal %+.2f%%", calibration.correctionPercent))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.teal.opacity(0.25), in: Capsule())
                }
            }

            switch result.kind {
            case .reachIn: reachInRows(m)
            case .walkIn: walkInRows(m)
            }

            if !m.portals.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Doors & openings").font(.subheadline.bold())
                ForEach(m.portals) { p in
                    dimRow("\(p.kind.rawValue) \(p.id)", meters: cal(Double(p.widthM)))
                }
            }

            Divider().padding(.vertical, 4)
            Text("RoomPlan gives a fast whole-room estimate (typically ±a few cm). For 1/16\" spans, use the Ruler tab. Values reflect the current scale calibration.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func reachInRows(_ m: ClosetMetrics) -> some View {
        dimRow("Width",  meters: cal(Double(m.bboxWidthM)))
        dimRow("Depth",  meters: cal(Double(m.bboxDepthM)))
        dimRow("Height", meters: cal(Double(m.bboxHeightM)))

        let areaM2 = (m.footprintAreaM2 ?? Double(m.bboxWidthM * m.bboxDepthM)) * k * k
        let volM3 = (m.volumeM3 ?? Double(m.bboxWidthM * m.bboxDepthM * m.bboxHeightM)) * k * k * k
        textRow("Floor area", ImperialLength.formatArea(squareMeters: areaM2))
        textRow("Volume", ImperialLength.formatVolume(cubicMeters: volM3))
    }

    @ViewBuilder
    private func walkInRows(_ m: ClosetMetrics) -> some View {
        if let area = m.footprintAreaM2 {
            textRow("Footprint area", ImperialLength.formatArea(squareMeters: area * k * k))
        } else {
            textRow("Footprint area", "— (outline not closed)")
        }
        textRow("Bounding box",
                "\(ImperialLength.format(meters: cal(Double(m.bboxWidthM)))) × \(ImperialLength.format(meters: cal(Double(m.bboxDepthM))))")

        // Ceiling height: single value, or a min–max range under a sloped ceiling.
        let minH = cal(Double(m.minWallHeightM))
        let maxH = cal(Double(m.maxWallHeightM))
        if maxH - minH > 0.013 {   // > ~1/2"
            textRow("Ceiling height",
                    "\(ImperialLength.format(meters: minH)) – \(ImperialLength.format(meters: maxH)) (sloped)")
        } else {
            dimRow("Ceiling height", meters: maxH)
        }

        if let vol = m.volumeM3 {
            textRow("Volume", ImperialLength.formatVolume(cubicMeters: vol * k * k * k))
        }

        if !m.walls.isEmpty {
            Divider().padding(.vertical, 4)
            Text("Wall segments (see floor plan)").font(.subheadline.bold())
            ForEach(m.walls) { w in
                dimRow("Wall \(w.id)", meters: cal(Double(w.lengthM)))
            }
        }
    }

    private func dimRow(_ label: String, meters: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ImperialLength.format(meters: meters)).font(.body.weight(.semibold))
                Text(String(format: "%.3f in  ·  %.1f cm",
                            ImperialLength.inches(fromMeters: meters), meters * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Export

    /// Writes the architecture-only (contents-excluded) reconstruction to USDZ via
    /// SceneKit, so the exported file is genuinely empty.
    private func exportEmptyUSDZ() {
        exportError = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyCloset.usdz")
        try? FileManager.default.removeItem(at: url)
        let scene = RoomSceneBuilder.scene(from: result.room, includeContents: false)
        if scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) {
            exportURL = url
            showShare = true
        } else {
            exportError = "Export failed while writing USDZ."
        }
    }
}

/// UIKit share sheet bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
