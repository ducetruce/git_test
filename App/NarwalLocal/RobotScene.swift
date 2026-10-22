import SceneKit
import simd
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
            r.position = SCNVector3(0, 0.06, 1.45)
            scene.rootNode.addChildNode(r)
            camera.position = SCNVector3(4.0, 5.2, 14.5)
            camera.look(at: SCNVector3(0, 1.8, 0.8))
        case .docked:
            let group = SCNNode()
            group.addChildNode(station())
            let r = robot()
            r.position = SCNVector3(0, 0.06, 1.45)
            group.addChildNode(r)
            group.eulerAngles.y = -0.5
            scene.rootNode.addChildNode(group)
            // A little wider than tight framing, so the dock's tray and
            // shadow don't reach the edge of the view.
            camera.camera?.fieldOfView = 29
            camera.position = SCNVector3(6.0, 5.6, 14.0)
            camera.look(at: SCNVector3(-0.2, 1.8, 0.6))
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

    // MARK: Materials (satin plastics; brushed metal only on the station's face)

    static func pbr(_ color: UIColor, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let plasticGrey = pbr(rgb(0x6C7179), metal: 0, rough: 0.4)
    static let plasticTop = pbr(rgb(0x777C84), metal: 0, rough: 0.48)
    static let plasticDark = pbr(rgb(0x3A3E45), metal: 0, rough: 0.4)
    static let stationPlastic = pbr(rgb(0x4A515B), metal: 0, rough: 0.42)
    static let lidPlastic = pbr(rgb(0x5E656E), metal: 0, rough: 0.55)
    static let stationDark = pbr(rgb(0x2A2D32), metal: 0, rough: 0.6)
    static let glossBlack = pbr(rgb(0x050607), metal: 0.2, rough: 0.08)
    static let capSilver = pbr(rgb(0xC9CCD1), metal: 0.45, rough: 0.3)
    static let faceMetal = pbr(rgb(0x8A919A), metal: 0.8, rough: 0.34)
    static let lensMetal = pbr(rgb(0x1A1D22), metal: 0.6, rough: 0.1)
    static let clearTray: SCNMaterial = {
        let m = pbr(rgb(0xC9CDD8), metal: 0, rough: 0.15)
        m.transparency = 0.35
        m.isDoubleSided = true
        return m
    }()

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

    /// The Freo Z10 Ultra: a tall satin-grey puck, flat top with a fine seam,
    /// a dark front panel with the camera window, and the lidar turret in
    /// the middle (grey base, glowing ring, silver cap). Front is +z.
    static func robot() -> SCNNode {
        let g = SCNNode()
        let R: CGFloat = 1.75, h: CGFloat = 0.82
        g.addChildNode(puck(radius: R, height: h, fillet: 0.16, material: plasticGrey))
        let cover = SCNCylinder(radius: 1.6, height: 0.012)
        cover.radialSegmentCount = 120
        g.addChildNode(node(cover, plasticTop, SCNVector3(0, Float(h) + 0.004, 0)))
        let seam = SCNTorus(ringRadius: 1.6, pipeRadius: 0.008)
        seam.ringSegmentCount = 160
        g.addChildNode(node(seam, plasticDark, SCNVector3(0, Float(h) + 0.008, 0)))
        // Dark front panel: a short arc of wall just proud of the body.
        let panel = SCNNode(geometry: arcWall(radius: Float(R) + 0.006, height: 0.36, from: -0.5, to: 0.5))
        panel.geometry?.materials = [plasticDark]
        panel.position = SCNVector3(0, 0.22, 0)
        g.addChildNode(panel)
        g.addChildNode(node(SCNBox(width: 0.8, height: 0.18, length: 0.08, chamferRadius: 0.05), glossBlack,
                            SCNVector3(0, 0.4, Float(R) - 0.005)))
        for x: Float in [-0.27, 0.27] {
            let n = node(SCNCylinder(radius: 0.045, height: 0.03), lensMetal, SCNVector3(x, 0.4, Float(R) + 0.04))
            n.eulerAngles.x = .pi / 2
            g.addChildNode(n)
        }
        // Lidar turret, centred.
        g.addChildNode(node(SCNCylinder(radius: 0.49, height: 0.08), plasticGrey, SCNVector3(0, Float(h) + 0.05, 0)))
        let ring = node(SCNCylinder(radius: 0.43, height: 0.16), glow(.systemPurple), SCNVector3(0, Float(h) + 0.17, 0))
        ring.name = "statusRing"
        g.addChildNode(ring)
        g.addChildNode(node(SCNCylinder(radius: 0.47, height: 0.09), capSilver, SCNVector3(0, Float(h) + 0.295, 0)))
        return g
    }

    /// A vertical strip of cylinder wall between two angles (radians from
    /// +z, i.e. the front), facing outward.
    static func arcWall(radius r: Float, height: Float, from a0: Float, to a1: Float, segments: Int = 40) -> SCNGeometry {
        var v: [SCNVector3] = [], n: [SCNVector3] = [], idx: [Int32] = []
        for i in 0...segments {
            let a = a0 + (a1 - a0) * Float(i) / Float(segments)
            let normal = SCNVector3(sin(a), 0, cos(a))
            v += [SCNVector3(r * sin(a), 0, r * cos(a)), SCNVector3(r * sin(a), height, r * cos(a))]
            n += [normal, normal]
        }
        for i in 0..<segments {
            let b = Int32(i * 2)
            idx += [b, b + 2, b + 1, b + 1, b + 2, b + 3]
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: n)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    // MARK: Station

    /// The footprint: a squircle whose front (+z) bulges forward.
    static func footprint(_ t: Float, _ scale: Float) -> (Float, Float) {
        let a: Float = 1.85, back: Float = 1.85, front: Float = 2.05, e: Float = 2 / 3.2
        let c = cos(t), s = sin(t)
        let x = a * (c < 0 ? -1 : 1) * pow(abs(c), e)
        let z = (s > 0 ? front : back) * (s < 0 ? -1 : 1) * pow(abs(s), e)
        return (x * scale, z * scale)
    }

    /// A surface swept around the footprint from t0 to t1 (front is pi/2)
    /// through rings of (height, scale), with outward normals.
    static func loft(_ t0: Float, _ t1: Float, _ rings: [(Float, Float)], segments: Int = 160) -> SCNGeometry {
        var v: [SCNVector3] = [], idx: [Int32] = []
        for i in 0...segments {
            let t = t0 + (t1 - t0) * Float(i) / Float(segments)
            for (y, sc) in rings {
                let (x, z) = footprint(t, sc)
                v.append(SCNVector3(x, y, z))
            }
        }
        let R = rings.count
        for i in 0..<segments {
            for j in 0..<(R - 1) {
                let a = Int32(i * R + j), b = Int32((i + 1) * R + j)
                idx += [a, a + 1, b, b, a + 1, b + 1]
            }
        }
        // Smooth normals: average the faces around each vertex.
        var normals = Array(repeating: SIMD3<Float>(0, 0, 0), count: v.count)
        for k in stride(from: 0, to: idx.count, by: 3) {
            let (i0, i1, i2) = (Int(idx[k]), Int(idx[k + 1]), Int(idx[k + 2]))
            let p0 = SIMD3(v[i0].x, v[i0].y, v[i0].z), p1 = SIMD3(v[i1].x, v[i1].y, v[i1].z), p2 = SIMD3(v[i2].x, v[i2].y, v[i2].z)
            let fn = simd_cross(p1 - p0, p2 - p0)
            normals[i0] += fn; normals[i1] += fn; normals[i2] += fn
        }
        let n = normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0) }.map { SCNVector3($0.x, $0.y, $0.z) }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: n)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// A flat, upward-facing cap of the footprint at height y.
    static func cap(_ y: Float, _ scale: Float, segments: Int = 160) -> SCNGeometry {
        var v = [SCNVector3(0, y, 0)], idx: [Int32] = []
        for i in 0...segments {
            let (x, z) = footprint(Float(i) / Float(segments) * 2 * .pi, scale)
            v.append(SCNVector3(x, y, z))
        }
        for i in 1...segments { idx += [0, Int32(i + 1), Int32(i)] }
        let n = Array(repeating: SCNVector3(0, 1, 0), count: v.count)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: n)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// Rings along a quarter circle from (y0, r0) to (y1, r1): a rounded edge.
    static func arc(_ steps: Int, _ r0: Float, _ r1: Float, _ y0: Float, _ y1: Float) -> [(Float, Float)] {
        (0...steps).map { i in
            let a = Float(i) / Float(steps) * .pi / 2
            return (y0 + (y1 - y0) * sin(a), r0 + (r1 - r0) * (1 - cos(a)))
        }
    }

    /// The station: a slate plastic body on a squircle footprint, a pillow
    /// lid with a groove and port, a curved metal front, a low bay and a
    /// clear tray reaching out in front.
    static func station() -> SCNNode {
        let g = SCNNode()
        let H: Float = 4.0, bay: Float = 1.2, lidY = H - 0.32
        let front: (Float, Float) = (.pi / 2 - 1.05, .pi / 2 + 1.05)
        func add(_ geo: SCNGeometry, _ m: SCNMaterial) {
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.castsShadow = true
            g.addChildNode(n)
        }
        add(loft(0, 2 * .pi, [(bay, 1.0), (lidY - 0.08, 1.0), (lidY, 0.985)], segments: 240), stationPlastic)
        add(loft(front.1 - 0.12, 2 * .pi + front.0 + 0.12, [(0.06, 0.975), (bay, 1.0)], segments: 200), stationPlastic)
        add(cap(bay, 0.985), stationDark)
        add(loft(0, 2 * .pi, [(0.06, 0.8), (bay, 0.8)]), stationDark)
        add(loft(front.0, front.1, [(bay + 0.12, 1.0), (bay + 0.2, 1.012)] + arc(4, 1.012, 1.0, lidY - 0.42, lidY - 0.12)), faceMetal)
        add(loft(0, 2 * .pi, [(lidY, 0.96), (lidY + 0.04, 0.96)], segments: 200), glossBlack)
        add(loft(0, 2 * .pi, [(lidY + 0.04, 0.985)] + arc(6, 0.985, 0.92, lidY + 0.04, H), segments: 220), lidPlastic)
        add(cap(H, 0.92), lidPlastic)

        // Port on the lid (back right) and the light slot near the face's top right.
        g.addChildNode(node(SCNCylinder(radius: 0.3, height: 0.03), glossBlack, SCNVector3(1.1, H + 0.01, -1.0)))
        let (lx, lz) = footprint(.pi / 2 - 0.82, 1.02)
        let light = node(SCNBox(width: 0.06, height: 0.55, length: 0.04, chamferRadius: 0.03),
                         glow(UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1)), SCNVector3(lx, lidY - 0.75, lz))
        light.look(at: SCNVector3(lx * 2, lidY - 0.75, lz * 2))
        g.addChildNode(light)
        for side: Float in [-1, 1] {
            let (hx, hz) = footprint(side > 0 ? 0 : .pi, 1.003)
            g.addChildNode(node(SCNBox(width: 0.04, height: 0.26, length: 0.7, chamferRadius: 0.02), stationDark,
                                SCNVector3(hx, lidY - 0.45, hz - 0.5)))
        }
        // Clear tray.
        let tray = SCNNode(geometry: cap(0.04, 1.0))
        tray.geometry?.materials = [clearTray]
        tray.scale = SCNVector3(1.04, 1, 1.45)
        tray.position = SCNVector3(0, 0, 0.75)
        g.addChildNode(tray)
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
