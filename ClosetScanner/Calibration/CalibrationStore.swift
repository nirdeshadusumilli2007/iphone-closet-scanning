import Foundation

/// A persisted multiplicative scale correction.
///
/// iPhone LiDAR/VIO typically carries a small *systematic* scale error (every
/// length reads a consistent fraction long or short). That bias is the largest
/// correctable error and the key to approaching 1/16". You measure one reference
/// of precisely known length; we derive `k = true / measured` and apply it to all
/// subsequent measurements and to the room dimensions. See VALIDATION.md §5.
final class CalibrationStore: ObservableObject {
    @Published var scaleFactor: Double {
        didSet { UserDefaults.standard.set(scaleFactor, forKey: Self.key) }
    }
    @Published var referenceNote: String {
        didSet { UserDefaults.standard.set(referenceNote, forKey: Self.noteKey) }
    }

    private static let key = "calibration.scaleFactor.v1"
    private static let noteKey = "calibration.note.v1"

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        scaleFactor = stored > 0 ? stored : 1.0
        referenceNote = UserDefaults.standard.string(forKey: Self.noteKey) ?? ""
    }

    var isCalibrated: Bool { abs(scaleFactor - 1.0) > 0.00001 }

    /// Percent correction, e.g. +0.7% means raw readings were 0.7% short.
    var correctionPercent: Double { (scaleFactor - 1.0) * 100 }

    /// Apply the correction to a raw metric length.
    func corrected(_ rawMeters: Double) -> Double { rawMeters * scaleFactor }

    /// Derive scale from a raw reading and its known true length (both meters).
    func calibrate(rawMeters: Double, trueMeters: Double, note: String) {
        guard rawMeters > 0 else { return }
        scaleFactor = trueMeters / rawMeters
        referenceNote = note
    }

    func reset() {
        scaleFactor = 1.0
        referenceNote = ""
    }
}
