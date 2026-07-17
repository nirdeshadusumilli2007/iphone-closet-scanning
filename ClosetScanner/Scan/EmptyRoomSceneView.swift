import SwiftUI
import SceneKit
import RoomPlan
import simd

/// Builds a SceneKit scene from a captured room. Walls, floor, doors, windows,
/// and openings are the architecture; detected `objects` are the *contents*,
/// added as tagged nodes so they can be shown or hidden — or excluded entirely
/// for a clean export.
enum RoomSceneBuilder {

    static func scene(from room: CapturedRoom, includeContents: Bool,
                      contentMesh: [ContentMesh] = [],
                      contentPoints: [SIMD3<Float>] = []) -> SCNScene {
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

        // Contents — tagged "content" so the UI can toggle them. Two sources:
        // the raw LiDAR mesh of everything that isn't architecture (catches
        // clothes, bins, shelf clutter), plus RoomPlan's classified objects
        // as translucent orange boxes.
        if includeContents {
            for mesh in contentMesh {
                scene.rootNode.addChildNode(contentMeshNode(mesh))
            }
            if !contentPoints.isEmpty {
                scene.rootNode.addChildNode(contentPointsNode(contentPoints))
            }
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

    /// The filtered LiDAR mesh of the closet's contents, with smoothed normals
    /// accumulated from face normals so default lighting shades it.
    private static func contentMeshNode(_ mesh: ContentMesh) -> SCNNode {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
        for f in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[f]), ib = Int(mesh.indices[f + 1]), ic = Int(mesh.indices[f + 2])
            let n = simd_cross(mesh.vertices[ib] - mesh.vertices[ia],
                               mesh.vertices[ic] - mesh.vertices[ia])   // area-weighted
            normals[ia] += n; normals[ib] += n; normals[ic] += n
        }

        let vertexSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let normalSource = SCNGeometrySource(normals: normals.map { n -> SCNVector3 in
            let len = simd_length(n)
            let u = len > 0 ? n / len : SIMD3<Float>(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        })
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        geometry.materials = [contentMaterial()]

        let node = SCNNode(geometry: geometry)
        node.name = "content"
        return node
    }

    /// The dense depth point cloud of the contents, drawn as a SceneKit point
    /// primitive. Tagged "content" so it toggles with the mesh; excluded from
    /// the empty-room USDZ export (which is built with `includeContents: false`).
    private static func contentPointsNode(_ points: [SIMD3<Float>]) -> SCNNode {
        let source = SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: Array(0..<Int32(points.count)), primitiveType: .point)
        element.pointSize = 0.012
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 6
        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemOrange
        material.lightingModel = .constant            // points carry no normals
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "content"
        return node
    }
}

/// Orbitable 3D view of the reconstructed closet. Toggling `showContents` hides
/// or reveals the detected clutter without rebuilding the scene, so the empty
/// space is visible on demand.
struct EmptyRoomSceneView: UIViewRepresentable {
    let room: CapturedRoom
    let contentMesh: [ContentMesh]
    let contentPoints: [SIMD3<Float>]
    let showContents: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.scene = RoomSceneBuilder.scene(from: room, includeContents: true,
                                            contentMesh: contentMesh, contentPoints: contentPoints)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene?.rootNode
            .childNodes { node, _ in node.name == "content" }
            .forEach { $0.isHidden = !showContents }
    }
}
