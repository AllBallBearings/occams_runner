import ARKit
import SceneKit
import CoreLocation
import Vision
import UIKit

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
    var onAlignmentUpdate: (ARAlignmentStatus) -> Void
    var onNearestItemDistance: (Double?) -> Void
    var onItemCollected: (UUID) -> Void
    var onDebugTick: (String) -> Void
    var onStartPlacementDebugUpdate: (String) -> Void

    /// Shared state object written by SwiftUI gesture handlers and read each
    /// AR frame to apply manual position / rotation corrections to the route.
    var manualAlignment: ManualAlignmentState?

    /// Set by the container when the session runs with the route's world map, so a
    /// later relocalization means the session adopted the recording's coordinates.
    var expectsRelocalization = false

    private let routeGroupNode = SCNNode()
    /// Child of `routeGroupNode` at the route start, so the beacon always sits exactly
    /// where the route begins and moves with every placement or manual correction.
    private let startGuidanceNode = SCNNode()
    private let guidanceOrange = UIColor(red: 1.0, green: 0.42, blue: 0.02, alpha: 1.0)
    private var pathNodes: [SCNNode] = []
    private var pathSegmentNodes: [SCNNode] = []
    private(set) var coinNodes: [UUID: SCNNode] = [:]
    private(set) var pendingCollectionIds: Set<UUID> = []
    private(set) var boxNodes: [UUID: SCNNode] = [:]
    private var pendingBoxIds: Set<UUID> = []

    /// Shadow-catcher plane nodes keyed by ARPlaneAnchor identifier. Each one is
    /// an invisible plane that writes to the depth buffer; the directional
    /// shadow light's deferred shadow pass darkens pixels behind shadow casters
    /// wherever those planes exist.
    private var shadowPlaneNodes: [UUID: SCNNode] = [:]
    private var shadowLightNode: SCNNode?
    private var ambientLightNode: SCNNode?

    private var arrowIndicatorNode: SCNNode?

    // Hand pose detection
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private var lastHandPoseTime: TimeInterval = 0
    private let handPoseInterval: TimeInterval = 0.1  // 10 fps

    private var runMode: ARRunMode = .aligning
    private(set) var viewMode: ARViewMode = .goToStart
    private var runStartedAt: Date?
    private var collectionTickSerial: UInt64 = 0
    private var collectionCheckSerial: UInt64 = 0
    private var lastSkipReasonLogged: String?
    private var lastHeartbeatAt: Date = .distantPast
    private var frozenRouteWorldTransform: simd_float4x4?

    private var alignmentState: ARAlignmentState = .moveToStart {
        didSet {
            guard oldValue != alignmentState else { return }
            DispatchQueue.main.async { self.updateRouteNodeVisibility() }
        }
    }
    private var alignmentConfidence: Double = 0
    /// Exponential moving average of per-frame raw confidence — smooths out
    /// transient tracking blips without introducing too much lag.
    private var smoothedConfidence: Double = 0
    private var alignmentLocked = false
    private var consecutiveGoodFrames = 0
    private var scanStartedAt: Date?
    /// How many consecutive status ticks have placed the user outside the start gate.
    /// Several are required before an established lock is dropped so one noisy
    /// reading can't knock out a good alignment.
    private var consecutiveOutOfRangeGPS = 0
    /// Cached by the status timer; the per-frame tracking score only runs inside the gate.
    private var isWithinStartGate = false

    private var statusTimer: Timer?
    private var collectionTimer: Timer?
    private var lastStartPlacementDebugAt: TimeInterval = 0

    // MARK: Placement state
    //
    // The route is recorded in its own AR coordinate space. Until ARKit matches the
    // recorded world map, the live session's space is unrelated, so the route is placed
    // through the earth: recording space → east/north (RouteGeoRegistration) → live
    // session (ARGeoFusion, from compass + GPS paired with ARKit's camera path). Once
    // ARKit relocalizes, the live session *is* recording space and placement is exact.

    private let registration: RouteGeoRegistration?
    private var geoFusion = ARGeoFusion()
    private var fusionEstimate: ARGeoFusion.Estimate?
    private let compass = CompassHeadingProvider()
    private var lastFusedGPSTimestamp: Date?
    private var sawRelocalizing = false
    private(set) var isRelocalized = false
    /// Where the route should sit, and where it sits while easing toward that so
    /// estimate refinements glide instead of jumping.
    private var targetPose: RoutePose?
    private var currentPose: RoutePose?
    private var lastPoseFrameTime: TimeInterval?
    private var placementUncertainty: Double?

    /// Manual drag/pinch corrections accumulated in world space, so turning the phone
    /// after a drag doesn't drag the route along with the camera.
    private var manualWorldOffset: SIMD3<Float> = .zero
    private var lastManualValues: SIMD3<Float> = .zero

    // Base Y offset applied to the route group so objects sit at chest height.
    // The manual alignment adds onto this baseline.
    private let baseRouteY: Float = -0.3

    init(
        route: RecordedRoute,
        quest: Quest,
        dataStore: DataStore,
        locationService: LocationService,
        onAlignmentUpdate: @escaping (ARAlignmentStatus) -> Void,
        onNearestItemDistance: @escaping (Double?) -> Void,
        onItemCollected: @escaping (UUID) -> Void,
        onDebugTick: @escaping (String) -> Void,
        onStartPlacementDebugUpdate: @escaping (String) -> Void
    ) {
        self.route = route
        self.quest = quest
        self.dataStore = dataStore
        self.locationService = locationService
        self.registration = RouteGeoRegistration(route: route)
        self.onAlignmentUpdate = onAlignmentUpdate
        self.onNearestItemDistance = onNearestItemDistance
        self.onItemCollected = onItemCollected
        self.onDebugTick = onDebugTick
        self.onStartPlacementDebugUpdate = onStartPlacementDebugUpdate
        super.init()

        // Both timers run on the main RunLoop so all coinNodes access
        // (checkCollections, updateNearestItemDistance, buildCoinNodes, updateQuest)
        // is single-threaded on main — no dictionary races possible.
        statusTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateAlignmentStatus()
            self?.updateNearestItemDistance()
            self?.updateOverviewScaling()
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
        compass.stop()
    }

    // MARK: - Setup

    func configureInitialScene() {
        guard let arView else { return }

        arView.session.delegate = self

        if routeGroupNode.parent == nil {
            arView.scene.rootNode.addChildNode(routeGroupNode)
        }
        if startGuidanceNode.parent == nil {
            routeGroupNode.addChildNode(startGuidanceNode)
            buildStartGuidanceBeacon()
        }
        // Recorded positions are the phone at chest height; the beacon stands on the
        // ground roughly 1.5 m below (the route group already sits baseRouteY lower).
        let start = registration?.localStart ?? route.localTrack.first.map {
            SIMD3(Float($0.x), Float($0.y), Float($0.z))
        } ?? .zero
        startGuidanceNode.simdPosition = start + SIMD3(0, -1.5 - baseRouteY, 0)

        // Shift the entire route (path + coins) down ~1 ft so objects
        // appear at chest/waist height rather than eye/head height.
        routeGroupNode.position.y = baseRouteY

        compass.start()
        setupShadowLighting()
        buildRoutePath()
        buildCoinNodes(forceRebuild: true)
        buildBoxNodes(forceRebuild: true)
        setupArrowIndicator()
        updateAlignmentStatus()
        updateRouteNodeVisibility()
    }

    // MARK: - Shadow Lighting

    /// Adds the directional shadow-casting light plus an ambient fill so items
    /// stay visible. The shadow-receiving planes are added later by the
    /// `renderer(_:didAdd:for:)` delegate as ARKit detects horizontal surfaces.
    private func setupShadowLighting() {
        guard let arView, shadowLightNode == nil else { return }

        // Adding our own lights disables ARSCNView's autoenabled default light,
        // so provide an ambient fill explicitly.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 0.75, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        arView.scene.rootNode.addChildNode(ambientNode)
        ambientLightNode = ambientNode

        let directional = SCNLight()
        directional.type = .directional
        directional.color = UIColor(white: 1.0, alpha: 1.0)
        directional.castsShadow = true
        // Deferred shadow mode renders shadows as a screen-space pass that
        // works with invisible shadow-catcher planes (color mask = []).
        directional.shadowMode = .deferred
        directional.shadowSampleCount = 16
        directional.shadowRadius = 4
        directional.shadowMapSize = CGSize(width: 2048, height: 2048)
        directional.shadowColor = UIColor(white: 0, alpha: 0.55)
        directional.orthographicScale = 8

        let dirNode = SCNNode()
        dirNode.light = directional
        // Position high above the camera so the orthographic shadow frustum
        // covers the route, then tilt the light down with a slight side angle
        // for natural-looking shadow direction.
        dirNode.position = SCNVector3(2, 6, 2)
        dirNode.eulerAngles = SCNVector3(-Float.pi / 2.4, Float.pi / 8, 0)
        arView.scene.rootNode.addChildNode(dirNode)
        shadowLightNode = dirNode
    }

    /// Builds the invisible material used by shadow-catcher planes: writes
    /// depth so the deferred shadow pass darkens shadowed pixels, but writes
    /// no color so the real ground from the camera feed shows through.
    private func makeShadowCatcherMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true
        mat.colorBufferWriteMask = []
        return mat
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
            refreshOverviewEmphasis()
            // Freeze route transform so alignment remains stable during collection.
            frozenRouteWorldTransform = routeGroupNode.simdWorldTransform
            // Keep session delegate active for hand pose detection during running.
            arView?.session.delegate = self

        case .aligning, .realigning:
            // Unfreeze route transform so AR alignment can adjust it.
            frozenRouteWorldTransform = nil
            // Restore frame callbacks for tracking updates.
            arView?.session.delegate = self
            if newMode == .realigning { viewMode = .goToStart }
            resetLock()
            alignmentState = .scanning
            refreshOverviewEmphasis()
        }

        updateRouteNodeVisibility()
    }

    func applyViewMode(_ newMode: ARViewMode) {
        guard newMode != viewMode else { return }
        viewMode = newMode
        resetLock()
        alignmentState = .moveToStart
        refreshOverviewEmphasis()
        updateRouteNodeVisibility()
    }

    private func resetLock() {
        alignmentLocked = false
        consecutiveGoodFrames = 0
        consecutiveOutOfRangeGPS = 0
        isWithinStartGate = false
        scanStartedAt = nil
    }

    private var isAligning: Bool { runMode == .aligning || runMode == .realigning }
    private var isPlaced: Bool { currentPose != nil }
    private var isOverviewActive: Bool { isAligning && viewMode == .overview }
    private var isLockedAtStart: Bool { alignmentLocked && alignmentState == .locked }

    private var collectiblesVisible: Bool {
        runMode == .running || (isPlaced && (isOverviewActive || isLockedAtStart))
    }

    private func updateRouteNodeVisibility() {
        assert(Thread.isMainThread)
        let showPath = isAligning && isPlaced && (isOverviewActive || isLockedAtStart)
        let showCollectibles = collectiblesVisible
        for node in pathNodes {
            node.isHidden = !showPath
        }
        for node in coinNodes.values {
            node.isHidden = !showCollectibles
        }
        for node in boxNodes.values {
            node.isHidden = !showCollectibles
        }
        startGuidanceNode.isHidden = !(isAligning && isPlaced && (isOverviewActive || !isLockedAtStart))
    }

    /// In the overview the route may be far away, so the path is drawn thicker and
    /// collectibles grow with distance to stay readable.
    private func refreshOverviewEmphasis() {
        let thickness: Float = isOverviewActive ? 3 : 1
        for node in pathSegmentNodes {
            node.simdScale = SIMD3(thickness, 1, thickness)
        }
        if !isOverviewActive {
            for node in coinNodes.values { node.simdScale = SIMD3(repeating: 1) }
            for node in boxNodes.values { node.simdScale = SIMD3(repeating: 1) }
        }
    }

    private func updateOverviewScaling() {
        guard isOverviewActive, let camera = arView?.pointOfView?.simdWorldPosition else { return }
        for node in Array(coinNodes.values) + Array(boxNodes.values) {
            let distance = simd_distance(camera, node.simdWorldPosition)
            node.simdScale = SIMD3(repeating: min(6, max(1, distance / 12)))
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
        pathSegmentNodes.removeAll()

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
            pathSegmentNodes.append(segment)
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
                coinNode.isHidden = !collectiblesVisible
                routeGroupNode.addChildNode(coinNode)
                coinNodes[item.id] = coinNode
            }
        }
    }

    func buildBoxNodes(forceRebuild: Bool) {
        assert(Thread.isMainThread)
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        if forceRebuild {
            for node in boxNodes.values { node.removeFromParentNode() }
            boxNodes.removeAll()
            pendingBoxIds.removeAll()
        }

        for box in currentQuest.boxes {
            if boxNodes[box.id] == nil,
               !pendingBoxIds.contains(box.id),
               let local = box.resolvedLocalPosition(on: route) {
                let node = createBoxNode()
                node.simdPosition = local
                node.isHidden = !collectiblesVisible
                routeGroupNode.addChildNode(node)
                boxNodes[box.id] = node
            }
        }
    }

    // MARK: - Hand Pose & Punch Detection

    private func processHandPose(frame: ARFrame) {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch { return }

        guard let observation = handPoseRequest.results?.first,
              detectFistPose(observation) else { return }

        let fistPos = fistWorldPosition(frame: frame)
        checkPunchDetection(fistPosition: fistPos)
    }

    /// Returns true when the detected hand is in a fist pose.
    /// Uses normalized tip-to-palm distances to be orientation-independent.
    private func detectFistPose(_ observation: VNHumanHandPoseObservation) -> Bool {
        guard let wrist      = try? observation.recognizedPoint(.wrist),
              let indexTip   = try? observation.recognizedPoint(.indexTip),
              let indexMCP   = try? observation.recognizedPoint(.indexMCP),
              let middleTip  = try? observation.recognizedPoint(.middleTip),
              let middleMCP  = try? observation.recognizedPoint(.middleMCP) else { return false }

        let minConf: Float = 0.4
        guard wrist.confidence > minConf,
              indexTip.confidence > minConf,
              indexMCP.confidence > minConf,
              middleTip.confidence > minConf,
              middleMCP.confidence > minConf else { return false }

        func dist2D(_ a: VNRecognizedPoint, _ bx: Double, _ by: Double) -> Double {
            let dx = a.location.x - bx
            let dy = a.location.y - by
            return sqrt(dx * dx + dy * dy)
        }

        // Palm center = midpoint between index and middle MCPs
        let palmX = (indexMCP.location.x + middleMCP.location.x) / 2
        let palmY = (indexMCP.location.y + middleMCP.location.y) / 2

        // Reference scale: wrist to index MCP distance
        let scale = dist2D(indexMCP, wrist.location.x, wrist.location.y)
        guard scale > 0.01 else { return false }

        // Fingertips are "curled" when they're close to the palm relative to hand size
        let indexRatio  = dist2D(indexTip,  palmX, palmY) / scale
        let middleRatio = dist2D(middleTip, palmX, palmY) / scale

        return indexRatio < 0.7 && middleRatio < 0.7
    }

    /// Estimates the 3D world position of the fist as camera position + forward × arm length.
    private func fistWorldPosition(frame: ARFrame) -> SIMD3<Float> {
        let t = frame.camera.transform
        let cameraPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // Camera looks along its -Z axis in world space
        let forward = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
        return cameraPos + simd_normalize(forward) * 0.6  // ~arm's length
    }

    private func checkPunchDetection(fistPosition: SIMD3<Float>) {
        guard runMode == .running else { return }
        let punchRadius: Float = 0.5

        for (id, node) in boxNodes {
            guard !pendingBoxIds.contains(id) else { continue }
            let boxPos = SIMD3<Float>(
                node.simdWorldPosition.x,
                node.simdWorldPosition.y,
                node.simdWorldPosition.z
            )
            if simd_distance(fistPosition, boxPos) < punchRadius {
                pendingBoxIds.insert(id)
                explodeBox(id: id, node: node)
                break
            }
        }
    }

    private func explodeBox(id: UUID, node: SCNNode) {
        guard let arView else { return }

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()

        // Capture world position before removing node
        let worldPos = node.simdWorldPosition

        // Remove box node immediately
        node.removeFromParentNode()
        boxNodes.removeValue(forKey: id)

        // Particle burst at box world position
        let particleNode = SCNNode()
        particleNode.simdWorldPosition = worldPos
        arView.scene.rootNode.addChildNode(particleNode)

        let particles = SCNParticleSystem()
        particles.particleColor = UIColor(red: 0.6, green: 0.35, blue: 0.1, alpha: 1.0)
        particles.particleColorVariation = SCNVector4(0.2, 0.1, 0.05, 0)
        particles.particleLifeSpan        = 0.7
        particles.particleLifeSpanVariation = 0.3
        particles.birthRate               = 500
        particles.emissionDuration        = 0.08
        particles.spreadingAngle          = 180
        particles.particleVelocity        = 3.0
        particles.particleVelocityVariation = 1.5
        particles.particleSize            = 0.04
        particles.particleSizeVariation   = 0.02
        particles.isAffectedByGravity     = true
        particles.loops                   = false
        particleNode.addParticleSystem(particles)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak particleNode] in
            particleNode?.removeFromParentNode()
        }

        #if DEBUG
        print("[ARRunner][PunchBox] destroyed box \(id.uuidString.prefix(8))")
        #endif
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
        updateArrowDirection()
    }

    // MARK: - Arrow Indicator

    private func setupArrowIndicator() {
        guard let cameraNode = arView?.pointOfView else { return }
        let arrow = createArrowIndicatorNode()
        // Bottom-center in camera space, visually just above the Start Quest button.
        arrow.position = SCNVector3(0, -0.29, -0.74)
        arrow.isHidden = true
        // Always draw on top of AR geometry so it isn't occluded by route nodes
        arrow.renderingOrder = 100
        cameraNode.addChildNode(arrow)
        arrowIndicatorNode = arrow
    }

    private func createArrowIndicatorNode() -> SCNNode {
        let container = SCNNode()
        let visual = SCNNode()
        visual.eulerAngles.x = -.pi / 2

        let bodyShape = SCNShape(path: directionalArrowPath(), extrusionDepth: 0.008)
        bodyShape.chamferRadius = 0.0015
        bodyShape.materials = [
            arrowMaterial(color: guidanceOrange, emission: 0.28, alpha: 0.86),
            arrowMaterial(color: UIColor(red: 0.72, green: 0.18, blue: 0.0, alpha: 1.0), emission: 0.06, alpha: 0.72)
        ]
        let bodyNode = SCNNode(geometry: bodyShape)
        bodyNode.renderingOrder = 101
        visual.addChildNode(bodyNode)

        container.addChildNode(visual)
        return container
    }

    private func updateArrowDirection() {
        guard let arrow = arrowIndicatorNode,
              let cameraNode = arView?.pointOfView else { return }

        if isAligning && !isLockedAtStart {
            guard isPlaced else {
                arrow.isHidden = true
                return
            }

            arrow.isHidden = false
            pointArrow(arrow, from: cameraNode, toward: startGuidanceNode.simdWorldPosition)
            return
        }

        guard runMode == .running, !coinNodes.isEmpty else {
            arrow.isHidden = true
            return
        }

        // Find nearest coin by world-space distance to the camera
        let camPos = cameraNode.worldPosition
        var nearest: SCNNode?
        var nearestDist: Float = .infinity

        for (_, node) in coinNodes {
            let d = ARCoordinator.distance3D(camPos, node.worldPosition)
            if d < nearestDist { nearestDist = d; nearest = node }
        }

        // Hide when the coin is close enough to see directly
        guard let target = nearest, nearestDist > 2.0 else {
            arrow.isHidden = true
            return
        }

        arrow.isHidden = false
        pointArrow(arrow, from: cameraNode, toward: target.worldPosition)
    }

    private func pointArrow(_ arrow: SCNNode, from cameraNode: SCNNode, toward targetWorldPosition: SCNVector3) {
        let targetCamLocal = cameraNode.convertPosition(targetWorldPosition, from: nil)
        let arrowCamLocal = arrow.position
        let dir = simd_float3(
            targetCamLocal.x - arrowCamLocal.x,
            0,
            targetCamLocal.z - arrowCamLocal.z
        )
        guard simd_length(dir) > 0.01 else { return }
        arrow.simdOrientation = simd_quatf(
            angle: atan2(-dir.x, -dir.z),
            axis: simd_float3(0, 1, 0)
        )
    }

    private func pointArrow(_ arrow: SCNNode, from cameraNode: SCNNode, toward targetWorldPosition: SIMD3<Float>) {
        pointArrow(
            arrow,
            from: cameraNode,
            toward: SCNVector3(
                targetWorldPosition.x,
                targetWorldPosition.y,
                targetWorldPosition.z
            )
        )
    }

    private func directionalArrowPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.0, y: 0.105))
        path.addLine(to: CGPoint(x: 0.075, y: 0.015))
        path.addLine(to: CGPoint(x: 0.038, y: 0.018))
        path.addLine(to: CGPoint(x: 0.038, y: -0.105))
        path.addLine(to: CGPoint(x: -0.038, y: -0.105))
        path.addLine(to: CGPoint(x: -0.038, y: 0.018))
        path.addLine(to: CGPoint(x: -0.075, y: 0.015))
        path.close()
        return path
    }

    private func arrowMaterial(color: UIColor, emission: CGFloat, alpha: CGFloat) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = color.withAlphaComponent(alpha)
        mat.emission.contents = color.withAlphaComponent(emission)
        mat.specular.contents = UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 0.75)
        mat.shininess = 0.25
        mat.lightingModel = .physicallyBased
        mat.blendMode = .alpha
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        return mat
    }

    // MARK: - Placement

    /// Recording space → live AR world: a yaw about +Y plus a translation.
    private struct RoutePose {
        var yaw: Float
        var translation: SIMD3<Float>

        var matrix: simd_float4x4 {
            var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(translation, 1)
            return m
        }

        func moved(toward target: RoutePose, fraction t: Float) -> RoutePose {
            let dYaw = Float(PlanarGeo.normalizeAngle(Double(target.yaw - yaw)))
            return RoutePose(
                yaw: yaw + dYaw * t,
                translation: simd_mix(translation, target.translation, SIMD3(repeating: t))
            )
        }

        /// A refinement this large is a different answer, not a correction; snap to it.
        func isFar(from other: RoutePose) -> Bool {
            simd_distance(translation, other.translation) > 25
                || abs(PlanarGeo.normalizeAngle(Double(yaw - other.yaw))) > .pi / 4
        }
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    private var precisePose: RoutePose {
        RoutePose(yaw: 0, translation: SIMD3(0, baseRouteY, 0))
    }

    private var placementQuality: ARPlacementQuality {
        if isRelocalized { return .precise }
        if isPlaced, let placementUncertainty {
            return .approximate(uncertaintyMeters: placementUncertainty)
        }
        return .calibrating
    }

    /// While ARKit hunts for the world map it reports `relocalizing` but still tracks
    /// motion in the session's own space, which is all the placement fusion needs.
    private static func isUsableForPlacement(_ state: ARCamera.TrackingState) -> Bool {
        switch state {
        case .normal, .limited(.relocalizing): return true
        default: return false
        }
    }

    /// Feeds each new GPS fix, paired with where ARKit had the camera at that moment,
    /// into the live-session registration.
    private func ingestGPS(frame: ARFrame) {
        guard !isRelocalized, let registration,
              let location = locationService.currentLocation,
              location.timestamp != lastFusedGPSTimestamp,
              Date().timeIntervalSince(location.timestamp) < 2,
              Self.isUsableForPlacement(frame.camera.trackingState) else { return }
        lastFusedGPSTimestamp = location.timestamp
        let camera = frame.camera.transform.columns.3
        geoFusion.addGPS(
            arPlan: PlanarGeo.plan(fromAR: SIMD3(camera.x, camera.y, camera.z)),
            enu: registration.frame.enu(location.coordinate),
            accuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }

    private func ingestCompass(frame: ARFrame) {
        guard !isRelocalized,
              Self.isUsableForPlacement(frame.camera.trackingState),
              let yaw = compass.arToENUYaw(
                  cameraTransform: frame.camera.transform,
                  frameTimestamp: frame.timestamp
              ) else { return }
        geoFusion.addCompass(yaw: yaw, time: frame.timestamp)
    }

    /// Recomputes where the route should sit. Runs on the status timer; the per-frame
    /// update eases the visible route toward the result.
    private func refreshPlacementTarget() {
        guard let frame = arView?.session.currentFrame else { return }
        ingestGPS(frame: frame)

        if isRelocalized {
            targetPose = precisePose
            placementUncertainty = 0
            return
        }
        guard let registration, let estimate = geoFusion.estimate() else {
            fusionEstimate = nil
            return
        }
        fusionEstimate = estimate

        let plan = ARGeoFusion.routeToAR(localToENU: registration.localToENU, arToENU: estimate.arToENU)
        let xz = PlanarGeo.arXZ(fromPlan: plan.translation)
        let vertical = verticalOffset(for: plan, camera: frame.camera.transform)
        targetPose = RoutePose(
            yaw: Float(plan.yaw),
            translation: SIMD3(xz.x, baseRouteY + vertical, xz.y)
        )
        let startPlan = plan.apply(PlanarGeo.plan(fromAR: registration.localStart))
        placementUncertainty = sqrt(
            pow(estimate.sigma(at: startPlan), 2) + pow(registration.startSigmaMeters, 2)
        )
    }

    /// The recording and live sessions put y = 0 at different heights. Match the route
    /// point nearest the user to the phone's current height, as it was when recorded.
    private func verticalOffset(for plan: PlanarTransform, camera: simd_float4x4) -> Float {
        let cameraPosition = camera.columns.3
        let cameraPlan = PlanarGeo.plan(fromAR: SIMD3(cameraPosition.x, cameraPosition.y, cameraPosition.z))
        var nearestY: Double?
        var nearestDistance = Double.infinity
        for sample in route.localTrack {
            let d = simd_distance(plan.apply(SIMD2(sample.x, -sample.z)), cameraPlan)
            if d < nearestDistance {
                nearestDistance = d
                nearestY = sample.y
            }
        }
        guard let nearestY else { return 0 }
        return cameraPosition.y - Float(nearestY)
    }

    /// Per frame: ease toward the target placement and apply manual corrections.
    private func updateRouteTransform(frame: ARFrame) {
        if runMode == .running, let frozen = frozenRouteWorldTransform {
            routeGroupNode.simdWorldTransform = frozen
            return
        }
        updateManualOffset(camera: frame.camera.transform)

        if let target = targetPose {
            let wasPlaced = isPlaced
            if let current = currentPose, !current.isFar(from: target), let last = lastPoseFrameTime {
                let dt = Float(max(0, min(0.1, frame.timestamp - last)))
                currentPose = current.moved(toward: target, fraction: 1 - exp(-dt / 0.6))
            } else {
                currentPose = target
            }
            if !wasPlaced {
                updateRouteNodeVisibility()
                refreshOverviewEmphasis()
            }
        }
        lastPoseFrameTime = frame.timestamp

        guard let pose = currentPose else { return }
        routeGroupNode.simdTransform = composedTransform(pose: pose)
    }

    /// Placement, then the user's manual rotation about the route start (so the start
    /// beacon stays put while the rest of the route swings), then the manual shift.
    private func composedTransform(pose: RoutePose) -> simd_float4x4 {
        let base = pose.matrix
        let pivotLocal = registration?.localStart ?? .zero
        let pivot4 = base * SIMD4(pivotLocal, 1)
        let pivot = SIMD3(pivot4.x, pivot4.y, pivot4.z)
        let rotation = simd_float4x4(simd_quatf(
            angle: manualAlignment?.rotationY ?? 0,
            axis: SIMD3(0, 1, 0)
        ))
        return Self.translationMatrix(manualWorldOffset + pivot)
            * rotation
            * Self.translationMatrix(-pivot)
            * base
    }

    /// Gestures report camera-relative offsets ("drag right", "pinch farther"). Convert
    /// each change into world space at the moment it happens and accumulate it.
    private func updateManualOffset(camera: simd_float4x4) {
        guard let manual = manualAlignment else { return }
        guard manual.hasAdjustment else {
            manualWorldOffset = .zero
            lastManualValues = .zero
            return
        }
        let values = SIMD3(manual.worldX, manual.worldY, manual.worldZ)
        let delta = values - lastManualValues
        guard delta != .zero else { return }

        // Camera's right vector is its X column; forward is -Z column (ARKit looks in -Z).
        // Flattened so tilting the phone doesn't cause vertical drift during a drag.
        let rightFlat = SIMD3<Float>(camera.columns.0.x, 0, camera.columns.0.z)
        let forwardFlat = SIMD3<Float>(-camera.columns.2.x, 0, -camera.columns.2.z)
        guard simd_length(rightFlat) > 0.001, simd_length(forwardFlat) > 0.001 else { return }

        lastManualValues = values
        manualWorldOffset += simd_normalize(rightFlat) * delta.x
            + simd_normalize(forwardFlat) * delta.z
            + SIMD3(0, delta.y, 0)
    }

    private func didRelocalize() {
        isRelocalized = true
        geoFusion.reset()
        fusionEstimate = nil
        // Manual corrections compensated for GPS error that no longer exists.
        manualAlignment?.reset()
        manualWorldOffset = .zero
        lastManualValues = .zero
        targetPose = precisePose
        currentPose = precisePose
        placementUncertainty = 0
        routeGroupNode.simdTransform = composedTransform(pose: precisePose)
        if runMode == .running {
            frozenRouteWorldTransform = routeGroupNode.simdWorldTransform
        }
        updateRouteNodeVisibility()
        refreshOverviewEmphasis()
        locationService.logRunEvent("[Placement] world map relocalized — precise placement")
    }

    // MARK: - Alignment

    /// Distance the user must be within to align. Precise placement can be trusted
    /// from farther away; a lock gets extra room before it is dropped.
    private func startGateMeters(locked: Bool) -> Double {
        (isRelocalized ? 8 : 5) + (locked ? 3 : 0)
    }

    private func updateAlignmentStatus() {
        guard isAligning else { return }
        refreshPlacementTarget()
        updateRouteNodeVisibility()

        let distance = runMode == .realigning ? distanceToNearestRoutePoint() : distanceToRouteStart()

        guard viewMode == .goToStart else {
            resetLock()
            alignmentState = .moveToStart
            publishAlignment(distance: distanceToRouteStart())
            return
        }

        // The gate is measured in AR space against the placed route, so it is only
        // meaningful once the route is placed.
        let isNear = isPlaced && (distance.map { $0 <= startGateMeters(locked: alignmentLocked) } ?? false)
        isWithinStartGate = isNear

        if isNear {
            consecutiveOutOfRangeGPS = 0
            if !alignmentLocked {
                if scanStartedAt == nil { scanStartedAt = Date() }
                if alignmentState == .moveToStart { alignmentState = .scanning }
            }
        } else {
            consecutiveOutOfRangeGPS += 1
            if !alignmentLocked || consecutiveOutOfRangeGPS >= 3 {
                alignmentState = .moveToStart
                alignmentConfidence = min(alignmentConfidence, 0.2)
                resetLock()
            }
        }

        publishAlignment(distance: distance)
    }

    private func publishAlignment(distance: Double?) {
        let status = ARAlignmentStatus(
            state: alignmentState,
            confidence: alignmentConfidence,
            distanceToStart: distance,
            ready: viewMode == .goToStart && alignmentLocked,
            placement: placementQuality
        )
        DispatchQueue.main.async {
            self.onAlignmentUpdate(status)
        }
    }

    /// Horizontal metres to the route start: measured in AR space against the placed
    /// beacon when there is one, otherwise from GPS to the registered start.
    private func distanceToRouteStart() -> Double? {
        if isPlaced, let camera = arView?.session.currentFrame?.camera.transform.columns.3 {
            let start = startGuidanceNode.simdWorldPosition
            return Double(simd_distance(SIMD2(camera.x, camera.z), SIMD2(start.x, start.z)))
        }
        guard let current = locationService.currentLocation,
              let start = registration?.startLocation ?? route.startLocation else { return nil }
        return current.distance(from: start)
    }

    /// Realigning happens mid-run, so the gate is the nearest point of the route.
    private func distanceToNearestRoutePoint() -> Double? {
        guard isPlaced, let camera = arView?.session.currentFrame?.camera.transform.columns.3 else {
            return nil
        }
        let transform = routeGroupNode.simdWorldTransform
        var nearest = Float.infinity
        for sample in route.localTrack {
            let world = transform * SIMD4(Float(sample.x), Float(sample.y), Float(sample.z), 1)
            nearest = min(nearest, simd_distance(SIMD2(camera.x, camera.z), SIMD2(world.x, world.z)))
        }
        return nearest.isFinite ? Double(nearest) : nil
    }

    // MARK: - ARSCNViewDelegate (plane anchors → shadow catchers)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor,
              planeAnchor.alignment == .horizontal else { return }

        let plane = SCNPlane(
            width: CGFloat(planeAnchor.extent.x),
            height: CGFloat(planeAnchor.extent.z)
        )
        plane.materials = [makeShadowCatcherMaterial()]

        let planeNode = SCNNode(geometry: plane)
        // ARPlaneAnchor.center is offset from the anchor's transform origin in
        // its local horizontal plane. Lay our SCNPlane flat in that plane.
        planeNode.simdPosition = SIMD3<Float>(
            planeAnchor.center.x, 0, planeAnchor.center.z
        )
        planeNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        planeNode.castsShadow = false
        planeNode.name = "shadowCatcherPlane"

        node.addChildNode(planeNode)
        shadowPlaneNodes[planeAnchor.identifier] = planeNode
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor,
              planeAnchor.alignment == .horizontal,
              let planeNode = shadowPlaneNodes[planeAnchor.identifier],
              let plane = planeNode.geometry as? SCNPlane else { return }

        plane.width = CGFloat(planeAnchor.extent.x)
        plane.height = CGFloat(planeAnchor.extent.z)
        planeNode.simdPosition = SIMD3<Float>(
            planeAnchor.center.x, 0, planeAnchor.center.z
        )
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        shadowPlaneNodes.removeValue(forKey: planeAnchor.identifier)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .limited(.relocalizing):
            sawRelocalizing = true
        case .normal:
            // A session started from a world map reports `relocalizing` until it
            // matches the map; reaching `normal` afterwards means it adopted the
            // recording's coordinate space.
            if expectsRelocalization, sawRelocalizing, !isRelocalized {
                didRelocalize()
            }
        default:
            break
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        ingestCompass(frame: frame)
        updateRouteTransform(frame: frame)
        publishStartPlacementDebugIfNeeded(frame: frame)
        updateArrowDirection()

        if runMode == .running {
            let now = frame.timestamp
            if now - lastHandPoseTime >= handPoseInterval {
                lastHandPoseTime = now
                processHandPose(frame: frame)
            }
            return
        }
        guard isAligning, viewMode == .goToStart, isWithinStartGate, !alignmentLocked else { return }

        // --- Feature density score ---
        let featureCount = Double(frame.rawFeaturePoints?.points.count ?? 0)
        // Scale: 0 at 0 features, 1.0 at ≥300 features (raised from 250 for stricter signal).
        let featureScore = min(1.0, featureCount / 300.0)

        // --- Tracking state score ---
        // Before ARKit matches the world map it reports `relocalizing` while still
        // tracking motion normally; the route is GPS-placed then, so that counts.
        let trackingScore: Double
        let isTrackingUsable: Bool
        switch frame.camera.trackingState {
        case .normal:
            trackingScore = 1.0
            isTrackingUsable = true
        case .limited(let reason):
            switch reason {
            case .relocalizing:
                trackingScore = expectsRelocalization ? 0.9 : 0.65
                isTrackingUsable = expectsRelocalization
            case .excessiveMotion:      trackingScore = 0.40; isTrackingUsable = false
            case .insufficientFeatures: trackingScore = 0.30; isTrackingUsable = false
            case .initializing:         trackingScore = 0.35; isTrackingUsable = false
            @unknown default:           trackingScore = 0.30; isTrackingUsable = false
            }
        case .notAvailable:
            trackingScore = 0
            isTrackingUsable = false
        }

        // --- World mapping status score ---
        let mappingScore: Double
        switch frame.worldMappingStatus {
        case .mapped:       mappingScore = 1.0
        case .extending:    mappingScore = 0.8
        case .limited:      mappingScore = 0.45
        case .notAvailable: mappingScore = 0.2
        @unknown default:   mappingScore = 0.3
        }

        // --- Raw composite confidence ---
        let rawConfidence = max(0.0, min(1.0,
            (featureScore * 0.4) + (trackingScore * 0.4) + (mappingScore * 0.2)
        ))

        // --- EMA smoothing (α=0.25) to damp transient tracking blips ---
        // A single bad frame won't crash confidence, but sustained degradation will.
        smoothedConfidence = 0.75 * smoothedConfidence + 0.25 * rawConfidence
        alignmentConfidence = smoothedConfidence

        // --- Consecutive-good-frame counter ---
        // Increment when tracking is usable and smoothed confidence clears 0.65.
        // On catastrophic loss hard-reset to 0. On mild degradation hold the
        // counter (don't decay) so a brief glitch doesn't undo accumulated progress.
        if isTrackingUsable && smoothedConfidence >= 0.65 {
            consecutiveGoodFrames += 1
        } else if !isTrackingUsable || smoothedConfidence < 0.40 {
            consecutiveGoodFrames = 0
        }

        // --- State transitions ---
        // Require 15 consecutive good frames (≈0.25 s at 60 fps) to lock.
        if consecutiveGoodFrames >= 15 {
            alignmentLocked = true
            alignmentState = .locked
        } else if let scanStartedAt,
                  Date().timeIntervalSince(scanStartedAt) > 14,
                  smoothedConfidence >= 0.45 {
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

    private func buildStartGuidanceBeacon() {
        startGuidanceNode.childNodes.forEach { $0.removeFromParentNode() }

        let markerOrange = guidanceOrange

        func solidGlowMaterial(alpha: CGFloat, emissionAlpha: CGFloat) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = markerOrange.withAlphaComponent(alpha)
            mat.emission.contents = markerOrange.withAlphaComponent(emissionAlpha)
            mat.lightingModel = .constant
            mat.blendMode = .add
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            return mat
        }

        func texturedGlowMaterial(_ image: UIImage) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = image
            mat.emission.contents = image
            mat.lightingModel = .constant
            mat.blendMode = .add
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            return mat
        }

        let floorHalo = SCNCylinder(radius: 0.92, height: 0.01)
        floorHalo.radialSegmentCount = 128
        floorHalo.materials = [solidGlowMaterial(alpha: 0.14, emissionAlpha: 0.55)]
        let floorHaloNode = SCNNode(geometry: floorHalo)
        floorHaloNode.opacity = 0.72
        startGuidanceNode.addChildNode(floorHaloNode)

        let floorDisk = SCNCylinder(radius: 0.68, height: 0.014)
        floorDisk.radialSegmentCount = 128
        floorDisk.materials = [solidGlowMaterial(alpha: 0.42, emissionAlpha: 0.95)]
        let floorDiskNode = SCNNode(geometry: floorDisk)
        floorDiskNode.position.y = 0.006
        startGuidanceNode.addChildNode(floorDiskNode)

        let columnTexture = verticalBeaconTexture(color: markerOrange)
        let column = SCNCylinder(radius: 0.68, height: 1.75)
        column.radialSegmentCount = 96
        column.materials = [
            texturedGlowMaterial(columnTexture),
            solidGlowMaterial(alpha: 0.04, emissionAlpha: 0.12),
            solidGlowMaterial(alpha: 0.36, emissionAlpha: 0.85)
        ]
        let columnNode = SCNNode(geometry: column)
        columnNode.position.y = 0.875
        columnNode.opacity = 0.86
        startGuidanceNode.addChildNode(columnNode)

        let outerGlow = SCNCylinder(radius: 0.78, height: 1.68)
        outerGlow.radialSegmentCount = 96
        outerGlow.materials = [texturedGlowMaterial(verticalBeaconTexture(color: markerOrange, peakAlpha: 0.18))]
        let outerGlowNode = SCNNode(geometry: outerGlow)
        outerGlowNode.position.y = 0.84
        outerGlowNode.opacity = 0.55
        startGuidanceNode.addChildNode(outerGlowNode)

        let floorPulse = SCNAction.sequence([
            .group([
                .scale(to: 1.08, duration: 1.15),
                .fadeOpacity(to: 0.48, duration: 1.15)
            ]),
            .group([
                .scale(to: 1.0, duration: 1.15),
                .fadeOpacity(to: 0.72, duration: 1.15)
            ])
        ])
        floorHaloNode.runAction(.repeatForever(floorPulse))

        let columnPulse = SCNAction.sequence([
            .fadeOpacity(to: 0.68, duration: 1.1),
            .fadeOpacity(to: 0.86, duration: 1.1)
        ])
        columnNode.runAction(.repeatForever(columnPulse))
    }

    private func verticalBeaconTexture(
        color: UIColor,
        peakAlpha: CGFloat = 0.36,
        size: CGSize = CGSize(width: 16, height: 256)
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cgContext = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                color.withAlphaComponent(peakAlpha * 0.95).cgColor,
                color.withAlphaComponent(peakAlpha).cgColor,
                color.withAlphaComponent(peakAlpha * 0.42).cgColor,
                color.withAlphaComponent(0.0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.22, 0.68, 1.0]
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: locations
            ) else { return }
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: size.width / 2, y: size.height),
                end: CGPoint(x: size.width / 2, y: 0),
                options: []
            )
        }
    }

    private func publishStartPlacementDebugIfNeeded(frame: ARFrame) {
        guard isAligning, frame.timestamp - lastStartPlacementDebugAt >= 0.5 else { return }
        lastStartPlacementDebugAt = frame.timestamp

        let placement: String
        switch placementQuality {
        case .calibrating: placement = "calibrating"
        case .approximate(let meters): placement = String(format: "GPS estimate ±%.1fm", meters)
        case .precise: placement = "precise (world map)"
        }

        let registrationLine = registration.map {
            String(
                format: "route reg: start ±%.1fm yaw ±%.1f° pairs %d compass %@",
                $0.startSigmaMeters, $0.yawSigma * 180 / .pi, $0.gpsPairCount,
                route.compassYawRadians == nil ? "no" : "yes"
            )
        } ?? "route reg: unavailable"
        let fusionLine = fusionEstimate.map {
            String(
                format: "live fit: gps %d yaw ±%.1f° (gps heading %@) pos ±%.1fm",
                $0.gpsCount, $0.yawSigma * 180 / .pi, $0.usedGPSHeading ? "yes" : "no",
                $0.translationSigma
            )
        } ?? "live fit: waiting for GPS + compass"
        let poseLine = currentPose.map {
            String(format: "route pose: yaw %.1f° t %@", Double($0.yaw) * 180 / .pi, Self.vectorString($0.translation))
        } ?? "route pose: nil"

        let camera = frame.camera.transform.columns.3
        let current = locationService.currentLocation
        let lines = [
            "PLACEMENT DEBUG",
            "view: \(viewMode.rawValue) placement: \(placement)",
            "world map: \(expectsRelocalization ? "loaded" : "none") relocalized: \(isRelocalized ? "yes" : "no")",
            "align: \(alignmentState.rawValue) conf: \(String(format: "%.0f%%", alignmentConfidence * 100)) locked: \(alignmentLocked ? "yes" : "no")",
            "dist to start: \(Self.distanceString(distanceToRouteStart())) gate: \(String(format: "%.1fm", startGateMeters(locked: alignmentLocked)))",
            registrationLine,
            fusionLine,
            "current: \(Self.locationString(current)) GPS acc: \(Self.accuracyString(current))",
            "registered start: \(Self.locationString(registration?.startLocation))",
            "first fix: \(Self.locationString(route.startLocation))",
            poseLine,
            "manual: \(Self.vectorString(manualWorldOffset)) rot \(String(format: "%.1f°", Double(manualAlignment?.rotationY ?? 0) * 180 / .pi))",
            "camera world: \(Self.vectorString(SIMD3(camera.x, camera.y, camera.z)))"
        ]

        DispatchQueue.main.async {
            self.onStartPlacementDebugUpdate(lines.joined(separator: "\n"))
        }
    }

    private static func locationString(_ location: CLLocation?) -> String {
        guard let location else { return "nil" }
        return String(
            format: "%.7f, %.7f",
            location.coordinate.latitude,
            location.coordinate.longitude
        )
    }

    private static func accuracyString(_ location: CLLocation?) -> String {
        guard let location else { return "nil" }
        return String(format: "±%.1fm", location.horizontalAccuracy)
    }

    private static func distanceString(_ distance: Double?) -> String {
        guard let distance else { return "nil" }
        return String(format: "%.2fm / %.1fft", distance, distance * 3.28084)
    }

    private static func degreesString(_ degrees: Double?) -> String {
        guard let degrees else { return "nil" }
        return String(format: "%.1f°", degrees)
    }

    private static func vectorString(_ vector: SIMD3<Float>?) -> String {
        guard let vector else { return "nil" }
        return String(format: "x %.2f y %.2f z %.2f", vector.x, vector.y, vector.z)
    }

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

    private func createBoxNode() -> SCNNode {
        let candidates = [
            "3DModels/VoxelLootBox.usdz",
            "Models/3DModels/VoxelLootBox.usdz",
            "VoxelLootBox.usdz"
        ]
        for candidate in candidates {
            guard let scene = SCNScene(named: candidate) else { continue }

            let content = SCNNode()
            for child in scene.rootNode.childNodes {
                content.addChildNode(child.clone())
            }

            let (minBounds, maxBounds) = content.boundingBox
            let width = maxBounds.x - minBounds.x
            let height = maxBounds.y - minBounds.y
            let depth = maxBounds.z - minBounds.z
            let largestDimension = max(width, max(height, depth))
            guard largestDimension > 0.0001 else { continue }

            let scale: Float = 0.34 / largestDimension
            let center = SCNVector3(
                (minBounds.x + maxBounds.x) * 0.5,
                (minBounds.y + maxBounds.y) * 0.5,
                (minBounds.z + maxBounds.z) * 0.5
            )
            content.scale = SCNVector3(scale, scale, scale)
            content.position = SCNVector3(-center.x * scale, -center.y * scale, -center.z * scale)

            let wrapper = SCNNode()
            wrapper.addChildNode(content)
            return wrapper
        }

        let box = SCNBox(width: 0.305, height: 0.305, length: 0.305, chamferRadius: 0.015)
        let material = SCNMaterial()
        material.diffuse.contents  = UIColor(red: 0.55, green: 0.35, blue: 0.15, alpha: 1.0)
        material.specular.contents = UIColor(white: 0.3, alpha: 1.0)
        material.roughness.contents = NSNumber(value: 0.7)
        material.isDoubleSided = true
        box.materials = [material]

        return SCNNode(geometry: box)
    }

    private func createCoinNode() -> SCNNode {
        StarCoinAsset.makeNode()
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

    static func bearingDegrees(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) -
            sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
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

