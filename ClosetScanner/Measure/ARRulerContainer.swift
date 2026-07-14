import SwiftUI
import RealityKit
import ARKit

/// Configures an `ARView` for LiDAR-backed measurement: scene-mesh
/// reconstruction, dense depth, and plane detection. The reconstructed mesh is
/// drawn as an overlay so the operator can see what the sensor has locked onto.
struct ARRulerContainer: UIViewRepresentable {
    let engine: RulerEngine

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = engine
        engine.arView = arView
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.run(RulerEngine.makeConfiguration())
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
