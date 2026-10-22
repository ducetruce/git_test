import SceneKit
import SwiftUI
import UIKit

/// The robot and its station as a live 3D model (SceneKit), modelled on the
/// Freo Z10 Ultra from the owner's photos. Drag to turn it; the lidar ring
/// glows in the robot's status colour.
struct RobotModelView: UIViewRepresentable {
    enum Shot { case docked, robot, station }
    enum Mood: Equatable { case idle, cleaning, charging, attention }

    var shot: Shot = .docked
    var mood: Mood = .idle

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.maximumVerticalAngle = 35
        view.defaultCameraController.minimumVerticalAngle = 5
        view.isJitteringEnabled = true
        let scene = RobotSceneBuilder.scene(for: shot)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        RobotSceneBuilder.apply(mood, to: scene)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if let scene = view.scene { RobotSceneBuilder.apply(mood, to: scene) }
    }
}

enum RobotSceneBuilder {
    static func scene(for shot: RobotModelView.Shot) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = environmentImage()
        scene.lightingEnvironment.intensity = 1.4
        addLights(to: scene.rootNode)
        addFloor(to: scene.rootNode)

        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 26
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        scene.rootNode.addChildNode(camera)

        switch shot {
        case .robot:
            let r = robot()
            r.eulerAngles.y = 0.35
            scene.rootNode.addChildNode(r)
            camera.camera?.fieldOfView = 24
            camera.position = SCNVector3(4.4, 4.0, 8.0)
            camera.look(at: SCNVector3(0, 0.3, 0))
        case .station:
            scene.rootNode.addChildNode(station())
            let r = robot()
            r.position = SCNVector3(0, 0.09, 0.35)
            scene.rootNode.addChildNode(r)
            camera.position = SCNVector3(5.0, 5.4, 15.5)
            camera.look(at: SCNVector3(0, 2.3, 0.4))
        case .docked:
            let group = SCNNode()
            group.addChildNode(station())
            let r = robot()
            r.position = SCNVector3(0, 0.09, 0.35)
            group.addChildNode(r)
            group.eulerAngles.y = -0.5
            scene.rootNode.addChildNode(group)
            camera.position = SCNVector3(6.0, 5.8, 14.0)
            camera.look(at: SCNVector3(-0.2, 2.2, 0.4))
        }
        return scene
    }

    /// The lidar ring's glow follows the robot's state.
    static func apply(_ mood: RobotModelView.Mood, to scene: SCNScene) {
        let color: UIColor
        switch mood {
        case .idle: color = UIColor(red: 0.42, green: 0.36, blue: 1.0, alpha: 1)
        case .cleaning: color = UIColor(red: 0.53, green: 0.84, blue: 0.78, alpha: 1)
        case .charging: color = UIColor(red: 0.62, green: 0.77, blue: 1.0, alpha: 1)
        case .attention: color = UIColor(red: 0.94, green: 0.66, blue: 0.35, alpha: 1)
        }
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == "statusRing" {
                node.geometry?.firstMaterial?.emission.contents = color
                node.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }

    // MARK: Materials

    static func pbr(_ color: UIColor, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    static let titanium = pbr(UIColor(red: 0.45, green: 0.47, blue: 0.51, alpha: 1), metal: 0.55, rough: 0.32)
    static let coverGrey = pbr(UIColor(red: 0.53, green: 0.55, blue: 0.58, alpha: 1), metal: 0.3, rough: 0.48)
    static let glossBlack = pbr(UIColor(white: 0.02, alpha: 1), metal: 0.2, rough: 0.08)
    static let silver = pbr(UIColor(red: 0.83, green: 0.84, blue: 0.86, alpha: 1), metal: 0.95, rough: 0.22)
    static let brushed = pbr(UIColor(red: 0.71, green: 0.73, blue: 0.75, alpha: 1), metal: 0.95, rough: 0.26)
    static let graphite = pbr(UIColor(red: 0.29, green: 0.31, blue: 0.34, alpha: 1), metal: 0.35, rough: 0.42)
    static let graphiteDark = pbr(UIColor(red: 0.17, green: 0.18, blue: 0.21, alpha: 1), metal: 0.3, rough: 0.55)
    static let ramp = pbr(UIColor(red: 0.6, green: 0.63, blue: 0.66, alpha: 1), metal: 0.2, rough: 0.3)

    static func glow(_ color: UIColor) -> SCNMaterial {
        let m = pbr(color, metal: 0, rough: 0.2)
        m.emission.contents = color
        return m
    }

    // MARK: Robot

    static func node(_ geometry: SCNGeometry, _ material: SCNMaterial, _ position: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.position = position
        n.castsShadow = true
        return n
    }

    /// A puck with rounded top and bottom edges.
    static func puck(radius r: CGFloat, height h: CGFloat, fillet f: CGFloat, material: SCNMaterial) -> SCNNode {
        let g = SCNNode()
        g.addChildNode(node(SCNCylinder(radius: r - f, height: h), material, SCNVector3(0, Float(h / 2), 0)))
        g.addChildNode(node(SCNCylinder(radius: r, height: h - 2 * f), material, SCNVector3(0, Float(h / 2), 0)))
        for y in [f, h - f] {
            let torus = SCNTorus(ringRadius: r - f, pipeRadius: f)
            torus.ringSegmentCount = 120
            g.addChildNode(node(torus, material, SCNVector3(0, Float(y), 0)))
        }
        return g
    }

    static func robot() -> SCNNode {
        let g = SCNNode()
        let R: CGFloat = 1.75, h: CGFloat = 0.56
        g.addChildNode(puck(radius: R, height: h, fillet: 0.14, material: titanium))
        let cover = SCNCylinder(radius: 1.55, height: 0.04)
        cover.radialSegmentCount = 120
        g.addChildNode(node(cover, coverGrey, SCNVector3(0, Float(h + 0.015), 0)))
        // Front camera window with two lenses (front is +z).
        let window = SCNBox(width: 0.78, height: 0.17, length: 0.1, chamferRadius: 0.05)
        g.addChildNode(node(window, glossBlack, SCNVector3(0, 0.28, Float(R - 0.02))))
        for x: Float in [-0.27, 0.27] {
            let lens = SCNCylinder(radius: 0.045, height: 0.04)
            let n = node(lens, silver, SCNVector3(x, 0.28, Float(R + 0.03)))
            n.eulerAngles.x = .pi / 2
            g.addChildNode(n)
        }
        // Lidar turret toward the back: silver base, status ring, silver cap.
        let tz: Float = -0.62
        g.addChildNode(node(SCNCylinder(radius: 0.45, height: 0.05), silver, SCNVector3(0, Float(h) + 0.07, tz)))
        let ring = node(SCNCylinder(radius: 0.4, height: 0.12), glow(.systemPurple), SCNVector3(0, Float(h) + 0.155, tz))
        ring.name = "statusRing"
        g.addChildNode(ring)
        g.addChildNode(node(SCNCylinder(radius: 0.43, height: 0.07), silver, SCNVector3(0, Float(h) + 0.25, tz)))
        g.addChildNode(node(SCNCylinder(radius: 0.3, height: 0.01), brushed, SCNVector3(0, Float(h) + 0.29, tz)))
        return g
    }

    // MARK: Station

    static func station() -> SCNNode {
        let g = SCNNode()
        let W: CGFloat = 4.2, H: CGFloat = 4.9, D: CGFloat = 4.2, bay: CGFloat = 1.5
        // Upper housing over an open docking bay.
        g.addChildNode(node(SCNBox(width: W, height: H - bay, length: D, chamferRadius: 0.36), graphite,
                            SCNVector3(0, Float(bay + (H - bay) / 2), 0)))
        g.addChildNode(node(SCNBox(width: W - 0.36, height: bay + 0.3, length: 1.0, chamferRadius: 0.1), graphiteDark,
                            SCNVector3(0, Float(bay / 2), Float(-D / 2 + 0.6))))
        for side: Float in [-1, 1] {
            g.addChildNode(node(SCNBox(width: 0.14, height: bay + 0.3, length: D - 0.6, chamferRadius: 0.06), graphiteDark,
                                SCNVector3(side * Float(W / 2 - 0.32), Float(bay / 2), -0.1)))
        }
        // Brushed silver door across the upper front.
        let doorH = H - bay - 0.5
        g.addChildNode(node(SCNBox(width: W - 0.3, height: doorH, length: 0.12, chamferRadius: 0.08), brushed,
                            SCNVector3(0, Float(bay + 0.2 + doorH / 2), Float(D / 2 + 0.02))))
        // Vertical blue light at the right of the door.
        g.addChildNode(node(SCNBox(width: 0.07, height: 0.6, length: 0.04, chamferRadius: 0.03),
                            glow(UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1)),
                            SCNVector3(Float(W / 2 - 0.5), Float(bay + 2.05), Float(D / 2 + 0.1))))
        // Round port on top, back right, and side handle recesses.
        g.addChildNode(node(SCNCylinder(radius: 0.34, height: 0.03), glossBlack,
                            SCNVector3(Float(W / 2 - 0.9), Float(H) + 0.005, Float(-D / 2 + 0.9))))
        for side: Float in [-1, 1] {
            g.addChildNode(node(SCNBox(width: 0.04, height: 0.34, length: 1.0, chamferRadius: 0.02), graphiteDark,
                                SCNVector3(side * Float(W / 2 + 0.002), Float(H - 0.65), -0.3)))
        }
        // Ramp in the bay.
        g.addChildNode(node(SCNBox(width: W - 0.7, height: 0.06, length: D - 0.6, chamferRadius: 0.03), ramp,
                            SCNVector3(0, 0.03, 0.4)))
        return g
    }

    // MARK: Light and floor

    static func addLights(to root: SCNNode) {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 10
        key.light?.shadowSampleCount = 16
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.6)
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.light?.orthographicScale = 9
        key.position = SCNVector3(-4, 9, 6)
        key.look(at: SCNVector3Zero)
        root.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 700
        rim.light?.color = UIColor(red: 0.62, green: 0.85, blue: 1, alpha: 1)
        rim.position = SCNVector3(5, 4, -7)
        rim.look(at: SCNVector3Zero)
        root.addChildNode(rim)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 180
        ambient.light?.color = UIColor(red: 0.8, green: 0.85, blue: 1, alpha: 1)
        root.addChildNode(ambient)
    }

    /// An invisible floor that only shows shadows.
    static func addFloor(to root: SCNNode) {
        let floor = SCNFloor()
        floor.reflectivity = 0
        let m = SCNMaterial()
        m.lightingModel = .shadowOnly
        floor.materials = [m]
        root.addChildNode(SCNNode(geometry: floor))
    }

    /// A soft studio environment for reflections: bright overhead, dark below.
    static func environmentImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor, UIColor(white: 0.55, alpha: 1).cgColor,
                          UIColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.45, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Two soft-box highlights.
            UIColor(white: 1, alpha: 0.9).setFill()
            ctx.cgContext.fill(CGRect(x: 40, y: 18, width: 50, height: 14))
            ctx.cgContext.fill(CGRect(x: 160, y: 24, width: 36, height: 10))
        }
    }
}
