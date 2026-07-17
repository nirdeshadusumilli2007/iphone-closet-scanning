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
    /// LiDAR scene mesh of everything inside the closet that isn't
    /// architecture — the contents the show/hide toggle operates on.
    let contentMesh: [ContentMesh]
    /// Dense per-pixel depth points that stand off the architecture — catches
    /// the hanging clothes and floor shoes the decimated mesh loses. Rendered
    /// alongside `contentMesh` under the same show/hide toggle.
    let contentPoints: [SIMD3<Float>]
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
    /// LiDAR scene mesh copied out at Finish time, before RoomPlan stops the
    /// session. Filtered against the processed room in the delegate callback.
    private var meshSnapshot: MeshSnapshot?
    /// Dense per-pixel depth cloud, accumulated across the scan (not just the
    /// final frame) so every viewpoint contributes coverage.
    private let depth = DepthContentAccumulator()
    /// Samples `sceneDepth` off the live session at ~10 Hz while scanning.
    private var depthTimer: Timer?

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
        meshSnapshot = nil
        depth.reset()
        statusText = mode.coaching
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
        startDepthSampling()
    }

    /// Read the live session's depth map on a timer and fold it into the dense
    /// point cloud. Polling `currentFrame` is read-only, so it doesn't disturb
    /// RoomPlan's ownership of the ARSession the way installing our own
    /// `ARSessionDelegate` would.
    private func startDepthSampling() {
        depthTimer?.invalidate()
        depthTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isScanning,
                  let frame = self.captureView?.captureSession.arSession.currentFrame,
                  let sample = DepthContentAccumulator.sample(from: frame) else { return }
            self.depth.add(sample)
        }
    }

    private func stopDepthSampling() {
        depthTimer?.invalidate()
        depthTimer = nil
    }

    /// Fully release the camera when leaving the Scan tab so the Ruler can take
    /// it. `RoomCaptureView` holds the AR session for its live preview until the
    /// session is stopped, so stop it even when no scan is running — otherwise
    /// the Ruler tab comes up black.
    func releaseCamera() {
        if isScanning {
            cancel()
        } else {
            stopDepthSampling()
            captureView?.captureSession.stop()
        }
    }

    /// Aborts the scan and discards the result (Cancel button, or the tab
    /// disappearing). RoomPlan still runs its post-processing after `stop()`,
    /// so we flag the result to be thrown away when the delegate fires.
    func cancel() {
        guard isScanning else { return }
        pendingCancel = true
        stopDepthSampling()
        captureView?.captureSession.stop()
        isScanning = false
        isProcessing = true
        statusText = "Cancelling…"
    }

    /// Ends capture; RoomPlan post-processes and delivers the final room via the delegate.
    func finish() {
        guard isScanning else { return }
        stopDepthSampling()
        let finalFrame = captureView?.captureSession.arSession.currentFrame
        deviceXZAtFinish = (finalFrame?.camera.transform.columns.3)
            .map { SIMD2<Float>($0.x, $0.z) }
        // Grab the accumulated scene mesh now — stop() tears the session down.
        print("[ClosetScanner] finish: snapshotting scene mesh…")
        meshSnapshot = (captureView?.captureSession.arSession).map(ContentMeshExtractor.snapshot(from:))
        print("[ClosetScanner] finish: snapshot ok — \(meshSnapshot?.anchors.count ?? 0) anchors, \(meshSnapshot?.anchors.reduce(0) { $0 + $1.vertices.count } ?? 0) vertices")
        // Fold in one last depth frame so the final viewpoint is represented.
        if let finalFrame, let sample = DepthContentAccumulator.sample(from: finalFrame) {
            depth.add(sample)
        }
        print("[ClosetScanner] finish: depth cloud — \(depth.count) voxels")
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
            meshSnapshot = nil
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
        print("[ClosetScanner] didPresent: filtering contents…")
        let contents = meshSnapshot.map {
            ContentMeshExtractor.extractContents(from: $0, room: processedResult, metrics: metrics)
        } ?? []
        let points = ContentMeshExtractor.extractContentPoints(points: depth.pointCloud(),
                                                               room: processedResult, metrics: metrics)
        print("[ClosetScanner] didPresent: filter ok — \(contents.count) mesh chunks, \(contents.reduce(0) { $0 + $1.indices.count / 3 }) triangles, \(points.count) depth points")
        meshSnapshot = nil
        depth.reset()
        result = ScanResult(room: processedResult, metrics: metrics, kind: kind,
                            requestedMode: mode, contentMesh: contents, contentPoints: points)
    }
}
