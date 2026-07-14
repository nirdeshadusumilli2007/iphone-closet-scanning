import SwiftUI
import RoomPlan
import ARKit

/// Live RoomPlan capture. RoomPlan uses the camera + LiDAR to reconstruct the
/// room's *architecture* (walls, floor, ceiling, doors, windows) separately from
/// its *contents* (`objects`). Because we render only the architecture, the
/// closet's clutter is inherently excluded — that is our "digitally remove the
/// existing contents" step.
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
                    controls
                }
            }
        }
        .navigationTitle("Closet Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }     // restart when returning to this tab
        .onDisappear { model.stop() }   // release the camera for the Ruler tab
        .sheet(item: $model.result, onDismiss: { model.start() }) { result in
            ScanResultScreen(result: result)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Text(model.statusText)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.ultraThinMaterial, in: Capsule())

            if model.isScanning {
                Button(action: model.finish) {
                    Label("Finish Scan", systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
            } else if !model.isProcessing {
                Button(action: model.start) {
                    Label("New Scan", systemImage: "arrow.clockwise.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
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
        model.start()
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
