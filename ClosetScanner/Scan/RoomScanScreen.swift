import SwiftUI
import RoomPlan
import ARKit

/// Live RoomPlan capture. RoomPlan uses the camera + LiDAR to reconstruct the
/// room's *architecture* (walls, floor, ceiling, doors, windows) separately from
/// its *contents*. Contents come from two sources: RoomPlan's classified
/// `objects`, plus the raw LiDAR scene mesh filtered against the architecture
/// (see `ContentMeshExtractor`) — which catches clothes, bins, and clutter that
/// RoomPlan can't classify. Rendering only the architecture is our "digitally
/// remove the existing contents" step.
///
/// Flow: pick a closet type (Reach-in / Walk-in / Auto) → Start Scan → coached
/// capture → Finish (process) or Cancel (discard).
struct RoomScanScreen: View {
    @StateObject private var model = RoomScanModel()

    var body: some View {
        Group {
            if !RoomScanModel.isSupported {
                UnsupportedView(
                    feature: "Closet Scan (RoomPlan)",
                    reason: "This device has no LiDAR scanner. RoomPlan requires an iPhone/iPad Pro (12 Pro or newer)."
                )
            } else {
                ZStack(alignment: .bottom) {
                    RoomCaptureRepresentable(model: model)
                        .ignoresSafeArea()
                    if model.isScanning || model.isProcessing {
                        scanControls
                    } else {
                        startPanel
                    }
                }
            }
        }
        .navigationTitle("Closet Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.releaseCamera() }   // release the camera for the Ruler tab
        .sheet(item: $model.result) { result in
            ScanResultScreen(result: result)
        }
    }

    /// Idle state: closet-type picker + start button, covering the (stopped) camera view.
    private var startPanel: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "door.left.hand.open")
                .font(.system(size: 44))
                .foregroundStyle(.teal)
            Text("Scan your closet")
                .font(.title2.bold())

            Picker("Closet type", selection: $model.mode) {
                ForEach(ClosetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 64, alignment: .top)

            Button(action: model.start) {
                Label("Start Scan", systemImage: "camera.viewfinder")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)

            if model.statusText.hasPrefix("Scan error") {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// Active state: coaching text + Finish / Cancel while scanning, or a
    /// processing indicator while RoomPlan builds the model.
    private var scanControls: some View {
        VStack(spacing: 12) {
            if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if model.isScanning {
                HStack(spacing: 12) {
                    Button(action: model.finish) {
                        Label("Finish Scan", systemImage: "checkmark.circle.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: model.cancel) {
                        Text("Cancel")
                            .font(.headline)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                }
            } else if model.isProcessing {
                ProgressView()
                    .padding(.bottom, 8)
            }
        }
        .padding()
    }
}

/// Hosts the UIKit `RoomCaptureView` (camera preview + coaching overlay) inside SwiftUI.
struct RoomCaptureRepresentable: UIViewRepresentable {
    let model: RoomScanModel

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        model.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
