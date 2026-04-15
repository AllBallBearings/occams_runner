import SwiftUI
import SceneKit

/// Displays a recorded route as an enhanced 3D scene using SceneKit.
/// The user can rotate, zoom, and examine the route including altitude changes.
struct Route3DView: View {
    let route: RecordedRoute
    @EnvironmentObject var dataStore: DataStore

    @State private var showQuestItems = true
    @State private var resetToken = 0

    var body: some View {
        VStack(spacing: 0) {
            Route3DSceneView(
                scene: buildScene(),
                resetToken: resetToken
            )
            .ignoresSafeArea(edges: .bottom)

            if !dataStore.quests(for: route.id).isEmpty {
                Toggle("Show Quest Items", isOn: $showQuestItems)
                    .padding()
                    .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("3D View")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { resetToken += 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset Camera")
            }
        }
    }

    // MARK: - Scene Building

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = makeGradientBackground()

        guard route.points.count >= 2 else { return scene }

        let normalized = normalizePoints()

        addNeonGrid(to: scene, points: normalized)
        addElevationCurtain(to: scene, points: normalized)
        addRoutePath(to: scene, points: normalized)
        addStartEndMarkers(to: scene, points: normalized)
        addAnimatedRunner(to: scene, points: normalized)

        if showQuestItems {
            addQuestItems(to: scene, points: normalized)
        }

        // Lighting
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 200
        ambient.light?.color = UIColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 500
        directional.light?.color = UIColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1)
        directional.position = SCNVector3(10, 20, 10)
        directional.look(at: .init(0, 0, 0))
        scene.rootNode.addChildNode(directional)

        // Camera
        let xs = normalized.map(\.x)
        let zs = normalized.map(\.z)
        let ys = normalized.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2
        let cz = (zs.min()! + zs.max()!) / 2
        let cy = (ys.min()! + ys.max()!) / 2
        let span = max(xs.max()! - xs.min()!, zs.max()! - zs.min()!, 10)

        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.zFar = 500
        camNode.camera?.zNear = 0.1
        camNode.position = SCNVector3(cx, cy + span * 0.7, cz + span * 0.9)
        camNode.look(at: SCNVector3(cx, cy * 0.3, cz))
        scene.rootNode.addChildNode(camNode)

