import SwiftUI

/// Displays the accuracy evidence: summary statistics against the 1/16" target
/// plus the full log of measured-vs-truth readings, exportable as CSV.
struct ValidationScreen: View {
    @EnvironmentObject private var store: ValidationStore
    @State private var showShare = false
    @State private var csvURL: URL?

    var body: some View {
        List {
            summarySection
            recordsSection
            methodologySection
        }
        .navigationTitle("Validation")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: exportCSV) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.count == 0)

                    Button(role: .destructive) { store.clear() } label: {
                        Label("Clear all", systemImage: "trash")
                    }
                    .disabled(store.count == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let csvURL { ShareSheet(items: [csvURL]) }
        }
    }

    private var summarySection: some View {
        Section("Accuracy vs. 1/16\" target") {
            if store.count == 0 {
                Text("No readings yet. On the Ruler tab, measure a known length, tap the seal button, and enter the tape-measure value.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                stat("Samples", "\(store.count)")
                stat("Within 1/16\"", String(format: "%.0f%%", store.pctWithinSixteenth),
                     highlight: store.pctWithinSixteenth >= 90 ? .green : .orange)
                stat("Mean abs error", errText(store.meanAbsErrorInches))
                stat("RMSE", errText(store.rmseInches))
                stat("Max error", errText(store.maxAbsErrorInches))
                stat("Systematic bias", errText(store.meanBiasInches, signed: true))
            }
        }
    }

    private var recordsSection: some View {
        Section("Readings") {
            ForEach(store.records) { r in
                HStack {
                    Image(systemName: r.withinSixteenth ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.withinSixteenth ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("truth \(fmt(r.groundTruthInches))\"  ·  meas \(fmt(r.measuredInches))\"")
                            .font(.subheadline)
                        Text(String(format: "err %+.3f in (%+.2f mm)", r.errorInches, r.errorMM))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { store.delete(at: $0) }
        }
    }

    private var methodologySection: some View {
        Section("How this is measured") {
            Text("Each reading is the outlier-rejected median of ~30 LiDAR raycasts at a fixed crosshair, with the current scale calibration applied. Ground truth is a steel tape/rule. Error = measured − truth. See VALIDATION.md for the full protocol; calibrate on the Ruler tab (⋯ menu) to remove systematic scale bias.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String, highlight: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.body.weight(.semibold)).foregroundStyle(highlight ?? .primary)
        }
    }

    private func fmt(_ inches: Double) -> String { String(format: "%.3f", inches) }

    private func errText(_ inches: Double, signed: Bool = false) -> String {
        let fmt = signed ? "%+.3f in (%+.2f mm)" : "%.3f in (%.2f mm)"
        return String(format: fmt, inches, inches * 25.4)
    }

    private func exportCSV() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("closet_validation.csv")
        try? store.csv().write(to: url, atomically: true, encoding: .utf8)
        csvURL = url
        showShare = true
    }
}
