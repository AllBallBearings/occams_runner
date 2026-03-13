import SwiftUI
import ARKit
import SceneKit
import CoreLocation

// MARK: - Run Mode

enum ARRunMode {
    case aligning
    case running
}

enum ARAlignmentState: String {
    case moveToStart = "Move to route start"
    case scanning = "Scanning for relocalization"
    case locked = "Alignment locked"
    case lowConfidence = "Low-confidence alignment"
}

// MARK: - AR Runner View

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

    @State private var alignmentState: ARAlignmentState = .moveToStart
    @State private var alignmentConfidence: Double = 0
    @State private var distanceToStart: Double?
    @State private var alignmentReady = false

    private var route: RecordedRoute? {
        dataStore.route(for: quest.routeId)
    }

    var body: some View {
        ZStack {
            if let route {
                ARRunnerContainerView(
                    route: route,
                    quest: quest,
                    dataStore: dataStore,
                    locationService: locationService,
                    runMode: runMode,
                    onAlignmentUpdate: { state, confidence, distance, ready in
                        alignmentState = state
                        alignmentConfidence = confidence
                        distanceToStart = distance
                        alignmentReady = ready
                    },
                    onNearestItemDistance: { nearest in
                        nearestItemDistance = nearest
                    },
                    onItemCollected: { itemId in
                        handleCollection(itemId: itemId)
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                Text("Route not found for this quest.")
                    .foregroundColor(.white)
            }

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
        VStack(spacing: 5) {
            Text(alignmentState.rawValue)
                .font(.headline)
                .foregroundColor(.white)

            if let distanceToStart {
                Text(String(format: "Distance to start: %.0f ft", distanceToStart * 3.281))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }

            Text(String(format: "Alignment confidence: %.0f%%", alignmentConfidence * 100))
                .font(.caption2)
                .foregroundColor(alignmentReady ? .green : .orange)

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
            Button(action: { runMode = .running }) {
                Text("Start Run →")
                    .font(.headline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(alignmentReady ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .disabled(!alignmentReady)

            if !alignmentReady {
                Text("Move near route start and scan the environment to lock alignment.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 28)
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

            Text(String(format: "Align %.0f%%", alignmentConfidence * 100))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(alignmentConfidence >= 0.75 ? .green : .orange)

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
    let route: RecordedRoute
    let quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let runMode: ARRunMode
    let onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    let onNearestItemDistance: (Double?) -> Void
    let onItemCollected: (UUID) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]

        if let encrypted = route.encryptedWorldMapData,
           let decrypted = locationService.decryptWorldMapData(encrypted),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: decrypted) {
            config.initialWorldMap = worldMap
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        context.coordinator.arView = arView
        context.coordinator.configureInitialScene()

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.applyRunMode(runMode)
        context.coordinator.updateQuest(quest, dataStore: dataStore)
    }

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(
            route: route,
            quest: quest,
            dataStore: dataStore,
            locationService: locationService,
            onAlignmentUpdate: onAlignmentUpdate,
            onNearestItemDistance: onNearestItemDistance,
            onItemCollected: onItemCollected
        )
    }
}

// MARK: - AR Coordinator

class ARCoordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
    var arView: ARSCNView?

    let route: RecordedRoute
    var quest: Quest
    let dataStore: DataStore
    let locationService: LocationService

    let onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    let onNearestItemDistance: (Double?) -> Void
    let onItemCollected: (UUID) -> Void

    private let routeGroupNode = SCNNode()
    private var pathNodes: [SCNNode] = []
    private var coinNodes: [UUID: SCNNode] = [:]
    private var pendingCollectionIds: Set<UUID> = []

    private var runMode: ARRunMode = .aligning

    private var alignmentState: ARAlignmentState = .moveToStart
    private var alignmentConfidence: Double = 0
    private var alignmentLocked = false
    private var consecutiveGoodFrames = 0
    private var scanStartedAt: Date?

    private var statusTimer: Timer?
    private var collectionTimer: Timer?

    private let startGateDistanceMeters: Double = 40

    init(
        route: RecordedRoute,
        quest: Quest,
        dataStore: DataStore,
        locationService: LocationService,
        onAlignmentUpdate: @escaping (ARAlignmentState, Double, Double?, Bool) -> Void,
        onNearestItemDistance: @escaping (Double?) -> Void,
        onItemCollected: @escaping (UUID) -> Void
    ) {
        self.route = route
        self.quest = quest
        self.dataStore = dataStore
        self.locationService = locationService
        self.onAlignmentUpdate = onAlignmentUpdate
        self.onNearestItemDistance = onNearestItemDistance
        self.onItemCollected = onItemCollected
        super.init()

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateAlignmentStatusFromGPS()
            self?.updateNearestItemDistance()
        }

        collectionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkCollections()
        }
    }

    deinit {
        statusTimer?.invalidate()
        collectionTimer?.invalidate()
    }

    // MARK: - Setup

    func configureInitialScene() {
        guard let arView else { return }

        arView.session.delegate = self

        if routeGroupNode.parent == nil {
            arView.scene.rootNode.addChildNode(routeGroupNode)
        }

        buildRoutePath()
        buildCoinNodes(forceRebuild: true)
        updateAlignmentStatusFromGPS()
    }

    func applyRunMode(_ newMode: ARRunMode) {
        guard newMode != runMode else { return }
        runMode = newMode

        let showPath = newMode == .aligning
        for node in pathNodes {
            node.isHidden = !showPath
        }
    }

    func updateQuest(_ quest: Quest, dataStore: DataStore) {
        self.quest = quest
        buildCoinNodes(forceRebuild: false)
    }

    // MARK: - Route + Coins

    private func buildRoutePath() {
        for node in pathNodes { node.removeFromParentNode() }
        pathNodes.removeAll()

        guard route.localTrack.count > 1 else { return }

        let points: [SIMD3<Float>] = route.localTrack.map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        }

        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]
            let segment = pathSegmentNode(from: from, to: to)
            routeGroupNode.addChildNode(segment)
            pathNodes.append(segment)
        }

        let start = markerNode(color: UIColor(red: 0.2, green: 0.85, blue: 0.2, alpha: 0.9))
        start.simdPosition = points[0]
        routeGroupNode.addChildNode(start)
        pathNodes.append(start)

        let end = markerNode(color: UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9))
        end.simdPosition = points[points.count - 1]
        routeGroupNode.addChildNode(end)
        pathNodes.append(end)
    }

    private func buildCoinNodes(forceRebuild: Bool) {
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        if forceRebuild {
            for node in coinNodes.values { node.removeFromParentNode() }
            coinNodes.removeAll()
        }

        for item in currentQuest.items {
            if item.collected {
                if let existing = coinNodes[item.id] {
                    existing.removeFromParentNode()
                    coinNodes.removeValue(forKey: item.id)
                }
                continue
            }

            if coinNodes[item.id] == nil,
               let local = item.resolvedLocalPosition(on: route) {
                let coinNode = createCoinNode()
                coinNode.simdPosition = local
                routeGroupNode.addChildNode(coinNode)
                coinNodes[item.id] = coinNode
            }
        }
    }

    private func updateNearestItemDistance() {
        guard let cameraNode = arView?.pointOfView else {
            DispatchQueue.main.async { self.onNearestItemDistance(nil) }
            return
        }

        var nearest: Double?
        let cameraPos = cameraNode.worldPosition

        for (_, node) in coinNodes {
            let p = node.worldPosition
            let dx = Double(cameraPos.x - p.x)
            let dy = Double(cameraPos.y - p.y)
            let dz = Double(cameraPos.z - p.z)
            let d = sqrt(dx * dx + dy * dy + dz * dz)
            if nearest == nil || d < nearest! {
                nearest = d
            }
        }

        DispatchQueue.main.async {
            self.onNearestItemDistance(nearest)
        }
    }

    // MARK: - Alignment

    private func updateAlignmentStatusFromGPS() {
        let distance = distanceToRouteStart()

        if let distance, distance > startGateDistanceMeters {
            alignmentState = .moveToStart
            alignmentConfidence = min(alignmentConfidence, 0.2)
            alignmentLocked = false
            consecutiveGoodFrames = 0
            scanStartedAt = nil
            publishAlignment(distance: distance)
            return
        }

        if !alignmentLocked {
            if scanStartedAt == nil {
                scanStartedAt = Date()
            }
            alignmentState = .scanning
        }

        publishAlignment(distance: distance)
    }

    private func publishAlignment(distance: Double?) {
        DispatchQueue.main.async {
            self.onAlignmentUpdate(
                self.alignmentState,
                self.alignmentConfidence,
                distance,
                self.alignmentLocked
            )
        }
    }

    private func distanceToRouteStart() -> Double? {
        guard let current = locationService.currentLocation,
              let start = route.startLocation else { return nil }
        return current.distance(from: start)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard (distanceToRouteStart() ?? 0) <= startGateDistanceMeters else { return }
        guard !alignmentLocked else { return }

        let featureCount = Double(frame.rawFeaturePoints?.points.count ?? 0)
        let featureScore = min(1, featureCount / 250)

        let trackingScore: Double
        switch frame.camera.trackingState {
        case .normal:
            trackingScore = 1
        case .limited(let reason):
            switch reason {
            case .relocalizing: trackingScore = 0.65
            case .excessiveMotion: trackingScore = 0.45
            case .insufficientFeatures: trackingScore = 0.3
            case .initializing: trackingScore = 0.35
            @unknown default: trackingScore = 0.3
            }
        case .notAvailable:
            trackingScore = 0
        }

        let mappingScore: Double
        switch frame.worldMappingStatus {
        case .mapped: mappingScore = 1
        case .extending: mappingScore = 0.8
        case .limited: mappingScore = 0.45
        case .notAvailable: mappingScore = 0.2
        @unknown default: mappingScore = 0.3
        }

        alignmentConfidence = max(0, min(1, (featureScore * 0.35) + (trackingScore * 0.35) + (mappingScore * 0.3)))

        if alignmentConfidence >= 0.75 {
            consecutiveGoodFrames += 1
        } else {
            consecutiveGoodFrames = max(0, consecutiveGoodFrames - 1)
        }

        if consecutiveGoodFrames >= 15 {
            alignmentLocked = true
            alignmentState = .locked
        } else if let scanStartedAt,
                  Date().timeIntervalSince(scanStartedAt) > 14,
                  alignmentConfidence >= 0.45 {
            alignmentState = .lowConfidence
        } else {
            alignmentState = .scanning
        }

        publishAlignment(distance: distanceToRouteStart())
    }

    // MARK: - Collection

    private func checkCollections() {
        guard runMode == .running else { return }
        guard let arView, let cameraNode = arView.pointOfView else { return }

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

            if distance < Float(QuestItem.collectionRadiusMeters) {
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

    // MARK: - Nodes

    private func markerNode(color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.25)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.35)
        mat.isDoubleSided = true
        sphere.materials = [mat]
        return SCNNode(geometry: sphere)
    }

    private func pathSegmentNode(from: SIMD3<Float>, to: SIMD3<Float>) -> SCNNode {
        let delta = to - from
        let len = simd_length(delta)
        guard len > 0.01 else { return SCNNode() }

        let cylinder = SCNCylinder(radius: 0.04, height: CGFloat(len))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.45)
        material.isDoubleSided = true
        cylinder.materials = [material]

        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (from + to) / 2

        let dirNorm = simd_normalize(delta)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(yAxis, dirNorm)
        if dot < -0.9999 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else if dot < 0.9999 {
            node.simdOrientation = simd_quatf(from: yAxis, to: dirNorm)
        }

        return node
    }

    private func createCoinNode() -> SCNNode {
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
}
