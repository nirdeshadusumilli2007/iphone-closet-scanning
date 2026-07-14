import SwiftUI
import RoomPlan
import ARKit

/// Identifiable wrapper so `CapturedRoom` can drive a SwiftUI `.sheet(item:)`.
struct ScanResult: Identifiable {
    let id = UUID()
    let room: CapturedRoom
    let dimensions: RoomDimensions?
}

/// Owns the RoomPlan capture session lifecycle and surfaces results to SwiftUI.
final class RoomScanModel: NSObject, ObservableObject, RoomCaptureViewDelegate {
    static let scanPrompt = "Move slowly and pan across every wall, the floor, and the ceiling."

    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var statusText = RoomScanModel.scanPrompt
    @Published var result: ScanResult?

    private weak var captureView: RoomCaptureView?

    /// RoomPlan is only available on LiDAR-equipped devices; scene-mesh support is a reliable proxy.
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    override init() {
        super.init()
    }

    // RoomCaptureViewDelegate inherits NSCoding (the view can archive its
    // delegate). We never archive this model, so these are inert stubs — but
    // without them the class does not compile.
    func encode(with coder: NSCoder) {}
    init?(coder: NSCoder) { return nil }

    func attach(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
    }

    /// Starts (or restarts) a capture. Safe to call repeatedly — no-ops while a
    /// scan is running or while RoomPlan is post-processing the previous one.
    func start() {
        guard let captureView, !isScanning, !isProcessing else { return }
        statusText = Self.scanPrompt
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func stop() {
        guard isScanning else { return }
        captureView?.captureSession.stop()
        isScanning = false
    }

    /// Ends capture; RoomPlan post-processes and delivers the final room via the delegate.
    func finish() {
        guard isScanning else { return }
        captureView?.captureSession.stop()
        isScanning = false
        isProcessing = true
        statusText = "Processing scan…"
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        isProcessing = false
        if let error {
            statusText = "Scan error: \(error.localizedDescription). Tap New Scan to retry."
            return
        }
        statusText = Self.scanPrompt
        result = ScanResult(room: processedResult, dimensions: RoomDimensions(from: processedResult))
    }
}
