import SwiftUI

/// Root tab bar. Three features map 1:1 onto the challenge requirements:
///   • Scan     – RoomPlan/LiDAR closet capture + empty-room reconstruction + dimensions
///   • Ruler    – ARKit high-precision point-to-point measurement (the 1/16" push)
///   • Validation – in-app harness that proves measured-vs-truth accuracy
struct ContentView: View {
    @StateObject private var validation = ValidationStore()
    @StateObject private var calibration = CalibrationStore()

    var body: some View {
        TabView {
            NavigationStack { RoomScanScreen() }
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }

            NavigationStack { PrecisionRulerScreen() }
                .tabItem { Label("Ruler", systemImage: "ruler") }

            NavigationStack { ValidationScreen() }
                .tabItem { Label("Validation", systemImage: "checkmark.seal") }
        }
        .environmentObject(validation)
        .environmentObject(calibration)
    }
}

/// Shown when the device lacks a required capability (e.g. no LiDAR).
struct UnsupportedView: View {
    let feature: String
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(feature).font(.title3.bold())
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
