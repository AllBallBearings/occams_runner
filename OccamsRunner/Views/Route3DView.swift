import SwiftUI
import SceneKit

/// Displays a recorded route as a 3D model using SceneKit.
/// The user can rotate, zoom, and examine the route including altitude changes.
struct Route3DView: View {
    let route: RecordedRoute
    @EnvironmentObject var dataStore: DataStore

    @State private var showQuestItems = true

    var body: some View {
        VStack(spacing: 0) {
            SceneView(
                scene: buildScene(),
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
            .ignoresSafeArea(edges: .bottom)

            // Toggle quest items visibility
            if !dataStore.quests(for: route.id).isEmpty {
                Toggle("Show Quest Items", isOn: $showQuestItems)
                    .padding()
                    .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("3D View")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Scene Building

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1.0)

        guard route.points.count >= 2 else { return scene }

        // Normalize coordinates to scene space
        let normalized = normalizePoints()

        // Build route path as a tube/line
        addRoutePath(to: scene, points: normalized)

        // Add start/end markers
        addMarker(to: scene, at: normalized.first!, color: .green, label: "START")
        addMarker(to: scene, at: normalized.last!, color: .red, label: "END")

        // Add altitude grid/reference plane
        addGroundPlane(to: scene, points: normalized)

        // Add quest items if visible
        if showQuestItems {
            addQuestItems(to: scene, points: normalized)
        }

        // Position camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 500
        let center = normalized[normalized.count / 2]
        cameraNode.position = SCNVector3(center.x, center.y + 15, center.z + 20)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(cameraNode)

        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambientLight)

        return scene
    }

    private struct NormalizedPoint {
        let x: Float
        let y: Float // altitude
        let z: Float
    }

    private func normalizePoints() -> [NormalizedPoint] {
        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        let alts = route.points.map(\.altitude)

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!
        let minAlt = alts.min()!
        let maxAlt = alts.max()!

        let latRange = maxLat - minLat
        let lonRange = maxLon - minLon
        let altRange = max(maxAlt - minAlt, 1.0)
        let maxRange = max(latRange, lonRange)
        let scale: Double = maxRange > 0 ? 30.0 / maxRange : 1.0
        let altScale: Double = 10.0 / altRange

        return route.points.map { pt in
            NormalizedPoint(
                x: Float((pt.longitude - minLon) * scale),
                y: Float((pt.altitude - minAlt) * altScale),
                z: Float(-(pt.latitude - minLat) * scale) // negative because SceneKit Z goes into screen
            )
        }
    }

    private func addRoutePath(to scene: SCNScene, points: [NormalizedPoint]) {
        // Create segments between consecutive points
        for i in 1..<points.count {
            let p1 = points[i - 1]
            let p2 = points[i]

            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let dz = p2.z - p1.z
            let length = sqrt(dx * dx + dy * dy + dz * dz)

            guard length > 0.001 else { continue }

            let cylinder = SCNCylinder(radius: 0.08, height: CGFloat(length))

            // Color by altitude (low=blue, mid=green, high=orange)
            let altFraction = CGFloat(p1.y / 10.0)
            let color: UIColor
            if altFraction < 0.5 {
                color = UIColor(
                    red: 0.2,
                    green: 0.4 + altFraction,
                    blue: 1.0 - altFraction,
                    alpha: 1.0
                )
            } else {
                color = UIColor(
                    red: altFraction,
                    green: 1.0 - altFraction * 0.5,
                    blue: 0.2,
                    alpha: 1.0
                )
            }

            cylinder.firstMaterial?.diffuse.contents = color
            cylinder.firstMaterial?.emission.contents = color.withAlphaComponent(0.3)

            let node = SCNNode(geometry: cylinder)
            node.position = SCNVector3(
                (p1.x + p2.x) / 2,
                (p1.y + p2.y) / 2,
                (p1.z + p2.z) / 2
            )

            // Align cylinder between two points
            let direction = SCNVector3(dx, dy, dz)
            node.look(at: SCNVector3(p2.x, p2.y, p2.z))
            node.eulerAngles.x += .pi / 2

            _ = direction // suppress unused warning
            scene.rootNode.addChildNode(node)
        }

        // Add small spheres at each point for smooth appearance
        for point in points {
            let sphere = SCNSphere(radius: 0.1)
            sphere.firstMaterial?.diffuse.contents = UIColor.orange
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(point.x, point.y, point.z)
            scene.rootNode.addChildNode(node)
        }
    }

    private func addMarker(to scene: SCNScene, at point: NormalizedPoint, color: UIColor, label: String) {
        // Sphere marker
        let sphere = SCNSphere(radius: 0.35)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(point.x, point.y + 0.5, point.z)
        scene.rootNode.addChildNode(node)

        // Text label
        let text = SCNText(string: label, extrusionDepth: 0.1)
        text.font = UIFont.boldSystemFont(ofSize: 0.8)
        text.firstMaterial?.diffuse.contents = color
        let textNode = SCNNode(geometry: text)
        textNode.position = SCNVector3(point.x - 0.5, point.y + 1.2, point.z)
        textNode.scale = SCNVector3(0.5, 0.5, 0.5)
        scene.rootNode.addChildNode(textNode)
    }

    private func addGroundPlane(to scene: SCNScene, points: [NormalizedPoint]) {
        let xs = points.map(\.x)
        let zs = points.map(\.z)
        let width = (xs.max()! - xs.min()!) + 4
        let length = (zs.max()! - zs.min()!) + 4

        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(length))
        plane.firstMaterial?.diffuse.contents = UIColor(white: 0.15, alpha: 0.5)
        plane.firstMaterial?.isDoubleSided = true

        let planeNode = SCNNode(geometry: plane)
        planeNode.eulerAngles.x = -.pi / 2
        planeNode.position = SCNVector3(
            (xs.min()! + xs.max()!) / 2,
            -0.1,
            (zs.min()! + zs.max()!) / 2
        )
        scene.rootNode.addChildNode(planeNode)
    }

