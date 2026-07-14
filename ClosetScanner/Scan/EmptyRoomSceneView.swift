import SwiftUI
import SceneKit
import RoomPlan
import simd

/// Builds a SceneKit scene from a captured room. Walls, floor, doors, windows,
/// and openings are the architecture; detected `objects` are the *contents*,
/// added as tagged nodes so they can be shown or hidden — or excluded entirely
/// for a clean export.
enum RoomSceneBuilder {

    static func scene(from room: CapturedRoom, includeContents: Bool) -> SCNScene {
        let scene = SCNScene()
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        // Walls — thin boxes at their captured transforms.
        for wall in room.walls {
            scene.rootNode.addChildNode(
                surfaceNode(wall, thickness: 0.04, material: surfaceMaterial(), name: "wall"))
            accumulate(wall.transform, wall.dimensions, &lo, &hi)
        }

        // Doors, windows, and openings are *architecture*, not contents — they
        // stay visible in the empty render and export. Slightly thicker than the
        // walls so they read through them.
        for door in room.doors {
            scene.rootNode.addChildNode(
                surfaceNode(door, thickness: 0.06, material: portalMaterial(.white, alpha: 0.35), name: "door"))
        }
        for window in room.windows {
            scene.rootNode.addChildNode(
                surfaceNode(window, thickness: 0.06, material: portalMaterial(.systemBlue, alpha: 0.30), name: "window"))
        }
        for opening in room.openings {
            scene.rootNode.addChildNode(
                surfaceNode(opening, thickness: 0.06, material: portalMaterial(.white, alpha: 0.15), name: "opening"))
        }

        guard lo.x <= hi.x else { return scene }   // no walls captured

        let center = (lo + hi) / 2
        let extent = hi - lo

        // Floor: use the captured floor surfaces when RoomPlan found them,
        // otherwise synthesize a slab at the base of the wall bounds.
        if !room.floors.isEmpty {
            for floor in room.floors {
                scene.rootNode.addChildNode(
                    surfaceNode(floor, thickness: 0.03, material: surfaceMaterial(alpha: 0.18), name: "floor"))
            }
        } else {
            let floor = SCNBox(width: CGFloat(extent.x), height: 0.03, length: CGFloat(extent.z), chamferRadius: 0)
            floor.materials = [surfaceMaterial(alpha: 0.18)]
            let floorNode = SCNNode(geometry: floor)
            floorNode.simdPosition = SIMD3<Float>(center.x, lo.y, center.z)
            floorNode.name = "floor"
            scene.rootNode.addChildNode(floorNode)
        }

        // Contents — translucent orange boxes, tagged so the UI can toggle them.
        if includeContents {
            for object in room.objects {
                let box = SCNBox(width: CGFloat(object.dimensions.x),
                                 height: CGFloat(object.dimensions.y),
                                 length: CGFloat(object.dimensions.z), chamferRadius: 0)
                box.materials = [contentMaterial()]
                let node = SCNNode(geometry: box)
                node.simdTransform = object.transform
                node.name = "content"
                scene.rootNode.addChildNode(node)
            }
        }

        // Camera framing the room from a 3/4 angle.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        let reach = max(extent.x, max(extent.y, extent.z)) * 2.2 + 0.5
        camera.simdPosition = center + SIMD3<Float>(extent.x * 0.6, extent.y * 0.7, reach)
        camera.look(at: SCNVector3(center.x, center.y, center.z))
        camera.name = "decor"
        scene.rootNode.addChildNode(camera)

        return scene
    }

    // MARK: Helpers

    /// A captured planar surface (wall/door/window/opening/floor) as a thin box:
    /// RoomPlan surfaces span local X (width) × Y (height) with Z as the normal.
    private static func surfaceNode(_ surface: CapturedRoom.Surface,
                                    thickness: CGFloat,
                                    material: SCNMaterial,
                                    name: String) -> SCNNode {
        let box = SCNBox(width: CGFloat(surface.dimensions.x),
                         height: CGFloat(surface.dimensions.y),
                         length: thickness, chamferRadius: 0)
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.simdTransform = surface.transform
        node.name = name
        return node
    }

    private static func accumulate(_ t: simd_float4x4, _ d: SIMD3<Float>,
                                   _ lo: inout SIMD3<Float>, _ hi: inout SIMD3<Float>) {
        let hx = d.x / 2, hy = d.y / 2, hz = max(d.z / 2, 0.02)
        for sx in [-hx, hx] {
            for sy in [-hy, hy] {
                for sz in [-hz, hz] {
                    let w = t * SIMD4<Float>(sx, sy, sz, 1)
                    let p = SIMD3<Float>(w.x, w.y, w.z)
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                }
            }
        }
    }

    private static func surfaceMaterial(alpha: CGFloat = 0.22) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(alpha)
        m.isDoubleSided = true
        return m
    }

    private static func portalMaterial(_ color: UIColor, alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color.withAlphaComponent(alpha)
        m.isDoubleSided = true
        return m
    }

    private static func contentMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.45)
        m.isDoubleSided = true
        return m
    }
}

/// Orbitable 3D view of the reconstructed closet. Toggling `showContents` hides
/// or reveals the detected clutter without rebuilding the scene, so the empty
/// space is visible on demand.
struct EmptyRoomSceneView: UIViewRepresentable {
    let room: CapturedRoom
    let showContents: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.scene = RoomSceneBuilder.scene(from: room, includeContents: true)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene?.rootNode
            .childNodes { node, _ in node.name == "content" }
            .forEach { $0.isHidden = !showContents }
    }
}
