import SwiftUI
import SceneKit
import RoomPlan

/// Post-scan summary: the reconstructed closet with a show/hide-contents toggle,
/// the (calibration-corrected) dimensions, and a walls-only USDZ export.
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

                    if let d = result.dimensions {
                        dimensionsCard(d)
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

    private func dimensionsCard(_ d: RoomDimensions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Interior dimensions").font(.headline)
                Spacer()
                if calibration.isCalibrated {
                    Text(String(format: "cal %+.2f%%", calibration.correctionPercent))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.teal.opacity(0.25), in: Capsule())
                }
            }
            dimRow("Width",  meters: calibration.corrected(Double(d.width)))
            dimRow("Depth",  meters: calibration.corrected(Double(d.length)))
            dimRow("Height", meters: calibration.corrected(Double(d.height)))

            if !d.wallLengths.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Individual wall lengths").font(.subheadline.bold())
                ForEach(Array(d.wallLengths.enumerated()), id: \.offset) { i, len in
                    dimRow("Wall \(i + 1)", meters: calibration.corrected(Double(len)))
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

    private func dimRow(_ label: String, meters: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ImperialLength.format(meters: meters)).font(.body.weight(.semibold))
                Text(String(format: "%.1f cm", meters * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