    private func addQuestItems(to scene: SCNScene, points: [NormalizedPoint]) {
        let quests = dataStore.quests(for: route.id)
        guard let quest = quests.first else { return }

        // For each quest item, find its approximate position in normalized space
        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        let alts = route.points.map(\.altitude)

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!
        let minAlt = alts.min()!
        let maxAlt = alts.max()!

        let latRange = maxLat - minLat
        let lonRange = maxLon - minLon
        let altRange = max(maxAlt - minAlt, 1.0)
        let maxRange = max(latRange, lonRange)
        let scale: Double = maxRange > 0 ? 30.0 / maxRange : 1.0
        let altScale: Double = 10.0 / altRange

        for item in quest.items {
            let x = Float((item.longitude - minLon) * scale)
            let y = Float((item.altitude - minAlt) * altScale) + 0.5
            let z = Float(-(item.latitude - minLat) * scale)

            // Container holds position and spin; the disc child is rotated upright
            let containerNode = SCNNode()
            containerNode.position = SCNVector3(x, y, z)

            // Gold coin disc
            let coin = SCNCylinder(radius: 0.25, height: 0.05)
            coin.firstMaterial?.diffuse.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
            coin.firstMaterial?.emission.contents = UIColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 0.5)
            coin.firstMaterial?.specular.contents = UIColor.white
            coin.firstMaterial?.isDoubleSided = true

            let coinDisc = SCNNode(geometry: coin)
            // 90° rotation on X makes the flat face point forward instead of up
            coinDisc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            containerNode.addChildNode(coinDisc)

            // Spin the container on Y — produces the Mario coin flip on the upright disc
            let spin = CABasicAnimation(keyPath: "rotation")
            spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
            spin.duration = 2
            spin.repeatCount = .infinity
            containerNode.addAnimation(spin, forKey: "spin")

            if item.collected {
                containerNode.opacity = 0.3
            }

            scene.rootNode.addChildNode(containerNode)
        }
    }
}
