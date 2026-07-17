import SwiftUI
import ARKit

/// The 1/16" measurement UI: a fixed crosshair over the live AR feed, live
/// distance + stability readout, applied scale calibration, and one-tap paths to
/// calibrate or log a reading into the validation harness.
struct PrecisionRulerScreen: View {
    @StateObject private var engine = RulerEngine()
    @EnvironmentObject private var validation: ValidationStore
    @EnvironmentObject private var calibration: CalibrationStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showLogSheet = false
    @State private var showCalibrateSheet = false
    /// Whether this tab is the one on screen — scenePhase changes fire on every
    /// live tab, and a hidden Ruler must not grab the camera from the Scan tab.
    @State private var isVisible = false

    /// Raw committed distance corrected by the current scale factor.
    private var correctedFinalMeters: Double? {
        engine.finalDistanceMeters.map { calibration.corrected($0) }
    }

    var body: some View {
        Group {
            if !RoomScanModel.isSupported {
                UnsupportedView(
                    feature: "Precision Ruler",
                    reason: "LiDAR is required for millimeter-class measurement. Use an iPhone/iPad Pro (12 Pro or newer)."
                )
            } else {
                content
            }
        }
        .navigationTitle("Precision Ruler")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {                             // reclaim the camera on tab switch
            isVisible = true
            engine.resumeSession()
        }
        .onDisappear {                          // hand it back to the Scan tab
            isVisible = false
            engine.pauseSession()
        }
        // Re-check permission + restart when returning from Settings/background
        // — `onAppear` doesn't refire on foregrounding.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isVisible { engine.resumeSession() }
        }
    }

    private var content: some View {
        ZStack {
            ARRulerContainer(engine: engine).ignoresSafeArea()
            if engine.cameraDenied {
                cameraDeniedOverlay
            } else {
                crosshair
                VStack {
                    topBar
                    Spacer()
                    readout
                    buttons
                }
                .padding()
            }
        }
        .sheet(isPresented: $showLogSheet) {
            if let meters = correctedFinalMeters {
                LogMeasurementSheet(measuredMeters: meters) { groundTruthInches in
                    validation.add(measuredMeters: meters, groundTruthInches: groundTruthInches, date: Date())
                }
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showCalibrateSheet) {
            if let rawMeters = engine.finalDistanceMeters {
                CalibrationSheet(rawMeters: rawMeters) { trueMeters, note in
                    calibration.calibrate(rawMeters: rawMeters, trueMeters: trueMeters, note: note)
                }
                .presentationDetents([.medium])
            }
        }
    }

    /// ARKit renders a black screen when camera access is denied — explain and
    /// route the user to Settings instead of leaving them staring at it.
    private var cameraDeniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Camera access is off")
                .font(.title3.bold())
            Text("The Precision Ruler needs the camera and LiDAR. Turn on Camera access for ClosetScanner in Settings, then come back to this tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(engine.hasLiveHit ? Color.green : Color.white, lineWidth: 2)
                .frame(width: 26, height: 26)
            Rectangle().frame(width: 2, height: 12)
            Rectangle().frame(width: 12, height: 2)
        }
        .foregroundStyle(engine.hasLiveHit ? Color.green : Color.white)
        .shadow(radius: 2)
    }

    private var topBar: some View {
        HStack {
            Label(engine.trackingOK ? "Tracking OK" : "Move to initialize…",
                  systemImage: engine.trackingOK ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.caption.bold())
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            // Live stability (while aiming) or committed confidence.
            if let mm = engine.finalDistanceMeters != nil ? engine.confidenceMM : engine.liveSpreadMM {
                Label(String(format: "±%.1f mm", mm), systemImage: "dot.scope")
                    .font(.caption.bold())
                    .foregroundStyle(mm <= 2 ? .green : .orange)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .overlay(alignment: .top) {
            if calibration.isCalibrated {
                Text(String(format: "calibrated %+.2f%%", calibration.correctionPercent))
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 40)
            }
        }
    }

    private var readout: some View {
        VStack(spacing: 6) {
            if let meters = correctedFinalMeters {
                Text(ImperialLength.format(meters: meters))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(String(format: "%.2f cm  ·  %.3f in", meters * 100, ImperialLength.inches(fromMeters: meters)))
                    .font(.callout).foregroundStyle(.secondary)
            } else if let live = engine.liveDistanceMeters {
                Text(ImperialLength.format(meters: calibration.corrected(live)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text(engine.statusText)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Set A") { engine.setPointA() }
                .buttonStyle(.borderedProminent)
                .tint(.green)

            Button("Set B") { engine.setPointB() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(engine.pointA == nil)

            Button("Reset") { engine.reset() }
                .buttonStyle(.bordered)

            Menu {
                Button { showLogSheet = true } label: {
                    Label("Log for validation", systemImage: "checkmark.seal")
                }
                .disabled(engine.finalDistanceMeters == nil)

                Button { showCalibrateSheet = true } label: {
                    Label("Calibrate from this reading", systemImage: "scalemass")
                }
                .disabled(engine.finalDistanceMeters == nil)

                if calibration.isCalibrated {
                    Button(role: .destructive) { calibration.reset() } label: {
                        Label("Clear calibration", systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
            }
            .disabled(engine.finalDistanceMeters == nil && !calibration.isCalibrated)
        }
        .font(.headline)
    }
}

/// Prompts for the tape-measure ground truth and logs a validation record.
struct LogMeasurementSheet: View {
    let measuredMeters: Double
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var groundTruthText = ""

    private var parsed: Double? { ImperialLength.parseInches(groundTruthText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("App measured (calibrated)") {
                    Text(ImperialLength.format(meters: measuredMeters))
                        .font(.title3.bold())
                    Text(String(format: "%.3f in", ImperialLength.inches(fromMeters: measuredMeters)))
                        .foregroundStyle(.secondary)
                }
                Section("Ground truth (tape/rule), in inches") {
                    TextField("e.g. 23 7/16 or 23.4375", text: $groundTruthText)
                        .keyboardType(.numbersAndPunctuation)
                    if let parsed {
                        Text(String(format: "= %.4f in", parsed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Log for Validation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let truth = parsed { onSave(truth) }
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
        }
    }
}

/// Derives a scale-correction factor from a reading of a known reference length.
struct CalibrationSheet: View {
    let rawMeters: Double
    let onCalibrate: (_ trueMeters: Double, _ note: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trueText = ""
    @State private var note = ""

    private var trueInches: Double? { ImperialLength.parseInches(trueText) }

    private var previewFactor: Double? {
        guard let inches = trueInches, rawMeters > 0 else { return nil }
        return (inches / ImperialLength.inchesPerMeter) / rawMeters
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Raw reading of the reference") {
                    Text(String(format: "%.3f in", ImperialLength.inches(fromMeters: rawMeters)))
                        .font(.title3.bold())
                }
                Section("True length of the reference, in inches") {
                    TextField("e.g. 24 or 23 15/16", text: $trueText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Reference note (e.g. 24\" steel rule)", text: $note)
                }
                if let f = previewFactor {
                    Section("Resulting correction") {
                        Text(String(format: "scale ×%.5f  (%+.2f%%)", f, (f - 1) * 100))
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .navigationTitle("Calibrate Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if let inches = trueInches {
                            onCalibrate(inches / ImperialLength.inchesPerMeter, note)
                        }
                        dismiss()
                    }
                    .disabled(trueInches == nil)
                }
            }
        }
    }
}
