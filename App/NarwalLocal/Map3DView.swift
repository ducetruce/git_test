import NarwalKit
import SceneKit
import simd
import SwiftUI
import UIKit

/// The house map in 3D: the floor plan as a textured floor, walls raised
/// along its edges, furniture as blocks and the robot where it is. Drag to
/// turn, pinch to zoom.
struct Map3DView: UIViewRepresentable {
    let map: RobotMap
    var selected: [Int] = []
    var pose: LivePose?

    /// Scene units per map pixel.
    static let unit: Float = 0.1

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        // Never draw past its own frame, onto the room tiles below.
        view.clipsToBounds = true
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.maximumVerticalAngle = 80
        view.defaultCameraController.minimumVerticalAngle = 15
        rebuild(view, context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let key = "\(map.mapId)-\(map.pixels.count)-\(selected)"
        if context.coordinator.key != key { rebuild(view, context) }
        if let robot = view.scene?.rootNode.childNode(withName: "robot", recursively: false) {
            place(robot, at: pose)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var key = "" }

    private func rebuild(_ view: SCNView, _ context: Context) {
        context.coordinator.key = "\(map.mapId)-\(map.pixels.count)-\(selected)"
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = RobotSceneBuilder.environmentImage()
        RobotSceneBuilder.addLights(to: scene.rootNode)

        let u = Self.unit
        let w = CGFloat(Float(map.width) * u), h = CGFloat(Float(map.height) * u)

        // Floor: the 2D map image laid flat (north up = -z).
        let floor = SCNPlane(width: w, height: h)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = map.image(selected: Set(selected))
        m.diffuse.magnificationFilter = .nearest
        m.roughness.contents = 0.8
        floor.materials = [m]
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(floorNode)

        if let walls = wallGeometry() { scene.rootNode.addChildNode(SCNNode(geometry: walls)) }

        let furnitureMaterial = RobotSceneBuilder.pbr(UIColor(red: 0.78, green: 0.8, blue: 0.83, alpha: 1), metal: 0.05, rough: 0.6)
        for item in map.furniture where item.isDrawable {
            let height = Self.height(forFurniture: item.type)
            let box = SCNBox(width: CGFloat(Float(item.width) * u), height: CGFloat(height),
                             length: CGFloat(Float(item.height) * u), chamferRadius: 0.05)
            box.materials = [furnitureMaterial]
            let n = SCNNode(geometry: box)
            n.position = scenePoint(map.gridPoint(for: item.center), y: height / 2)
            n.eulerAngles.y = Float(item.angle * .pi / 180)
            scene.rootNode.addChildNode(n)
        }

        let robot = RobotSceneBuilder.robot()
        robot.name = "robot"
        robot.scale = SCNVector3(0.16, 0.16, 0.16)
        scene.rootNode.addChildNode(robot)
        place(robot, at: pose)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        // Fit the whole map, walls included, inside the view with a margin:
        // the field of view is set across the width (the narrow side on a
        // phone), and the camera stands back far enough that a sphere
        // around the map fits inside it from any angle.
        camera.camera?.projectionDirection = .horizontal
        camera.camera?.fieldOfView = 44
        let radius = Float((w * w + h * h).squareRoot() / 2) + 1
        let distance = radius / sin(Float(44.0 / 2 * .pi / 180)) * 1.08
        let direction = simd_normalize(SIMD3<Float>(0.15, 0.85, 0.75))
        camera.position = SCNVector3(direction * distance)
        camera.camera?.zFar = Double(distance * 3)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)

        view.scene = scene
        view.pointOfView = camera
    }

    private func place(_ robot: SCNNode, at pose: LivePose?) {
        if let pose {
            robot.isHidden = false
            robot.position = scenePoint(map.gridPoint(for: pose.position), y: 0.01)
            robot.eulerAngles.y = Float(pose.heading) - .pi / 2
        } else if let dock = map.dock {
            robot.isHidden = false
            robot.position = scenePoint(dock, y: 0.01)
        } else {
            robot.isHidden = true
        }
    }

    /// Grid point (y up) -> scene position on the floor, centred.
    private func scenePoint(_ p: MapPoint, y: Float) -> SCNVector3 {
        let u = Self.unit
        return SCNVector3(Float(p.x) * u - Float(map.width) * u / 2, y,
                          Float(map.height) * u / 2 - Float(p.y) * u)
    }

    static func height(forFurniture type: Int) -> Float {
        switch type {
        case 1, 2, 3: return 0.55          // beds
        case 4, 5, 31: return 0.75         // dining tables, desk
        case 6, 7, 9: return 0.45          // low tables
        case 10, 11, 12, 23: return 1.6    // cabinets, wardrobe, fridge
        case 13, 14, 15, 16, 30: return 0.8 // seating
        default: return 0.6
        }
    }

    /// Walls along the map's outer edges and obstacles: one merged mesh of
    /// pixel-sized blocks.
    private func wallGeometry() -> SCNGeometry? {
        let u = Self.unit, height: Float = 0.9
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        func isFloor(_ x: Int, _ y: Int) -> Bool {
            switch map.pixel(x: x, y: y) {
            case .unknown, .unassignedObstacle: return false
            default: return true
            }
        }

        func addBox(_ x: Int, _ y: Int) {
            let x0 = Float(x) * u - Float(map.width) * u / 2, x1 = x0 + u
            let z1 = Float(map.height) * u / 2 - Float(y) * u, z0 = z1 - u
            let faces: [([SCNVector3], SCNVector3)] = [
                ([SCNVector3(x0, height, z0), SCNVector3(x1, height, z0), SCNVector3(x1, height, z1), SCNVector3(x0, height, z1)], SCNVector3(0, 1, 0)),
                ([SCNVector3(x0, 0, z1), SCNVector3(x1, 0, z1), SCNVector3(x1, height, z1), SCNVector3(x0, height, z1)], SCNVector3(0, 0, 1)),
                ([SCNVector3(x1, 0, z0), SCNVector3(x0, 0, z0), SCNVector3(x0, height, z0), SCNVector3(x1, height, z0)], SCNVector3(0, 0, -1)),
                ([SCNVector3(x1, 0, z1), SCNVector3(x1, 0, z0), SCNVector3(x1, height, z0), SCNVector3(x1, height, z1)], SCNVector3(1, 0, 0)),
                ([SCNVector3(x0, 0, z0), SCNVector3(x0, 0, z1), SCNVector3(x0, height, z1), SCNVector3(x0, height, z0)], SCNVector3(-1, 0, 0)),
            ]
            for (corners, normal) in faces {
                let base = Int32(vertices.count)
                vertices += corners
                normals += Array(repeating: normal, count: 4)
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }

        for y in 0..<map.height {
            for x in 0..<map.width where !isFloor(x, y) {
                // A wall pixel borders floor on at least one side.
                if isFloor(x - 1, y) || isFloor(x + 1, y) || isFloor(x, y - 1) || isFloor(x, y + 1) {
                    addBox(x, y)
                }
            }
        }
        guard !vertices.isEmpty else { return nil }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [RobotSceneBuilder.pbr(UIColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1), metal: 0, rough: 0.7)]
        return geometry
    }
}
