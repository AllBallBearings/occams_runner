import ARKit
import SceneKit
import CoreLocation

// MARK: - AR Coordinator

class ARCoordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
    var arView: ARSCNView?

    let route: RecordedRoute
    var quest: Quest
    let dataStore: DataStore
    let locationService: LocationService

    // Fix 3: `var` so updateUIView can refresh these on every SwiftUI render pass.
    // makeCoordinator() is called once — the closures it captures contain a frozen
    // struct copy of ARRunnerView. By re-assigning these from updateUIView we ensure
    // each collection callback always closes over the live @State / @EnvironmentObject
    // values rather than the stale snapshot from the first render.
    var onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    var onNearestItemDistance: (Double?) -> Void
    var onItemCollected: (UUID) -> Void
    var onDebugTick: (String) -> Void

    private let routeGroupNode = SCNNode()
    private var pathNodes: [SCNNode] = []
    private(set) var coinNodes: [UUID: SCNNode] = [:]
    private(set) var pendingCollectionIds: Set<UUID> = []

    private var runMode: ARRunMode = .aligning
    private var runStartedAt: Date?
    private var collectionTickSerial: UInt64 = 0
    private var collectionCheckSerial: UInt64 = 0
    private var lastSkipReasonLogged: String?
    private var lastHeartbeatAt: Date = .distantPast
    private var frozenRouteWorldTransform: simd_float4x4?

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
        onItemCollected: @escaping (UUID) -> Void,
        onDebugTick: @escaping (String) -> Void
    ) {
        self.route = route
        self.quest = quest
        self.dataStore = dataStore
        self.locationService = locationService
        self.onAlignmentUpdate = onAlignmentUpdate
        self.onNearestItemDistance = onNearestItemDistance
        self.onItemCollected = onItemCollected
        self.onDebugTick = onDebugTick
        super.init()

        // Both timers run on the main RunLoop so all coinNodes access
        // (checkCollections, updateNearestItemDistance, buildCoinNodes, updateQuest)
        // is single-threaded on main — no dictionary races possible.
        statusTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateAlignmentStatusFromGPS()
            self?.updateNearestItemDistance()
        }
        RunLoop.main.add(statusTimer!, forMode: .common)

        collectionTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkCollections()
        }
        RunLoop.main.add(collectionTimer!, forMode: .common)
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

        // Shift the entire route (path + coins) down ~1 ft so objects
        // appear at chest/waist height rather than eye/head height.
        routeGroupNode.position.y = -0.3

        buildRoutePath()
        buildCoinNodes(forceRebuild: true)
        updateAlignmentStatusFromGPS()
    }

    func applyRunMode(_ newMode: ARRunMode) {
        guard newMode != runMode else { return }
        let previousMode = runMode
        runMode = newMode

        switch newMode {
        case .running:
            if previousMode != .realigning {
                // Fresh run start — reset timing and tick counter
                runStartedAt = Date()
                collectionTickSerial = 0
            }
            // Freeze route transform so alignment remains stable during collection.
            frozenRouteWorldTransform = routeGroupNode.simdWorldTransform
            // Running mode does not require per-frame ARSession callbacks.
            arView?.session.delegate = nil

        case .aligning, .realigning:
            // Unfreeze route transform so AR alignment can adjust it.
            frozenRouteWorldTransform = nil
            // Restore frame callbacks for tracking updates.
            arView?.session.delegate = self
            alignmentLocked = false
            consecutiveGoodFrames = 0
            scanStartedAt = nil
            alignmentState = .scanning
        }

        let showPath = (newMode == .aligning || newMode == .realigning)
        for node in pathNodes {
            node.isHidden = !showPath
        }
    }

    func updateQuest(_ quest: Quest, dataStore: DataStore) {
        // updateUIView is called on the main thread; keep coinNodes mutations there.
        assert(Thread.isMainThread)
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

    func buildCoinNodes(forceRebuild: Bool) {
        assert(Thread.isMainThread)
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        if forceRebuild {
            for node in coinNodes.values { node.removeFromParentNode() }
            coinNodes.removeAll()
        }

        for item in currentQuest.items {
            if item.collected {
                // Fix 1: unblock the pending slot now that the dataStore has
                // confirmed this item is collected. Without this remove(), the
                // ID stays in pendingCollectionIds forever.
                pendingCollectionIds.remove(item.id)
                if let existing = coinNodes[item.id] {
                    existing.removeFromParentNode()
                    coinNodes.removeValue(forKey: item.id)
                }
                continue
            }

            // Fix 2: also skip items that are in-flight (pending collection).
            // Between Phase 2 removing the node from coinNodes and the dataStore
            // confirming collected=true, a SwiftUI re-render can fire this path.
            // Without the guard, buildCoinNodes would create a ghost node for the
            // in-flight item.
            if coinNodes[item.id] == nil,
               !pendingCollectionIds.contains(item.id),
               let local = item.resolvedLocalPosition(on: route) {
                let coinNode = createCoinNode()
                coinNode.simdPosition = local
                routeGroupNode.addChildNode(coinNode)
                coinNodes[item.id] = coinNode
            }
        }
    }

    private func updateNearestItemDistance() {
        if runMode == .running, let frozen = frozenRouteWorldTransform {
            routeGroupNode.simdWorldTransform = frozen
        }

        guard let cameraNode = arView?.pointOfView else {
            onNearestItemDistance(nil)
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

        onNearestItemDistance(nearest)
    }

    // MARK: - Alignment

    private func updateAlignmentStatusFromGPS() {
        guard runMode == .aligning || runMode == .realigning else { return }
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
        guard runMode == .aligning || runMode == .realigning else { return }
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

    private func logCollectionConsole(_ message: String, force: Bool = false) {
        #if DEBUG
        let now = Date()
        if force || now.timeIntervalSince(lastHeartbeatAt) >= 1.0 {
            lastHeartbeatAt = now
            print("[ARRunner][Collection] \(message)")
        }
        #endif
    }

    private func checkCollections() {
        collectionCheckSerial &+= 1

        guard runMode == .running else {
            let reason = "skip:runMode=\(runMode)"
            if lastSkipReasonLogged != reason {
                lastSkipReasonLogged = reason
                logCollectionConsole("check#\(collectionCheckSerial) \(reason)", force: true)
            }
            return
        }
        if let runStartedAt, Date().timeIntervalSince(runStartedAt) < 0.8 {
            let reason = "skip:startDelay"
            if lastSkipReasonLogged != reason {
                lastSkipReasonLogged = reason
                logCollectionConsole("check#\(collectionCheckSerial) \(reason)", force: true)
            }
            return
        }
        guard let arView else {
            let reason = "skip:noARView"
            if lastSkipReasonLogged != reason {
                lastSkipReasonLogged = reason
                logCollectionConsole("check#\(collectionCheckSerial) \(reason)", force: true)
            }
            return
        }
        guard let cameraNode = arView.pointOfView else {
            let reason = "skip:noCameraNode"
            if lastSkipReasonLogged != reason {
                lastSkipReasonLogged = reason
                logCollectionConsole("check#\(collectionCheckSerial) \(reason)", force: true)
            }
            return
        }

        if let frozen = frozenRouteWorldTransform {
            routeGroupNode.simdWorldTransform = frozen
        }

        if lastSkipReasonLogged != nil {
            lastSkipReasonLogged = nil
            logCollectionConsole("check#\(collectionCheckSerial) resumed", force: true)
        } else {
            logCollectionConsole(
                "check#\(collectionCheckSerial) heartbeat tick=\(collectionTickSerial) nodes=\(coinNodes.count) pending=\(pendingCollectionIds.count)"
            )
        }

        performCollectionTick(cameraPosition: cameraNode.worldPosition)
    }

    /// Core collection logic. Uses CollectionEngine for pure geometry checks,
    /// then handles side effects (node removal, sound, dataStore, callbacks).
    func performCollectionTick(cameraPosition: SCNVector3) {
        collectionTickSerial &+= 1
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        // Self-heal: clean up confirmed-collected items from coinNodes/pendingIds.
        // This runs before the engine so stale state doesn't accumulate.
        for item in currentQuest.items where item.collected {
            pendingCollectionIds.remove(item.id)
            if let staleNode = coinNodes.removeValue(forKey: item.id) {
                staleNode.removeFromParentNode()
            }
        }

        // Phase 1 — pure geometry check via CollectionEngine. No mutations.
        var coinWorldPositions: [UUID: SCNVector3] = [:]
        for (id, node) in coinNodes {
            coinWorldPositions[id] = node.worldPosition
        }

        let result = CollectionEngine.evaluateCollections(
            cameraPosition: cameraPosition,
            items: currentQuest.items,
            coinWorldPositions: coinWorldPositions,
            pendingIds: pendingCollectionIds,
            tickSerial: collectionTickSerial
        )

        // Log every tick so collection behaviour is visible in the debug log.
        let shouldPersistTick = !result.collectedItemIds.isEmpty || (collectionTickSerial % 4 == 0)
        if shouldPersistTick {
            locationService.logRunEvent("[Tick] \(result.debugLog)")
        }
        onDebugTick(result.debugLog)
        #if DEBUG
        if shouldPersistTick {
            print("[ARRunner][Tick] \(result.debugLog)")
        }
        #endif

        // Phase 2 — act on collected items. Safe to mutate now since the
        // CollectionEngine loop over items has already finished.
        for itemId in result.collectedItemIds {
            pendingCollectionIds.insert(itemId)
            let node = coinNodes.removeValue(forKey: itemId)

            if let node, arView != nil {
                CoinSoundPlayer.shared.playCollect()

                let scaleUp = SCNAction.scale(to: 2.0, duration: 0.2)
                let fadeOut = SCNAction.fadeOut(duration: 0.3)
                let group   = SCNAction.group([scaleUp, fadeOut])
                let remove  = SCNAction.removeFromParentNode()
                node.runAction(SCNAction.sequence([group, remove]))
            } else {
                node?.removeFromParentNode()
            }

            dataStore.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)
            onItemCollected(itemId)
            #if DEBUG
            print("[ARRunner][Collect] t\(collectionTickSerial) item=\(itemId.uuidString.prefix(8)) nodes=\(coinNodes.count) pending=\(pendingCollectionIds.count)")
            #endif
        }
    }

    // MARK: - Test Inspection

    #if DEBUG
    var testCoinNodeIds: Set<UUID> { Set(coinNodes.keys) }
    var testPendingIds: Set<UUID> { pendingCollectionIds }
    var testCoinNodeCount: Int { coinNodes.count }

    /// Build coin nodes without needing configureInitialScene (no arView).
    func testBuildCoinNodes(forceRebuild: Bool) {
        buildCoinNodes(forceRebuild: forceRebuild)
    }
    #endif

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

// MARK: - Testable Pure Helpers

extension ARCoordinator {
    /// Euclidean distance between two SceneKit positions. Extracted for unit testing.
    static func distance3D(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    /// Returns items eligible for collection — not collected, not pending, and with a node.
    static func eligibleItems(
        from items: [QuestItem],
        coinNodes: [UUID: SCNNode],
        pendingIds: Set<UUID>
    ) -> [QuestItem] {
        items.filter { item in
            !item.collected &&
            !pendingIds.contains(item.id) &&
            coinNodes[item.id] != nil
        }
    }

    /// Returns whether `buildCoinNodes` should create a new node for `item`.
    static func shouldCreateNode(
        for item: QuestItem,
        coinNodes: [UUID: SCNNode],
        pendingIds: Set<UUID>
    ) -> Bool {
        !item.collected &&
        !pendingIds.contains(item.id) &&
        coinNodes[item.id] == nil
    }
}