        return scene
    }

    // MARK: - Normalized points

    private struct NormalizedPoint {
        let x: Float
        let y: Float // altitude
        let z: Float
    }

    private func normalizePoints() -> [NormalizedPoint] {
        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        let alts = route.points.map(\.altitude)

        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let minAlt = alts.min()!,  maxAlt = alts.max()!

        let maxRange = max(maxLat - minLat, maxLon - minLon)
        let scale: Double    = maxRange > 0 ? 30.0 / maxRange : 1.0
        let altRange: Double = max(maxAlt - minAlt, 1.0)
        let altScale: Double = 10.0 / altRange

        return route.points.map { pt in
            NormalizedPoint(
                x: Float((pt.longitude - minLon) * scale),
                y: Float((pt.altitude  - minAlt) * altScale),
                z: Float(-(pt.latitude - minLat) * scale)
            )
        }
    }

    // MARK: - Background gradient

    private func makeGradientBackground() -> UIImage {
        let size = CGSize(width: 1, height: 256)
        UIGraphicsBeginImageContext(size)
        let ctx = UIGraphicsGetCurrentContext()!
        let colors: [UIColor] = [
            UIColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 1),
            UIColor(red: 0.05, green: 0.08, blue: 0.22, alpha: 1)
        ]
        let locs: [CGFloat] = [0, 1]
        let cgColors = colors.map(\.cgColor) as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locs)!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end:   CGPoint(x: 0, y: size.height),
                               options: [])
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }

    // MARK: - Neon grid ground plane

    private func addNeonGrid(to scene: SCNScene, points: [NormalizedPoint]) {
        let xs = points.map(\.x)
        let zs = points.map(\.z)
        let minX = xs.min()! - 3, maxX = xs.max()! + 3
        let minZ = zs.min()! - 3, maxZ = zs.max()! + 3
        let gridY: Float = -0.05

        let gridColor = UIColor(red: 0.10, green: 0.80, blue: 0.60, alpha: 0.45)
        let accentColor = UIColor(red: 0.10, green: 0.80, blue: 0.60, alpha: 0.90)

        let step: Float = 5.0
        var xLines: [Float] = []
        var zLines: [Float] = []
        var v = minX - fmod(minX, step)
        while v <= maxX { xLines.append(v); v += step }
        v = minZ - fmod(minZ, step)
        while v <= maxZ { zLines.append(v); v += step }

        let lenZ = CGFloat(maxZ - minZ)
        let lenX = CGFloat(maxX - minX)

        for xPos in xLines {
            let box = SCNBox(width: 0.03, height: 0.02, length: lenZ, chamferRadius: 0)
            let col = xPos.truncatingRemainder(dividingBy: step * 2) == 0 ? accentColor : gridColor
            box.firstMaterial?.diffuse.contents  = col
            box.firstMaterial?.emission.contents = col
            box.firstMaterial?.isDoubleSided = true
            let n = SCNNode(geometry: box)
            n.position = SCNVector3(xPos, gridY, (minZ + maxZ) / 2)
            scene.rootNode.addChildNode(n)
        }
        for zPos in zLines {
            let box = SCNBox(width: lenX, height: 0.02, length: 0.03, chamferRadius: 0)
            let col = zPos.truncatingRemainder(dividingBy: step * 2) == 0 ? accentColor : gridColor
            box.firstMaterial?.diffuse.contents  = col
            box.firstMaterial?.emission.contents = col
            box.firstMaterial?.isDoubleSided = true
            let n = SCNNode(geometry: box)
            n.position = SCNVector3((minX + maxX) / 2, gridY, zPos)
            scene.rootNode.addChildNode(n)
        }
    }

    // MARK: - Elevation curtain

    private func addElevationCurtain(to scene: SCNScene, points: [NormalizedPoint]) {
        // Subsample — draw a curtain drop every ~3 points for performance
        let stride = max(1, points.count / 80)
        for i in Swift.stride(from: 0, to: points.count, by: stride) {
            let pt = points[i]
            guard pt.y > 0.2 else { continue }

            let t = CGFloat(pt.y / 10.0).clamped(to: 0...1)
            let curtainColor = UIColor(
                red:   0.10 + 0.50 * t,
                green: 0.55 - 0.20 * t,
                blue:  0.90 - 0.70 * t,
                alpha: 0.20)

            let box = SCNBox(width: 0.05, height: CGFloat(pt.y), length: 0.05, chamferRadius: 0)
            box.firstMaterial?.diffuse.contents  = curtainColor
            box.firstMaterial?.emission.contents = curtainColor
            box.firstMaterial?.isDoubleSided = true
            box.firstMaterial?.transparency = 0.6

            let n = SCNNode(geometry: box)
            n.position = SCNVector3(pt.x, pt.y / 2, pt.z)
            scene.rootNode.addChildNode(n)
        }
    }

    // MARK: - Route path (glowing tube)

    private func addRoutePath(to scene: SCNScene, points: [NormalizedPoint]) {
        for i in 1..<points.count {
            let p1 = points[i - 1], p2 = points[i]
            let dx = p2.x - p1.x, dy = p2.y - p1.y, dz = p2.z - p1.z
            let length = sqrt(dx*dx + dy*dy + dz*dz)
            guard length > 0.001 else { continue }

            let t = CGFloat(p1.y / 10.0).clamped(to: 0...1)
            let segColor: UIColor
            if t < 0.5 {
                segColor = UIColor(red: 0.10, green: 0.50 + 0.40 * (t * 2),
                                   blue: 1.0 - t, alpha: 1)
            } else {
                let tt = (t - 0.5) * 2
                segColor = UIColor(red: 0.20 + 0.75 * tt,
                                   green: 0.90 - 0.50 * tt,
                                   blue: 0.50 - 0.40 * tt, alpha: 1)
            }

            // Core tube
            let tube = SCNCylinder(radius: 0.10, height: CGFloat(length))
            tube.firstMaterial?.diffuse.contents  = segColor
            tube.firstMaterial?.emission.contents = segColor.withAlphaComponent(0.7)
            tube.firstMaterial?.specular.contents = UIColor.white

            let node = SCNNode(geometry: tube)
            node.position = SCNVector3((p1.x+p2.x)/2, (p1.y+p2.y)/2, (p1.z+p2.z)/2)
            node.look(at: SCNVector3(p2.x, p2.y, p2.z))
            node.eulerAngles.x += .pi / 2
            scene.rootNode.addChildNode(node)

            // Outer glow halo — wider, very transparent
            let halo = SCNCylinder(radius: 0.22, height: CGFloat(length))
            halo.firstMaterial?.diffuse.contents  = segColor.withAlphaComponent(0.0)
            halo.firstMaterial?.emission.contents = segColor.withAlphaComponent(0.18)
            halo.firstMaterial?.isDoubleSided = true

            let haloNode = SCNNode(geometry: halo)
            haloNode.position = node.position
            haloNode.eulerAngles = node.eulerAngles
            scene.rootNode.addChildNode(haloNode)
        }
    }

    // MARK: - Start / End markers

    private func addStartEndMarkers(to scene: SCNScene, points: [NormalizedPoint]) {
        addFlagMarker(to: scene, at: points.first!, color: UIColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1), label: "S")
        addFlagMarker(to: scene, at: points.last!,  color: UIColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1), label: "E")
    }

    private func addFlagMarker(to scene: SCNScene, at point: NormalizedPoint, color: UIColor, label: String) {
        // Glowing base sphere
        let sphere = SCNSphere(radius: 0.45)
        sphere.firstMaterial?.diffuse.contents  = color
        sphere.firstMaterial?.emission.contents = color.withAlphaComponent(0.8)
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.position = SCNVector3(point.x, point.y + 0.45, point.z)
        scene.rootNode.addChildNode(sphereNode)

        // Vertical post
        let post = SCNCylinder(radius: 0.06, height: 2.0)
        post.firstMaterial?.diffuse.contents  = color.withAlphaComponent(0.7)
        post.firstMaterial?.emission.contents = color.withAlphaComponent(0.3)
        let postNode = SCNNode(geometry: post)
        postNode.position = SCNVector3(point.x, point.y + 1.9, point.z)
        scene.rootNode.addChildNode(postNode)

        // Small flag plane
        let flag = SCNPlane(width: 0.8, height: 0.5)
        flag.firstMaterial?.diffuse.contents  = color
        flag.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
        flag.firstMaterial?.isDoubleSided = true
        let flagNode = SCNNode(geometry: flag)
        flagNode.position = SCNVector3(point.x + 0.45, point.y + 2.65, point.z)
        scene.rootNode.addChildNode(flagNode)

        // Label
        let text = SCNText(string: label, extrusionDepth: 0.05)
        text.font = UIFont.boldSystemFont(ofSize: 0.6)
        text.firstMaterial?.diffuse.contents  = color
        text.firstMaterial?.emission.contents = color
        let textNode = SCNNode(geometry: text)
        textNode.position = SCNVector3(point.x + 0.18, point.y + 2.45, point.z + 0.1)
        textNode.scale = SCNVector3(0.7, 0.7, 0.7)
        scene.rootNode.addChildNode(textNode)
    }

    // MARK: - Animated runner sphere

    private func addAnimatedRunner(to scene: SCNScene, points: [NormalizedPoint]) {
        guard points.count >= 2 else { return }

        // Sample evenly — keep ≤60 key positions for smooth animation
        let count  = min(points.count, 60)
        let stride = max(1, points.count / count)
        var keyPts: [NormalizedPoint] = []
        for i in Swift.stride(from: 0, to: points.count, by: stride) { keyPts.append(points[i]) }
        if keyPts.last.map({ $0.x != points.last!.x }) ?? true { keyPts.append(points.last!) }

        // Runner: bright cyan glowing sphere
        let sphere = SCNSphere(radius: 0.28)
        sphere.firstMaterial?.diffuse.contents  = UIColor(red: 0.10, green: 0.95, blue: 1.00, alpha: 1)
        sphere.firstMaterial?.emission.contents = UIColor(red: 0.10, green: 0.95, blue: 1.00, alpha: 1)

        // Outer pulse halo
        let halo = SCNSphere(radius: 0.50)
        halo.firstMaterial?.diffuse.contents  = UIColor.clear
        halo.firstMaterial?.emission.contents = UIColor(red: 0.10, green: 0.95, blue: 1.00, alpha: 0.25)
        halo.firstMaterial?.isDoubleSided = true

        let runner   = SCNNode(geometry: sphere)
        let haloNode = SCNNode(geometry: halo)
        runner.addChildNode(haloNode)
        runner.position = SCNVector3(keyPts[0].x, keyPts[0].y + 0.3, keyPts[0].z)
        scene.rootNode.addChildNode(runner)

        // Pulse animation on halo
        let pulse = CABasicAnimation(keyPath: "scale")
        pulse.fromValue  = NSValue(scnVector3: SCNVector3(1, 1, 1))
        pulse.toValue    = NSValue(scnVector3: SCNVector3(1.6, 1.6, 1.6))
        pulse.duration   = 0.9
        pulse.autoreverses = true
        pulse.repeatCount  = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloNode.addAnimation(pulse, forKey: "pulse")

        // Position keyframe animation along route
        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.values = keyPts.map {
            NSValue(scnVector3: SCNVector3($0.x, $0.y + 0.3, $0.z))
        }
        let dur: Double = Double(keyPts.count) * 0.18
        posAnim.duration    = dur
        posAnim.repeatCount = .infinity
        posAnim.calculationMode = .catmullRom
        runner.addAnimation(posAnim, forKey: "run")
    }

    // MARK: - Quest coin items

    private func addQuestItems(to scene: SCNScene, points: [NormalizedPoint]) {
        let quests = dataStore.quests(for: route.id)
        guard let quest = quests.first else { return }

        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        let alts = route.points.map(\.altitude)

        let minLat = lats.min()!, minLon = lons.min()!, minAlt = alts.min()!
        let maxRange = max(lats.max()! - minLat, lons.max()! - minLon)
        let scale: Double = maxRange > 0 ? 30.0 / maxRange : 1.0
        let altScale: Double = 10.0 / max(alts.max()! - minAlt, 1.0)

        for item in quest.items {
            guard let geo = route.geoSample(atProgress: item.routeProgress) else { continue }

            let x = Float((geo.longitude - minLon) * scale)
            let y = Float(((geo.altitude + item.verticalOffset) - minAlt) * altScale) + 0.5
            let z = Float(-(geo.latitude - minLat) * scale)

            let container = SCNNode()
            container.position = SCNVector3(x, y, z)

            let coin = SCNCylinder(radius: 0.22, height: 0.05)
            let coinColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
            coin.firstMaterial?.diffuse.contents  = coinColor
            coin.firstMaterial?.emission.contents = UIColor(red: 0.9, green: 0.65, blue: 0.0, alpha: 0.6)
            coin.firstMaterial?.specular.contents = UIColor.white
            coin.firstMaterial?.isDoubleSided = true

            let disc = SCNNode(geometry: coin)
            disc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            container.addChildNode(disc)

            let spin = CABasicAnimation(keyPath: "rotation")
            spin.toValue    = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
            spin.duration   = 2
            spin.repeatCount = .infinity
            container.addAnimation(spin, forKey: "spin")

            container.opacity = item.collected ? 0.25 : 1.0
            scene.rootNode.addChildNode(container)
        }
    }
}

// MARK: - CGFloat clamping helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - SCNView wrapper with reset support

private struct Route3DSceneView: UIViewRepresentable {
    let scene: SCNScene
    let resetToken: Int

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl    = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 1)
        scnView.antialiasingMode = .multisampling4X
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        scnView.scene = scene
    }
}
