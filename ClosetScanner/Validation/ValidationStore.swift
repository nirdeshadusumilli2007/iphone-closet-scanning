import Foundation

/// One measured-vs-truth data point.
struct ValidationRecord: Identifiable, Codable {
    var id = UUID()
    var measuredMeters: Double
    var groundTruthInches: Double
    var timestamp: Date

    var measuredInches: Double { ImperialLength.inches(fromMeters: measuredMeters) }
    var errorInches: Double { measuredInches - groundTruthInches }
    var absErrorInches: Double { abs(errorInches) }
    var errorMM: Double { errorInches * 25.4 }
    /// The headline pass/fail: within 1/16".
    var withinSixteenth: Bool { absErrorInches <= 1.0 / 16.0 }
}

/// Persists validation records and computes accuracy statistics. This is the
/// evidence the challenge asks for — "demonstrate how you tested and validated
/// the accuracy" — captured live on-device.
final class ValidationStore: ObservableObject {
    @Published private(set) var records: [ValidationRecord] = []
    private let key = "validation.records.v1"

    init() { load() }

    func add(measuredMeters: Double, groundTruthInches: Double, date: Date) {
        records.insert(
            ValidationRecord(measuredMeters: measuredMeters, groundTruthInches: groundTruthInches, timestamp: date),
            at: 0
        )
        save()
    }

    func delete(at offsets: IndexSet) { records.remove(atOffsets: offsets); save() }
    func clear() { records.removeAll(); save() }

    // MARK: Statistics

    var count: Int { records.count }

    var meanAbsErrorInches: Double {
        guard !records.isEmpty else { return 0 }
        return records.map(\.absErrorInches).reduce(0, +) / Double(records.count)
    }

    var maxAbsErrorInches: Double { records.map(\.absErrorInches).max() ?? 0 }

    /// Root-mean-square error — penalizes large misses, the honest headline metric.
    var rmseInches: Double {
        guard !records.isEmpty else { return 0 }
        let sumSq = records.map { $0.errorInches * $0.errorInches }.reduce(0, +)
        return (sumSq / Double(records.count)).squareRoot()
    }

    /// Systematic bias (signed mean error): non-zero suggests a scale/offset error.
    var meanBiasInches: Double {
        guard !records.isEmpty else { return 0 }
        return records.map(\.errorInches).reduce(0, +) / Double(records.count)
    }

    var pctWithinSixteenth: Double {
        guard !records.isEmpty else { return 0 }
        return Double(records.filter(\.withinSixteenth).count) / Double(records.count) * 100
    }

    // MARK: Export

    func csv() -> String {
        let df = ISO8601DateFormatter()
        var lines = ["timestamp,ground_truth_in,measured_in,error_in,abs_error_in,error_mm,within_1_16"]
        for r in records.reversed() {
            lines.append([
                df.string(from: r.timestamp),
                String(format: "%.4f", r.groundTruthInches),
                String(format: "%.4f", r.measuredInches),
                String(format: "%.4f", r.errorInches),
                String(format: "%.4f", r.absErrorInches),
                String(format: "%.3f", r.errorMM),
                r.withinSixteenth ? "PASS" : "FAIL",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([ValidationRecord].self, from: data)
        else { return }
        records = decoded
    }
}
