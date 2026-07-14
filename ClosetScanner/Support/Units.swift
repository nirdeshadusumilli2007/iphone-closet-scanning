import Foundation

/// Imperial length formatting to the nearest 1/16 inch, which is the target
/// display resolution for this app.
enum ImperialLength {
    static let inchesPerMeter = 39.37007874015748

    static func inches(fromMeters m: Double) -> Double { m * inchesPerMeter }

    /// Break a metric length into feet / whole inches / sixteenths, rounded to
    /// the nearest 1/16".
    static func components(fromMeters meters: Double) -> (feet: Int, inches: Int, sixteenths: Int) {
        let totalSixteenths = Int((meters * inchesPerMeter * 16).rounded())
        var s = max(0, totalSixteenths)
        let feetSixteenths = 12 * 16
        let feet = s / feetSixteenths
        s -= feet * feetSixteenths
        let inches = s / 16
        s -= inches * 16
        return (feet, inches, s)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Reduce n/16 to lowest terms, e.g. 8/16 -> "1/2". Empty string for 0.
    static func reducedFraction(sixteenths: Int) -> String {
        guard sixteenths > 0 else { return "" }
        let g = gcd(sixteenths, 16)
        return "\(sixteenths / g)/\(16 / g)"
    }

    /// e.g. 1.9812 m  ->  6' 6 1/16"
    static func format(meters: Double) -> String {
        let c = components(fromMeters: meters)
        let frac = reducedFraction(sixteenths: c.sixteenths)
        var parts: [String] = []
        if c.feet > 0 { parts.append("\(c.feet)'") }

        if frac.isEmpty {
            parts.append("\(c.inches)\"")
        } else if c.inches == 0 && c.feet == 0 {
            parts.append("\(frac)\"")
        } else {
            parts.append("\(c.inches) \(frac)\"")
        }
        return parts.joined(separator: " ")
    }

    /// Render a length given in inches to the nearest 1/16" (feet shown when ≥ 12"),
    /// e.g. 23.4 in -> 1' 11 7/16"
    static func formatInches(_ totalInches: Double) -> String {
        format(meters: totalInches / inchesPerMeter)
    }

    static let squareFeetPerSquareMeter = 10.763910416709722
    static let cubicFeetPerCubicMeter = 35.31466672148859

    /// e.g. 2.32 m² -> "25.0 sq ft  ·  2.32 m²"
    static func formatArea(squareMeters: Double) -> String {
        String(format: "%.1f sq ft  ·  %.2f m²", squareMeters * squareFeetPerSquareMeter, squareMeters)
    }

    /// e.g. 5.1 m³ -> "180.1 cu ft  ·  5.10 m³"
    static func formatVolume(cubicMeters: Double) -> String {
        String(format: "%.1f cu ft  ·  %.2f m³", cubicMeters * cubicFeetPerCubicMeter, cubicMeters)
    }

    /// Parse a user-entered length in inches, the way people read tape measures.
    /// Accepts decimals ("23.4375") and mixed fractions ("23 7/16", "23-7/16",
    /// "7/16"), with an optional trailing inch mark. Returns nil for anything
    /// unparseable or non-positive.
    static func parseInches(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("\"") { trimmed = String(trimmed.dropLast()) }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let plain = Double(trimmed) {
            return plain > 0 ? plain : nil
        }

        let parts = trimmed
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        guard !parts.isEmpty else { return nil }

        var total = 0.0
        for part in parts {
            if part.contains("/") {
                let f = part.split(separator: "/")
                guard f.count == 2,
                      let num = Double(f[0]), let den = Double(f[1]), den > 0
                else { return nil }
                total += num / den
            } else if let whole = Double(part) {
                total += whole
            } else {
                return nil
            }
        }
        return total > 0 ? total : nil
    }
}
