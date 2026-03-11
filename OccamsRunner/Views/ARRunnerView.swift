import SwiftUI
import ARKit
import SceneKit
import RealityKit
import CoreLocation
import Combine

// MARK: - Run Mode

enum ARRunMode {
    case aligning
    case running
}

// MARK: - AR Runner View

/// The AR running experience. Shows floating gold coins along the quest route.
/// Starts in alignment mode so the user can correct GPS/compass drift before
/// the run begins; gestures move the entire route as a group.
struct ARRunnerView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var locationService: LocationService
    @Environment(\.dismiss) private var dismiss

    let quest: Quest

    @State private var collectedCount = 0
    @State private var totalPoints = 0
    @State private var showingCompletionAlert = false
    @State private var nearestItemDistance: Double?
    @State private var runMode: ARRunMode = .aligning
    @State private var autoAlignRequested = false

    var body: some View {
        ZStack {
            ARRunnerContainerView(
                quest: quest,
                dataStore: dataStore,
                locationService: locationService,
                runMode: runMode,
                autoAlignRequested: $autoAlignRequested,
                onItemCollected: { itemId in
                    handleCollection(itemId: itemId)
                }
            )
            .ignoresSafeArea()

            if runMode == .aligning {
                VStack {
                    alignmentTopBanner
                    Spacer()
                    alignmentBottomControls
                }
            } else {
                VStack {
                    runningHUD
                    Spacer()
                    bottomBar
                }
            }
        }
        .onAppear {
            locationService.startUpdating()
            let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
            collectedCount = currentQuest.collectedItems
            totalPoints = currentQuest.collectedPoints
        }
        .alert("Quest Complete!", isPresented: $showingCompletionAlert) {
            Button("Finish") { dismiss() }
        } message: {
            Text("You collected all \(quest.totalItems) coins for \(quest.totalPoints) points!")
        }
    }

    // MARK: - Alignment HUD

    private var alignmentTopBanner: some View {
        VStack(spacing: 4) {
            Text("Align Your Route")
                .font(.headline)
                .foregroundColor(.white)
            Text("Drag · Two-finger rotate · Pinch to resize")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            if let accuracy = locationService.currentLocation?.horizontalAccuracy {
                Text(String(format: "GPS: ±%.0f m", accuracy))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }

    private var alignmentBottomControls: some View {
        VStack(spacing: 12) {
            // Point the phone at a recognizable straightaway, then tap this to
            // snap the route so that segment extends directly ahead of you.
            Button(action: { autoAlignRequested = true }) {
                Label("Align to View", systemImage: "viewfinder.circle")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            Button(action: { runMode = .running }) {
                Text("Start Run →")
                    .font(.headline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, 48)
    }

    // MARK: - Running HUD

    private var runningHUD: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "circle.circle.fill")
                    .foregroundColor(.yellow)
                Text("\(collectedCount)/\(quest.totalItems)")
                    .fontWeight(.bold)
            }

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("\(totalPoints) pts")
                    .fontWeight(.bold)
            }

            Spacer()

            // Instant snap: no mode change, just point and tap.
            Button(action: { autoAlignRequested = true }) {
                Image(systemName: "viewfinder.circle")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            Button(action: { runMode = .aligning }) {
                Label("Realign", systemImage: "location.north.line")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack {
            if let distance = nearestItemDistance {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle")
                        .foregroundColor(.orange)
                    Text(String(format: "Next coin: %.0f ft", distance * 3.281))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Collection

    private func handleCollection(itemId: UUID) {
        dataStore.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)
        collectedCount += 1
        totalPoints += QuestItemType.coin.pointValue

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
        if currentQuest.isComplete {
            showingCompletionAlert = true
        }
    }
}

// MARK: - AR Container (UIViewRepresentable)

struct ARRunnerContainerView: UIViewRepresentable {
    let quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let runMode: ARRunMode
    @Binding var autoAlignRequested: Bool
    let onItemCollected: (UUID) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        arView.session.run(config)

        context.coordinator.arView = arView

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(ARCoordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        arView.addGestureRecognizer(pan)

        let rotation = UIRotationGestureRecognizer(
            target: context.coordinator,
            action: #selector(ARCoordinator.handleRotation(_:))
        )
        rotation.delegate = context.coordinator
        arView.addGestureRecognizer(rotation)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(ARCoordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        arView.addGestureRecognizer(pinch)

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if autoAlignRequested {
            context.coordinator.snapToView()
            DispatchQueue.main.async { autoAlignRequested = false }
        }
        context.coordinator.applyRunMode(runMode)
        context.coordinator.updateItems(quest: quest, dataStore: dataStore)
    }

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(
            quest: quest,
            dataStore: dataStore,
            locationService: locationService,
            onItemCollected: onItemCollected
        )
    }
}

// MARK: - AR Coordinator

class ARCoordinator: NSObject, ARSCNViewDelegate, UIGestureRecognizerDelegate {
    var arView: ARSCNView?
    var quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let onItemCollected: (UUID) -> Void

    /// Single parent node for all AR content (coins + ghost path).
    /// Translating/rotating this node repositions everything at once.
    private let routeGroupNode = SCNNode()

    private var coinNodes: [UUID: SCNNode] = [:]
    /// Ghost path segment cylinders and markers, shown only during alignment mode.
    private var ghostNodes: [SCNNode] = []
    private var collectionTimer: Timer?
    private var pendingCollectionIds: Set<UUID> = []
    private var ghostBuilt = false

    /// Current run mode — updated from SwiftUI via applyRunMode().
    private var runMode: ARRunMode = .aligning

    /// Best (most accurate) GPS fix seen this session.
    /// All AR positions are computed relative to this point.
    private var sessionOriginFix: CLLocation?

    /// Altitude of the route's first point, used to pin the start marker to
    /// the device's eye level so GPS altitude drift doesn't float the route.
    private var routeStartAltitude: Double?

    /// Current user-applied XZ scale for the route. 1.0 = GPS-computed distances.
    /// Positions are stored at scale=1 and multiplied by this when placed.
    private var routeScale: Float = 1.0

    /// Route points in AR space at routeScale=1, computed from GPS.
    /// Stored so the ghost path can be rebuilt cheaply on every pinch delta.
    private var ghostPathOriginalPoints: [SCNVector3] = []

    /// Coin positions at routeScale=1. Kept so pinch can move coins without
    /// changing their visual size (only the position is scaled, not the node).
    private var coinOriginalPositions: [UUID: SCNVector3] = [:]

    init(quest: Quest, dataStore: DataStore, locationService: LocationService, onItemCollected: @escaping (UUID) -> Void) {
        self.quest = quest
        self.dataStore = dataStore
        self.locationService = locationService
        self.onItemCollected = onItemCollected
        super.init()

        collectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkCollections()
        }
    }

    deinit {
        collectionTimer?.invalidate()
    }

    // MARK: - Mode Management

    func applyRunMode(_ newMode: ARRunMode) {
        guard newMode != runMode else { return }
        runMode = newMode

        if newMode == .running {
            // Keep ghostPathOriginalPoints so snapToView() works mid-run
            clearGhostPath(preserveData: true)
        } else {
            // Re-entering alignment — rebuild ghost overlay
            ghostBuilt = false
            if let reference = sessionOriginFix {
                buildGhostPath(reference: reference)
            }
        }
    }

    // MARK: - Item Placement

    func updateItems(quest: Quest, dataStore: DataStore) {
        self.quest = quest

        guard let arView = arView, let currentLocation = locationService.currentLocation else { return }

        // Accept up to 50 m horizontal accuracy
        guard currentLocation.horizontalAccuracy > 0,
              currentLocation.horizontalAccuracy < 50 else { return }

        // Attach routeGroupNode to scene once
        if routeGroupNode.parent == nil {
            arView.scene.rootNode.addChildNode(routeGroupNode)
        }

        // Update the session origin fix when we get a meaningfully better GPS reading.
        // "Better" = at least 2 m improvement so noise doesn't trigger constant re-placement.
        let needsNewOrigin: Bool
        if let existing = sessionOriginFix {
            needsNewOrigin = currentLocation.horizontalAccuracy < existing.horizontalAccuracy - 2.0
        } else {
            needsNewOrigin = true
        }

        if needsNewOrigin {
            sessionOriginFix = currentLocation
            // Remove coins; routeGroupNode.position (user drag offset) is preserved
            for node in coinNodes.values { node.removeFromParentNode() }
            coinNodes.removeAll()
            coinOriginalPositions.removeAll()
            // Ghost path needs rebuilding with the new reference
            if runMode == .aligning {
                ghostBuilt = false
            }
        }

        guard let reference = sessionOriginFix else { return }

        // Build ghost path on first valid fix in alignment mode
        if runMode == .aligning && !ghostBuilt {
            buildGhostPath(reference: reference)
        }

        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        for item in currentQuest.items {
            if item.collected {
                if let node = coinNodes[item.id] {
                    node.removeFromParentNode()
                    coinNodes.removeValue(forKey: item.id)
                }
                continue
            }

            if coinNodes[item.id] == nil {
                let itemLocation = item.location
                let distance = reference.distance(from: itemLocation)

                guard distance < 100 else { continue }

                let bearing = reference.bearing(to: itemLocation)

                // ARKit with gravityAndHeading: +X = east, +Y = up, -Z = north
                let dx = Float(distance * sin(bearing))
                // Y is relative to the route's first point so the start marker
                // appears at device eye level regardless of GPS altitude drift.
                let altBase = routeStartAltitude ?? locationService.absoluteAltitude
                let dy = Float(item.altitude - altBase)
                let dz = Float(-distance * cos(bearing))

                // Store the scale=1 position; routeScale is applied separately
                // so pinch can move the coin without changing its visual size.
                let origPos = SCNVector3(dx, dy, dz)
                coinOriginalPositions[item.id] = origPos

                let coinNode = createCoinNode()
                coinNode.position = SCNVector3(dx * routeScale, dy, dz * routeScale)
                routeGroupNode.addChildNode(coinNode)
                coinNodes[item.id] = coinNode
            }
        }
    }

    // MARK: - Ghost Path

    /// Full setup: projects GPS points to AR space at scale=1, stores them,
    /// then calls buildGhostPathNodes() to create the visuals.
    private func buildGhostPath(reference: CLLocation) {
        guard let route = dataStore.route(for: quest.routeId) else { return }
        guard route.points.count > 1 else { return }

        clearGhostPath()

        // Pin the route's starting point to device eye level (Y = 0) so GPS
        // altitude drift between recording and playback doesn't float the route.
        routeStartAltitude = route.points[0].altitude
        let altBase = routeStartAltitude!

        // Project each route point into ARKit world coordinates at routeScale=1
        var arPoints: [SCNVector3] = []
        for point in route.points {
            let bearing = reference.bearing(to: point.location)
            let distance = reference.distance(from: point.location)
            let x = Float(distance * sin(bearing))
            let y = Float(point.altitude - altBase)
            let z = Float(-distance * cos(bearing))
            arPoints.append(SCNVector3(x, y, z))
        }
        ghostPathOriginalPoints = arPoints

        buildGhostPathNodes()
        ghostBuilt = true
    }

    /// Rebuilds ghost visuals from the stored scale=1 points with the current
    /// routeScale applied to XZ. Coins are NOT touched here — their positions
    /// are updated in handlePinch so their visual size stays constant.
    private func buildGhostPathNodes() {
        for node in ghostNodes { node.removeFromParentNode() }
        ghostNodes.removeAll()

        guard ghostPathOriginalPoints.count > 1 else { return }

        let pts = ghostPathOriginalPoints.map { p in
            SCNVector3(p.x * routeScale, p.y, p.z * routeScale)
        }

        for i in 0..<pts.count - 1 {
            let seg = pathSegmentNode(from: pts[i], to: pts[i + 1])
            routeGroupNode.addChildNode(seg)
            ghostNodes.append(seg)
        }

        // Markers use the same fixed sphere size regardless of routeScale
        let startMarker = markerNode(color: UIColor(red: 0.2, green: 0.85, blue: 0.2, alpha: 0.9))
        startMarker.position = pts[0]
        routeGroupNode.addChildNode(startMarker)
        ghostNodes.append(startMarker)

        let endMarker = markerNode(color: UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9))
        endMarker.position = pts[pts.count - 1]
        routeGroupNode.addChildNode(endMarker)
        ghostNodes.append(endMarker)
    }

    private func markerNode(color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.35)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.4)
        mat.isDoubleSided = true
        sphere.materials = [mat]
        return SCNNode(geometry: sphere)
    }

    /// Removes ghost visual nodes.
    /// Pass `preserveData: true` when switching to running mode so that
    /// `snapToView()` can still fire mid-run without rebuilding from GPS.
    private func clearGhostPath(preserveData: Bool = false) {
        for node in ghostNodes { node.removeFromParentNode() }
        ghostNodes.removeAll()
        ghostBuilt = false
        if !preserveData {
            ghostPathOriginalPoints.removeAll()
        }
    }

    private func pathSegmentNode(from: SCNVector3, to: SCNVector3) -> SCNNode {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dz = to.z - from.z
        let len = sqrt(dx * dx + dy * dy + dz * dz)
        guard len > 0.01 else { return SCNNode() }

        let cylinder = SCNCylinder(radius: 0.05, height: CGFloat(len))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.4)
        material.isDoubleSided = true
        cylinder.materials = [material]

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(
            (from.x + to.x) / 2,
            (from.y + to.y) / 2,
            (from.z + to.z) / 2
        )

        // Orient the cylinder's Y-axis along the direction vector
        let dirNorm = simd_normalize(simd_float3(dx, dy, dz))
        let yAxis = simd_float3(0, 1, 0)
        let dot = simd_dot(yAxis, dirNorm)
        if dot < -0.9999 {
            // Anti-parallel: flip 180° around X
            node.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else if dot < 0.9999 {
            node.simdOrientation = simd_quatf(from: yAxis, to: dirNorm)
        }

        return node
    }

    // MARK: - Snap to View

    /// Rotates and translates the route group so that the nearest route segment
    /// to the camera extends directly along the camera's forward direction, and
    /// the nearest route point lands at the camera's XZ position.
    ///
    /// Usage: user stands at a recognisable straightaway, points the phone along
    /// it, and taps "Align to View". The whole route snaps into position.
    func snapToView() {
        guard ghostPathOriginalPoints.count > 1 else { return }
        guard let arView = arView, let pov = arView.pointOfView else { return }

        let t = pov.simdWorldTransform

        // Camera XZ position and forward direction (world space)
        let camX = t.columns.3.x
        let camZ = t.columns.3.z
        let rawFwdX = -t.columns.2.x
        let rawFwdZ = -t.columns.2.z
        let fwdLen = sqrt(rawFwdX * rawFwdX + rawFwdZ * rawFwdZ)
        guard fwdLen > 0.001 else { return }
        let camFwd = simd_float2(rawFwdX / fwdLen, rawFwdZ / fwdLen)

        // Transform all route points to world XZ using current group state
        let q = simd_quatf(angle: routeGroupNode.eulerAngles.y, axis: simd_float3(0, 1, 0))
        let gx = routeGroupNode.position.x
        let gz = routeGroupNode.position.z

        let worldPts: [simd_float2] = ghostPathOriginalPoints.map { p in
            let rotated = q.act(simd_float3(p.x * routeScale, 0, p.z * routeScale))
            return simd_float2(rotated.x + gx, rotated.z + gz)
        }

        // Find the nearest route point to the camera
        let camXZ = simd_float2(camX, camZ)
        var nearestIdx = 0
        var nearestDist = Float.greatestFiniteMagnitude
        for (i, pt) in worldPts.enumerated() {
            let d = simd_length(pt - camXZ)
            if d < nearestDist { nearestDist = d; nearestIdx = i }
        }

        // Route segment direction in world space at the nearest point
        let rawDir: simd_float2
        if nearestIdx < worldPts.count - 1 {
            let d = worldPts[nearestIdx + 1] - worldPts[nearestIdx]
            rawDir = simd_length(d) > 0.001 ? simd_normalize(d) : camFwd
        } else {
            let d = worldPts[nearestIdx] - worldPts[nearestIdx - 1]
            rawDir = simd_length(d) > 0.001 ? simd_normalize(d) : camFwd
        }

        // Choose the direction that faces toward camera forward, not away
        let segDir = simd_dot(rawDir, camFwd) >= 0 ? rawDir : -rawDir

        // Signed angle needed to rotate segDir onto camFwd
        let cross = segDir.x * camFwd.y - segDir.y * camFwd.x
        let dot   = simd_dot(segDir, camFwd)
        let deltaAngle = atan2(cross, dot)

        routeGroupNode.eulerAngles.y += deltaAngle

        // Recompute nearest point's world XZ position after the new rotation
        let newQ = simd_quatf(angle: routeGroupNode.eulerAngles.y, axis: simd_float3(0, 1, 0))
        let localPt = ghostPathOriginalPoints[nearestIdx]
        let rotatedNearest = newQ.act(simd_float3(localPt.x * routeScale, 0, localPt.z * routeScale))

        // Translate so the nearest route point sits at the camera's XZ position
        routeGroupNode.position.x = camX - rotatedNearest.x
        routeGroupNode.position.z = camZ - rotatedNearest.z

        // Rebuild ghost path visuals so cylinders reflect the new transform
        if ghostBuilt { buildGhostPathNodes() }
    }

    // MARK: - Gesture Handlers

    /// Pan gesture: translate the route group in the screen-relative XZ plane.
    /// Uses pointOfView transform (SceneKit-space) which correctly accounts for
    /// portrait/landscape orientation — unlike camera.transform which is always
    /// in ARKit's landscape-sensor frame.
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard runMode == .aligning, let arView = arView else { return }

        let translation = gesture.translation(in: arView)
        gesture.setTranslation(.zero, in: arView)

        guard let pov = arView.pointOfView else { return }
        let t = pov.simdWorldTransform

        // Extract screen-right and screen-forward from the SceneKit camera node,
        // then project onto the horizontal XZ plane.
        var right   = simd_float3(t.columns.0.x, 0, t.columns.0.z)
        var forward = simd_float3(-t.columns.2.x, 0, -t.columns.2.z)

        let rightLen   = simd_length(right)
        let forwardLen = simd_length(forward)
        guard rightLen > 0.001, forwardLen > 0.001 else { return }

        right   /= rightLen
        forward /= forwardLen

        let scale: Float = 0.02  // metres per screen point (≈8 m per full-width swipe)
        let offset = right * Float(translation.x) * scale
                   + forward * Float(-translation.y) * scale

        routeGroupNode.position = SCNVector3(
            routeGroupNode.position.x + offset.x,
            routeGroupNode.position.y,
            routeGroupNode.position.z + offset.z
        )
    }

    /// Two-finger rotation gesture: rotate the route group around the Y axis
    /// to correct compass heading error.
    @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard runMode == .aligning else { return }
        routeGroupNode.eulerAngles.y -= Float(gesture.rotation)
        gesture.rotation = 0
    }

    /// Pinch gesture: scale the route path in the XZ plane.
    /// Only the route cylinders and marker POSITIONS change — coins keep their
    /// visual size and just move to the correct scaled positions.
    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard runMode == .aligning else { return }
        let delta = Float(gesture.scale)
        gesture.scale = 1.0
        routeScale = min(5.0, max(0.1, routeScale * delta))

        // Rebuild ghost cylinders + reposition markers at the new scale
        if ghostBuilt {
            buildGhostPathNodes()
        }

        // Reposition coins using their stored scale=1 positions.
        // The coin nodes themselves are NOT scaled — they keep their visual size.
        for (id, node) in coinNodes {
            if let orig = coinOriginalPositions[id] {
                node.position = SCNVector3(orig.x * routeScale, orig.y, orig.z * routeScale)
            }
        }
    }

    // Allow pan, rotation, and pinch to fire simultaneously in alignment mode.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - Coin Node

    private func createCoinNode() -> SCNNode {
        // Container node owns the world position, spin, and bob animations.
        // The actual disc is a child rotated 90° on X so it stands upright
        // and the Y-axis spin produces the classic Mario coin flip.
        let containerNode = SCNNode()

        let coin = SCNCylinder(radius: 0.15, height: 0.02)

        let goldMaterial = SCNMaterial()
        goldMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        goldMaterial.specular.contents = UIColor.white
        goldMaterial.metalness.contents = 0.8
        goldMaterial.roughness.contents = 0.2
        goldMaterial.emission.contents = UIColor(red: 0.6, green: 0.45, blue: 0.0, alpha: 1.0)
        goldMaterial.isDoubleSided = true

        coin.materials = [goldMaterial]

        let coinDisc = SCNNode(geometry: coin)
        coinDisc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        containerNode.addChildNode(coinDisc)

        let glow = SCNSphere(radius: 0.2)
        let glowMaterial = SCNMaterial()
        glowMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.9, blue: 0.3, alpha: 0.15)
        glowMaterial.emission.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.3)
        glowMaterial.isDoubleSided = true
        glow.materials = [glowMaterial]
        containerNode.addChildNode(SCNNode(geometry: glow))

        let spin = CABasicAnimation(keyPath: "rotation")
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, Float.pi * 2))
        spin.duration = 2.0
        spin.repeatCount = .infinity
        containerNode.addAnimation(spin, forKey: "spin")

        let bob = CABasicAnimation(keyPath: "position.y")
        bob.byValue = 0.1
        bob.duration = 1.0
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        containerNode.addAnimation(bob, forKey: "bob")

        return containerNode
    }

    // MARK: - Collection

    private func checkCollections() {
        // Collection is disabled during alignment mode
        guard runMode == .running else { return }

        guard let arView = arView,
              let cameraNode = arView.pointOfView else { return }

        let cameraPos = cameraNode.worldPosition
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        for item in currentQuest.items {
            guard !item.collected, !pendingCollectionIds.contains(item.id) else { continue }
            guard let node = coinNodes[item.id] else { continue }

            let coinPos = node.worldPosition
            let dx = cameraPos.x - coinPos.x
            let dy = cameraPos.y - coinPos.y
            let dz = cameraPos.z - coinPos.z
            let distance = sqrt(dx * dx + dy * dy + dz * dz)

            // 2 metres in AR scene space (~6.5 ft)
            if distance < 2.0 {
                pendingCollectionIds.insert(item.id)

                let scaleUp = SCNAction.scale(to: 2.0, duration: 0.2)
                let fadeOut = SCNAction.fadeOut(duration: 0.3)
                let group = SCNAction.group([scaleUp, fadeOut])
                let remove = SCNAction.removeFromParentNode()
                node.runAction(SCNAction.sequence([group, remove]))
                coinNodes.removeValue(forKey: item.id)

                DispatchQueue.main.async {
                    self.onItemCollected(item.id)
                }
            }
        }
    }
}

// MARK: - CLLocation Bearing Extension

extension CLLocation {
    /// Calculate bearing from this location to another location in radians.
    func bearing(to destination: CLLocation) -> Double {
        let lat1 = coordinate.latitude.degreesToRadians
        let lon1 = coordinate.longitude.degreesToRadians
        let lat2 = destination.coordinate.latitude.degreesToRadians
        let lon2 = destination.coordinate.longitude.degreesToRadians

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        return atan2(y, x)
    }
}

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
    var radiansToDegrees: Double { self * 180 / .pi }
}
