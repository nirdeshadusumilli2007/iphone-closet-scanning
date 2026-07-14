import SwiftUI
import RoomPlan
import ARKit
import simd

/// Identifiable wrapper so `CapturedRoom` can drive a SwiftUI `.sheet(item:)`.
struct ScanResult: Identifiable {
    let id = UUID()
    let room: CapturedRoom
    let metrics: ClosetMetrics?
    let kind: ResolvedClosetKind
    let requestedMode: ClosetMode
}

/// Owns the RoomPlan capture session lifecycle and surfaces results to SwiftUI.
final class RoomScanModel: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published var mode: ClosetMode = .autoDetect
    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var statusText = ""
    @Published var result: ScanResult?

    private weak var captureView: RoomCaptureView?
    /// Set when the scan is cancelled (button or tab switch) so the delegate
    /// discards the processed result instead of presenting it.
    private var pendingCancel = false
    /// Device position (world XZ) at the moment Finish was tapped — the
    /// inside-the-footprint signal for auto-detection.
    private var deviceXZAtFinish: SIMD2<Float>?

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

    /// Starts a capture in the currently selected mode. No-ops while a scan is
    /// running or while RoomPlan is post-processing the previous one.
    func start() {
        guard let captureView, !isScanning, !isProcessing else { return }
        pendingCancel = false
        deviceXZAtFinish = nil
        statusText = mode.coaching
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    /// Aborts the scan and discards the result (Cancel button, or the tab
    /// disappearing). RoomPlan still runs its post-processing after `stop()`,
    /// so we flag the result to be thrown away when the delegate fires.
    func cancel() {
        guard isScanning else { return }
        pendingCancel = true
        captureView?.captureSession.stop()
        isScanning = false
        isProcessing = true
        statusText = "Cancelling…"
    }

    /// Ends capture; RoomPlan post-processes and delivers the final room via the delegate.
    func finish() {
        guard isScanning else { return }
        deviceXZAtFinish = (captureView?.captureSession.arSession.currentFrame?.camera.transform.columns.3)
            .map { SIMD2<Float>($0.x, $0.z) }
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
        if pendingCancel {
            pendingCancel = false
            statusText = ""
            return
        }
        if let error {
            statusText = "Scan error: \(error.localizedDescription)"
            return
        }
        statusText = ""
        let metrics = ClosetMetrics(from: processedResult)
        let kind = ClosetMetrics.resolveKind(mode: mode, metrics: metrics, deviceXZ: deviceXZAtFinish)
        result = ScanResult(room: processedResult, metrics: metrics, kind: kind, requestedMode: mode)
    }
}
