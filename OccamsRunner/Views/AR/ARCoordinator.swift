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
    var onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    var onNearestItemDistance: (Double?) -> Void
    var onItemCollected: (UUID) -> Void
    var onDebugTick: (String) -> Void
    /// 0–1 intensity for the "camera points at start ring" screen glow.
    /// Re-assigned each SwiftUI render pass (same pattern as the other callbacks).
    var onRingGlowIntensity: ((Double) -> Void)?
    /// Signed bearing from camera forward to the start ring in degrees
    /// (0 = dead ahead, + = right, − = left, magnitude up to 180).  `nil` when
    /// no meaningful target direction is available (ring not positioned yet,
    /// or runner is essentially on top of the ring).  Drives the HUD compass.
    var onRingBearing: ((Double?) -> Void)?

    /// Shared state object written by SwiftUI gesture handlers and read each
    /// AR frame to apply manual position / rotation corrections to the route.
    var manualAlignment: ManualAlignmentState?

    private let routeGroupNode = SCNNode()
    private var pathNodes: [SCNNode] = []
    private(set) var coinNodes: [UUID: SCNNode] = [:]
    private(set) var pendingCollectionIds: Set<UUID> = []
    private(set) var boxNodes: [UUID: SCNNode] = [:]
    private var pendingBoxIds: Set<UUID> = []

    private var arrowIndicatorNode: SCNNode?

    /// GPS-anchored orange ring placed in AR world space at the recorded route
    /// start GPS coordinate.  Unlike routeGroupNode children this node is added
    /// directly to the scene root so its position is independent of the AR
    /// alignment — it is pure GPS truth, not AR-alignment truth.
    private var startGPSRingNode: SCNNode?

    /// Tracks whether `updateStartGPSRing` has successfully placed the ring
    /// at a real world position yet.  Until then the ring is parked off-screen
    /// so the user never sees it sitting at the AR session origin.
    private var startRingPositioned = false
    /// Once true the ring is a fixed physical-world anchor — ARKit tracking
    /// handles the user's motion relative to it, so the ring stops jittering
    /// around with per-frame compass noise.  This matches the stable
    /// "walk to start X ft" distance label as the source of truth.
    private var ringWorldLocked = false
    /// Running sum of world-space position samples used to average out
    /// compass and GPS jitter before we lock the ring.
    private var ringSampleSum: SIMD3<Float> = .zero
    private var ringSampleCount: Int = 0
    /// Number of quality-gated samples required before locking (~1 s @60fps).
    private let ringLockSamples = 60
    /// Preferred GPS accuracy (m) for a ring sample.  Samples worse than this
    /// are still accepted (so indoors / weak-signal runners aren't locked out)
    /// but require more of them before we lock the anchor.
    private let ringPreferredGPSAccuracy: Double = 20

    /// Flips true the first time the user enters the start gate.  Gates
    /// route/coin/box node construction so we don't build or render anything
    /// until the runner is physically standing at the recorded GPS start.
    private var startPhaseActivated = false

    // Hand pose detection
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private var lastHandPoseTime: TimeInterval = 0
    private let handPoseInterval: TimeInterval = 0.1  // 10 fps

    private var runMode: ARRunMode = .aligning
    private var runStartedAt: Date?
    private var collectionTickSerial: UInt64 = 0
    private var collectionCheckSerial: UInt64 = 0
    private var lastSkipReasonLogged: String?
    private var lastHeartbeatAt: Date = .distantPast
    private var frozenRouteWorldTransform: simd_float4x4?

    private var alignmentState: ARAlignmentState = .moveToStart
    private var alignmentConfidence: Double = 0
    /// Exponential moving average of per-frame raw confidence — smooths out
    /// transient tracking blips without introducing too much lag.
    private var smoothedConfidence: Double = 0
    private var alignmentLocked = false
    private var consecutiveGoodFrames = 0
    private var scanStartedAt: Date?
    /// How many consecutive GPS readings have placed the user beyond the start gate.
    /// We require several before resetting an established lock so GPS jitter can't
    /// knock out a good alignment on a single bad reading.
    private var consecutiveOutOfRangeGPS = 0

    private var statusTimer: Timer?
    private var collectionTimer: Timer?

    private let startGateDistanceMeters: Double = 3

    // Base Y offset applied to the route group so objects sit at chest height.
    // The manual alignment adds onto this baseline.  Default to -0.3 before
    // auto-orient runs; `autoOrientRoute` overwrites this with a value that
    // lands the route's first sample at the user's current ground plane,
    // regardless of what altitude the AR session origin ended up at.
    private var baseRouteY: Float = -0.3

    // MARK: - Auto-Alignment
    // Compass heading (degrees from north, clockwise) updated each SwiftUI render pass.
    // -1 = HeadingManager has not received a reading yet (never treat as "pointing north").
    var compassHeading: Double = -1
    // CLHeading.headingAccuracy in degrees. -1 = invalid / not yet calibrated.
    var compassHeadingAccuracy: Double = -1
    // Whether the one-shot GPS+compass auto-orient has fired this alignment session.
    private var hasAutoAligned = false
    // World-space XZ base position for the route group, set by autoOrientRoute().
    // Manual gesture deltas are added on top of this each frame in applyManualAlignment().
    private var autoBasePosition: SIMD3<Float> = .zero
    // Y-rotation base (radians) set by autoOrientRoute(); manual rotation adds onto it.
    private var autoBaseRotation: Float = 0

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
        routeGroupNode.position.y = baseRouteY

        // Phase-1 content only: the runner sees the orange GPS ring + beacon.
        // The on-screen HUD compass (not an AR node) indicates direction.
        // Route lines, coins and boxes are built lazily by activateStartPhase()
        // on first gate entry.
        setupArrowIndicator()
        setupStartGPSRing()
        updateAlignmentStatusFromGPS()
    }

    /// Called exactly once, the first time the runner enters the start gate.
    /// Builds the route path lines, coin nodes and box nodes and makes them
    /// visible.  Subsequent gate re-entries only toggle visibility via
    /// updateRouteVisibility() — we don't rebuild geometry.
    private func activateStartPhase() {
        guard !startPhaseActivated else { return }
        startPhaseActivated = true
        buildRoutePath()
        buildCoinNodes(forceRebuild: true)
        buildBoxNodes(forceRebuild: true)
        updateRouteVisibility()
    }

    /// Centralises visibility rules for route lines, coins and boxes.
    ///   – moveToStart (outside gate): everything hidden
    ///   – aligning/realigning inside gate: everything visible
    ///   – running: coins + boxes visible, path preview hidden
    private func updateRouteVisibility() {
        let inMoveToStart = (alignmentState == .moveToStart)
        let pathHidden: Bool
        let collectiblesHidden: Bool

        switch runMode {
        case .running:
            pathHidden = true
            collectiblesHidden = false
        case .aligning, .realigning:
            pathHidden = inMoveToStart
            collectiblesHidden = inMoveToStart
        }

        for node in pathNodes { node.isHidden = pathHidden }
        for node in coinNodes.values { node.isHidden = collectiblesHidden }
        for node in boxNodes.values { node.isHidden = collectiblesHidden }
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
            // Keep session delegate active for hand pose detection during running.
            arView?.session.delegate = self

        case .aligning, .realigning:
            // Unfreeze route transform so AR alignment can adjust it.
            frozenRouteWorldTransform = nil
            // Restore frame callbacks for tracking updates.
            arView?.session.delegate = self
            alignmentLocked = false
            consecutiveGoodFrames = 0
            consecutiveOutOfRangeGPS = 0
            scanStartedAt = nil
            alignmentState = .scanning
            hasAutoAligned = false
            autoBasePosition = .zero
            autoBaseRotation = 0
            // Re-sample the physical-world ring anchor on (re)align so a bad
            // previous lock doesn't persist.  Keeps the ring where the stable
            // GPS distance label says the start is.
            ringWorldLocked = false
            ringSampleSum = .zero
            ringSampleCount = 0
            if previousMode == .running {
                // Coming back from a run: force a fresh placement too.
                startRingPositioned = false
                startGPSRingNode?.simdWorldPosition = SIMD3<Float>(0, -1000, 0)
            }
        }

        updateRouteVisibility()
        // The GPS ring stays visible for the entire alignment phase so the
        // runner always has a physical target to move to.  Only hidden once
        // the quest is actually running.
        let showRing = (newMode == .aligning || newMode == .realigning) && startRingPositioned
        startGPSRingNode?.isHidden = !showRing
    }

    func updateQuest(_ quest: Quest, dataStore: DataStore) {
        // updateUIView is called on the main thread; keep coinNodes mutations there.
        assert(Thread.isMainThread)
        self.quest = quest
        // Don't materialise coin geometry before the runner has reached the
        // start gate for the first time — phase 1 is navigation-only.
        guard startPhaseActivated else { return }
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

        // During alignment we only render the first 300 m of the route.
        // A full multi-mile loop rendered in AR space looks like a spiderweb
        // of lines going in every direction; the short preview shows enough
        // context to orient without the confusion.
        let alignmentPreviewMeters: Float = 300
        var cumDist: Float = 0
        var previewEnd = points.count - 1
        for i in 1..<points.count {
            let p0 = SIMD3<Float>(points[i-1].x, 0, points[i-1].z)
            let p1 = SIMD3<Float>(points[i].x,   0, points[i].z)
            cumDist += simd_distance(p0, p1)
            if cumDist >= alignmentPreviewMeters {
                previewEnd = i
                break
            }
        }

        for i in 0..<previewEnd {
            let segment = pathSegmentNode(from: points[i], to: points[i + 1])
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
        // Any freshly-created nodes inherit the current phase visibility.
        updateRouteVisibility()
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
                routeGroupNode.addChildNode(node)
                boxNodes[box.id] = node
            }
        }
        updateRouteVisibility()
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
        // Sit at the bottom-center of the view: centered (x=0), below center (y=-0.25), 0.7 m in front
        arrow.position = SCNVector3(0, -0.25, -0.7)
        arrow.isHidden = true
        // Always draw on top of AR geometry so it isn't occluded by route nodes
        arrow.renderingOrder = 100
        cameraNode.addChildNode(arrow)
        arrowIndicatorNode = arrow
    }

    private func createArrowIndicatorNode() -> SCNNode {
        let mat = SCNMaterial()
        mat.diffuse.contents  = UIColor.orange
        mat.emission.contents = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
        mat.isDoubleSided = true

        // Shaft: thin cylinder along +Y
        let shaft = SCNCylinder(radius: 0.006, height: 0.055)
        shaft.materials = [mat]
        let shaftNode = SCNNode(geometry: shaft)

        // Head: cone with tip at +Y, base at shaft top
        let head = SCNCone(topRadius: 0, bottomRadius: 0.018, height: 0.035)
        head.materials = [mat]
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, 0.045, 0)

        let container = SCNNode()
        container.addChildNode(shaftNode)
        container.addChildNode(headNode)
        return container
    }

    private func updateArrowDirection() {
        guard let arrow = arrowIndicatorNode,
              let cameraNode = arView?.pointOfView else { return }

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

        // Compute direction from arrow's position to the coin, in camera-local space
        let coinCamLocal  = cameraNode.convertPosition(target.worldPosition, from: nil)
        let arrowCamLocal = arrow.position
        let dir = simd_float3(
            coinCamLocal.x - arrowCamLocal.x,
            coinCamLocal.y - arrowCamLocal.y,
            coinCamLocal.z - arrowCamLocal.z
        )
        guard simd_length(dir) > 0.01 else { return }
        let dirNorm = simd_normalize(dir)

        // Rotate arrow so its +Y tip axis points toward the coin
        let yAxis = simd_float3(0, 1, 0)
        let dot = simd_dot(yAxis, dirNorm)
        if dot > 0.9999 {
            arrow.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        } else if dot < -0.9999 {
            arrow.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            arrow.simdOrientation = simd_quatf(from: yAxis, to: dirNorm)
        }
    }

    // MARK: - Manual Alignment

    /// Applies the user's manual position and rotation corrections to the route group.
    /// Called every AR frame while in aligning/realigning mode so the adjustments
    /// are visible in real-time as the user drags/rotates.
    private func applyManualAlignment() {
        guard let manual = manualAlignment else { return }

        // Convert camera-relative offsets to AR world-space coordinates so the
        // route slides in the direction the user actually dragged regardless of
        // which way the camera is facing.
        //
        //   manual.worldX  = "screen right" offset  (drag right → route goes right on screen)
        //   manual.worldZ  = "screen depth" offset  (spread → closer, pinch → further)
        //   manual.worldY  = vertical offset         (drag up → route goes up; Y is up in both spaces)
        //
        // We flatten the camera's right and forward vectors onto the horizontal
        // plane so that tilting the phone doesn't cause vertical drift during
        // a horizontal drag.
        var deltaX: Float = 0
        var deltaZ: Float = 0

        if let cam = arView?.session.currentFrame?.camera.transform {
            // Camera's right vector is its X column; forward is -Z column (ARKit looks in -Z).
            let rightFlat   = SIMD3<Float>( cam.columns.0.x, 0,  cam.columns.0.z)
            let forwardFlat = SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z)

            // Guard against degenerate vectors (phone pointing nearly straight up/down).
            if simd_length(rightFlat) > 0.001 && simd_length(forwardFlat) > 0.001 {
                let r = simd_normalize(rightFlat)   * manual.worldX
                let f = simd_normalize(forwardFlat) * manual.worldZ
                deltaX = r.x + f.x
                deltaZ = r.z + f.z
            } else {
                deltaX = manual.worldX
                deltaZ = manual.worldZ
            }
        }

        // autoBasePosition is the world-space position set by auto-orient.
        // Manual gesture deltas are added on top so user fine-tunes from the auto-aligned base.
        routeGroupNode.simdPosition = SIMD3<Float>(
            autoBasePosition.x + deltaX,
            baseRouteY + manual.worldY,
            autoBasePosition.z + deltaZ
        )
        routeGroupNode.simdOrientation = simd_quatf(
            angle: autoBaseRotation + manual.rotationY,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    // MARK: - Auto-Orientation Helpers

    /// GPS bearing in radians from north (clockwise positive) using the haversine formula.
    private func gpsBearing(from c1: CLLocationCoordinate2D, to c2: CLLocationCoordinate2D) -> Float {
        let lat1 = Float(c1.latitude  * .pi / 180)
        let lat2 = Float(c2.latitude  * .pi / 180)
        let dLon = Float((c2.longitude - c1.longitude) * .pi / 180)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)  // radians, 0 = north, clockwise positive
    }

    /// One-shot: positions and rotates the route group so that localTrack[0] (the recording
    /// start) lands at the camera's current XZ position, and the route's initial direction
    /// matches its real-world GPS bearing.  Uses compass heading to bridge the arbitrary
    /// rotation between the recording AR session and the current playback AR session.
    private func autoOrientRoute(frame: ARFrame) {
        guard !hasAutoAligned,
              route.localTrack.count >= 2,
              route.geoTrack.count >= 2 else { return }

        // Don't fire while ARKit is still initializing — the camera transform
        // is unreliable and the north-vector math produces garbage.
        if case .notAvailable = frame.camera.trackingState { return }
        if case .limited(let reason) = frame.camera.trackingState, reason == .initializing { return }

        // Require a valid, calibrated compass reading. Using the default -1 value
        // (no reading yet) or a >30° accuracy reading would rotate the entire
        // route skeleton in the wrong direction with no retry possible.
        // Returning here keeps hasAutoAligned = false so we retry next frame.
        guard compassHeading >= 0,
              compassHeadingAccuracy >= 0,
              compassHeadingAccuracy < 30 else {
            locationService.logRunEvent(String(format:
                "[AutoOrient] waiting for compass (hdg=%.0f acc=%.0f°)",
                compassHeading, compassHeadingAccuracy))
            return
        }

        // --- Find a stable bearing sample ~30 m into the route ---
        // Using a short baseline rather than just the first two points avoids noise
        // from GPS jitter or AR drift at the moment recording started.
        var cumLocalDist: Float = 0
        var localBearingIdx = route.localTrack.count - 1
        for i in 1..<route.localTrack.count {
            let prev = SIMD3<Float>(Float(route.localTrack[i-1].x), 0, Float(route.localTrack[i-1].z))
            let curr = SIMD3<Float>(Float(route.localTrack[i].x),   0, Float(route.localTrack[i].z))
            cumLocalDist += simd_distance(prev, curr)
            if cumLocalDist >= 30 {
                localBearingIdx = i
                break
            }
        }

        var cumGpsDist: Double = 0
        var gpsBearingIdx = route.geoTrack.count - 1
        for i in 1..<route.geoTrack.count {
            let prev = CLLocation(latitude: route.geoTrack[i-1].latitude, longitude: route.geoTrack[i-1].longitude)
            let curr = CLLocation(latitude: route.geoTrack[i].latitude,   longitude: route.geoTrack[i].longitude)
            cumGpsDist += curr.distance(from: prev)
            if cumGpsDist >= 30 {
                gpsBearingIdx = i
                break
            }
        }

        // --- AR-space bearing of the route at start (radians from AR –Z axis, clockwise) ---
        let dx = Float(route.localTrack[localBearingIdx].x - route.localTrack[0].x)
        let dz = Float(route.localTrack[localBearingIdx].z - route.localTrack[0].z)
        guard dx != 0 || dz != 0 else { return }
        let arBearing = atan2(dx, -dz)

        // --- Real-world direction the route was heading at its start (radians, north=0, clockwise) ---
        // Prefer the compass heading recorded in the first localTrack sample (magnetometer reading
        // captured at the exact moment).  Fall back to computing the bearing from consecutive GPS
        // samples when the stored heading is not available (older recordings without this field).
        let routeStartBearingRad: Float
        let bearingSource: String
        if let storedHeading = route.localTrack[0].compassHeading, storedHeading >= 0 {
            routeStartBearingRad = Float(storedHeading * .pi / 180)
            bearingSource = String(format: "stored %.0f°", storedHeading)
        } else {
            routeStartBearingRad = gpsBearing(
                from: route.geoTrack[0].coordinate,
                to:   route.geoTrack[gpsBearingIdx].coordinate
            )
            bearingSource = String(format: "GPS-derived %.1f°", routeStartBearingRad * 180 / .pi)
        }

        // --- Camera horizontal heading in this AR session (radians from AR –Z axis, clockwise) ---
        // Derived from the camera transform so it stays valid even when the phone is tilted.
        let camTransform = frame.camera.transform
        let camFwdX = -camTransform.columns.2.x
        let camFwdZ = -camTransform.columns.2.z
        let cameraHeadingInAR = atan2(camFwdX, -camFwdZ)

        // --- Compass heading of camera forward direction (radians from north, clockwise) ---
        let compassRad = Float(compassHeading * .pi / 180)

        // Derivation:
        //   In playback AR space, any AR angle θ maps to compass bearing = compassRad + (θ - cameraHeadingInAR)
        //   Route initial direction in AR = arBearing; after Y-rotation R it becomes arBearing + R.
        //   We want: compassRad + (arBearing + R - cameraHeadingInAR) = routeStartBearingRad
        //   ∴ R = routeStartBearingRad - compassRad + cameraHeadingInAR - arBearing
        let R = routeStartBearingRad - compassRad + cameraHeadingInAR - arBearing

        locationService.logRunEvent(String(format:
            "[AutoOrient] bearingSource=%@ arBearing=%.1f° camera=%.1f° compass=%.1f° rotation=%.1f°",
            bearingSource,
            arBearing * 180 / .pi,
            cameraHeadingInAR * 180 / .pi,
            compassHeading,
            R * 180 / .pi
        ))

        // --- Position: rotate localTrack[0] by R, then offset group so it lands at camera XZ ---
        let trackStartX = Float(route.localTrack[0].x)
        let trackStartZ = Float(route.localTrack[0].z)
        let cosR = cos(R)
        let sinR = sin(R)
        let rotatedStartX = trackStartX * cosR - trackStartZ * sinR
        let rotatedStartZ = trackStartX * sinR + trackStartZ * cosR

        let cameraX = frame.camera.transform.columns.3.x
        let cameraY = frame.camera.transform.columns.3.y
        let cameraZ = frame.camera.transform.columns.3.z

        autoBasePosition = SIMD3<Float>(cameraX - rotatedStartX, 0, cameraZ - rotatedStartZ)
        autoBaseRotation = R

        // --- Altitude: anchor the route's start to (ground + altitude delta) ---
        // The recorded localTrack Y values are relative to the AR session
        // origin from recording time, which can be at any altitude.  We shift
        // `baseRouteY` so the route's first sample lands at the user's ground
        // plane, then bias by the recorded GPS altitude delta so the start
        // point appears higher or lower than the runner based on the real-
        // world elevation difference.  GPS vertical accuracy is noisy — we
        // only apply the delta when both readings have decent accuracy.
        let trackStartY = Float(route.localTrack[0].y)
        let groundY = cameraY - 1.5
        var altitudeDeltaY: Float = 0
        if let current = locationService.currentLocation,
           let start = route.startLocation,
           current.verticalAccuracy > 0, current.verticalAccuracy <= 15,
           start.verticalAccuracy > 0,   start.verticalAccuracy <= 15 {
            altitudeDeltaY = Float(start.altitude - current.altitude)
        }
        baseRouteY = groundY + altitudeDeltaY - trackStartY

        locationService.logRunEvent(String(format:
            "[AutoOrient] altitude anchor: camY=%.2f groundY=%.2f altDelta=%.2f trackStartY=%.2f → baseRouteY=%.2f",
            cameraY, groundY, altitudeDeltaY, trackStartY, baseRouteY
        ))

        hasAutoAligned = true
    }

    // MARK: - Alignment

    private func updateAlignmentStatusFromGPS() {
        guard runMode == .aligning || runMode == .realigning else { return }
        let distance = distanceToRouteStart()

        if let distance, distance > startGateDistanceMeters {
            consecutiveOutOfRangeGPS += 1
            // Require 3 consecutive out-of-range GPS readings before resetting a
            // lock — GPS can jitter 20-40 m so a single bad fix must not undo
            // good alignment.
            if consecutiveOutOfRangeGPS >= 3 && alignmentState != .moveToStart {
                alignmentState = .moveToStart
                alignmentConfidence = min(alignmentConfidence, 0.2)
                alignmentLocked = false
                consecutiveGoodFrames = 0
                scanStartedAt = nil
                hasAutoAligned = false  // re-orient when the runner returns to the gate
                updateRouteVisibility()  // hide route/coins/boxes again
            }
            publishAlignment(distance: distance)
            return
        }
        consecutiveOutOfRangeGPS = 0

        // First entry into the gate builds the route geometry.
        if !startPhaseActivated {
            activateStartPhase()
        }

        if !alignmentLocked {
            if scanStartedAt == nil {
                scanStartedAt = Date()
            }
            let previous = alignmentState
            alignmentState = .scanning
            if previous == .moveToStart {
                updateRouteVisibility()  // reveal route on gate (re-)entry
            }
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
        if runMode == .running {
            let now = frame.timestamp
            if now - lastHandPoseTime >= handPoseInterval {
                lastHandPoseTime = now
                processHandPose(frame: frame)
            }
            return
        }
        guard runMode == .aligning || runMode == .realigning else { return }

        // Phase 1 helpers — run regardless of whether the user has reached
        // the gate yet, because these are what guide them *to* the gate.
        updateStartGPSRing(frame: frame)
        updateRingGlowIntensity(frame: frame)
        updateRingBearing(frame: frame)

        // Apply manual position/rotation corrections every frame so the
        // AR view updates in real-time as the user adjusts.
        applyManualAlignment()

        guard (distanceToRouteStart() ?? 0) <= startGateDistanceMeters else { return }

        // First frame inside the gate: auto-position and auto-rotate the route using
        // GPS bearing + compass so it appears at the user's location facing the right way.
        if !hasAutoAligned {
            autoOrientRoute(frame: frame)
        }

        guard !alignmentLocked else { return }

        // --- Feature density score ---
        let featureCount = Double(frame.rawFeaturePoints?.points.count ?? 0)
        // Scale: 0 at 0 features, 1.0 at ≥300 features (raised from 250 for stricter signal).
        let featureScore = min(1.0, featureCount / 300.0)

        // --- Tracking state score ---
        let trackingScore: Double
        let isTrackingNormal: Bool
        switch frame.camera.trackingState {
        case .normal:
            trackingScore = 1.0
            isTrackingNormal = true
        case .limited(let reason):
            isTrackingNormal = false
            switch reason {
            case .relocalizing:         trackingScore = 0.65
            case .excessiveMotion:      trackingScore = 0.40
            case .insufficientFeatures: trackingScore = 0.30
            case .initializing:         trackingScore = 0.35
            @unknown default:           trackingScore = 0.30
            }
        case .notAvailable:
            trackingScore = 0
            isTrackingNormal = false
        }

        // --- World mapping status score ---
        let mappingScore: Double
        let isMappingGood: Bool
        switch frame.worldMappingStatus {
        case .mapped:
            mappingScore = 1.0
            isMappingGood = true
        case .extending:
            mappingScore = 0.8
            isMappingGood = true
        case .limited:
            mappingScore = 0.45
            isMappingGood = false
        case .notAvailable:
            mappingScore = 0.2
            isMappingGood = false
        @unknown default:
            mappingScore = 0.3
            isMappingGood = false
        }

        // --- Raw composite confidence ---
        let rawConfidence = max(0.0, min(1.0,
            (featureScore * 0.35) + (trackingScore * 0.35) + (mappingScore * 0.30)
        ))

        // --- EMA smoothing (α=0.25) to damp transient tracking blips ---
        // A single bad frame won't crash confidence, but sustained degradation will.
        smoothedConfidence = 0.75 * smoothedConfidence + 0.25 * rawConfidence
        alignmentConfidence = smoothedConfidence

        // --- Consecutive-good-frame counter ---
        // Increment when tracking is normal, mapping is good, and smoothed
        // confidence clears 0.70. On catastrophic loss hard-reset to 0.
        // On mild degradation hold the counter (don't decay) so a brief
        // glitch doesn't undo accumulated progress.
        if isTrackingNormal && isMappingGood && smoothedConfidence >= 0.70 {
            consecutiveGoodFrames += 1
        } else if !isTrackingNormal || smoothedConfidence < 0.40 {
            // Catastrophic: tracking unavailable or severely low confidence.
            consecutiveGoodFrames = 0
        }
        // else: mild degradation — hold counter, don't increment or decrement.

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

    // MARK: - GPS Start Ring

    /// Creates the orange torus and adds it directly to the scene root (world space).
    /// Called once from configureInitialScene(); position is driven each frame by
    /// updateStartGPSRing(frame:) using live GPS + compass, not AR alignment.
    private func setupStartGPSRing() {
        guard let arView, route.startLocation != nil else { return }

        // Remove any stale ring from a previous alignment session.
        startGPSRingNode?.removeFromParentNode()

        let orange = UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 0.92)

        // Parent node — holds the ring, beacon column and halo together so
        // they all move as one unit when updateStartGPSRing() repositions it.
        let root = SCNNode()

        // --- Flat torus sitting on the ground ---
        let torus = SCNTorus(ringRadius: 1.0, pipeRadius: 0.06)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents  = orange
        ringMat.emission.contents = orange.withAlphaComponent(0.65)
        ringMat.isDoubleSided = true
        torus.materials = [ringMat]
        let ring = SCNNode(geometry: torus)

        // Gentle XZ pulse so the ring is easy to spot even at distance.
        let pulse = CABasicAnimation(keyPath: "scale")
        pulse.fromValue = NSValue(scnVector3: SCNVector3(0.88, 1.0, 0.88))
        pulse.toValue   = NSValue(scnVector3: SCNVector3(1.12, 1.0, 1.12))
        pulse.duration  = 1.4
        pulse.autoreverses  = true
        pulse.repeatCount   = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.addAnimation(pulse, forKey: "pulse")
        root.addChildNode(ring)

        // --- Vertical beacon column (pillar of light) — visible from far away ---
        // 60 m tall and wider than before so it reads as a clear marker even
        // at 60+ ft.  Pulses brightness so the eye can lock onto it.
        let beaconHeight: CGFloat = 60
        let beacon = SCNCylinder(radius: 0.35, height: beaconHeight)
        let beaconMat = SCNMaterial()
        beaconMat.diffuse.contents  = orange.withAlphaComponent(0.35)
        beaconMat.emission.contents = orange.withAlphaComponent(1.0)
        beaconMat.transparent.contents = orange.withAlphaComponent(0.85)
        beaconMat.blendMode = .add
        beaconMat.isDoubleSided = true
        beaconMat.writesToDepthBuffer = false   // don't z-occlude ring / other geo
        beacon.materials = [beaconMat]
        let beaconNode = SCNNode(geometry: beacon)
        beaconNode.position = SCNVector3(0, Float(beaconHeight) / 2, 0)
        beaconNode.renderingOrder = 10

        // Brightness pulse: scale the beam's X/Z so it "breathes" visibly from
        // a distance.  1.4 s period matches the ring pulse.
        let beaconPulse = CABasicAnimation(keyPath: "scale")
        beaconPulse.fromValue = NSValue(scnVector3: SCNVector3(0.85, 1.0, 0.85))
        beaconPulse.toValue   = NSValue(scnVector3: SCNVector3(1.35, 1.0, 1.35))
        beaconPulse.duration  = 1.4
        beaconPulse.autoreverses  = true
        beaconPulse.repeatCount   = .infinity
        beaconPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beaconNode.addAnimation(beaconPulse, forKey: "beaconPulse")
        root.addChildNode(beaconNode)

        // --- Inner bright core beam ---
        // A thin, very bright white-core cylinder inside the orange beam so
        // the beacon reads as a laser line when viewed against sky or trees.
        let core = SCNCylinder(radius: 0.08, height: beaconHeight)
        let coreMat = SCNMaterial()
        coreMat.diffuse.contents  = UIColor.white.withAlphaComponent(0.9)
        coreMat.emission.contents = UIColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 1.0)
        coreMat.blendMode = .add
        coreMat.isDoubleSided = true
        coreMat.writesToDepthBuffer = false
        core.materials = [coreMat]
        let coreNode = SCNNode(geometry: core)
        coreNode.position = SCNVector3(0, Float(beaconHeight) / 2, 0)
        coreNode.renderingOrder = 12
        root.addChildNode(coreNode)

        // --- Hazy halo sphere around the ring ---
        // Large, translucent, additive — gives the ring a soft "glow" aura
        // when seen at distance so the eye can find it on the horizon.
        let halo = SCNSphere(radius: 2.5)
        halo.segmentCount = 24
        let haloMat = SCNMaterial()
        haloMat.diffuse.contents  = UIColor.clear
        haloMat.emission.contents = orange.withAlphaComponent(0.5)
        haloMat.transparent.contents = orange.withAlphaComponent(0.5)
        haloMat.blendMode = .add
        haloMat.isDoubleSided = true
        haloMat.writesToDepthBuffer = false
        halo.materials = [haloMat]
        let haloNode = SCNNode(geometry: halo)
        haloNode.position = SCNVector3(0, 0.6, 0)
        haloNode.renderingOrder = 11

        // Halo pulses larger/smaller to create a "heartbeat" you can see
        // from distance even if the torus itself is below the horizon.
        let haloPulse = CABasicAnimation(keyPath: "scale")
        haloPulse.fromValue = NSValue(scnVector3: SCNVector3(0.7, 0.7, 0.7))
        haloPulse.toValue   = NSValue(scnVector3: SCNVector3(1.6, 1.6, 1.6))
        haloPulse.duration  = 1.4
        haloPulse.autoreverses  = true
        haloPulse.repeatCount   = .infinity
        haloPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloNode.addAnimation(haloPulse, forKey: "haloPulse")
        root.addChildNode(haloNode)

        // Park the ring far below ground until updateStartGPSRing() places it
        // using live GPS.  This prevents a brief flash of the ring sitting at
        // the AR world origin on the first frame.
        root.simdPosition = SIMD3<Float>(0, -1000, 0)
        startRingPositioned = false

        arView.scene.rootNode.addChildNode(root)
        startGPSRingNode = root
    }

    // MARK: - Ring Bearing (HUD compass)

    /// Every AR frame during aligning/realigning: publish the signed horizontal
    /// bearing (degrees) from camera forward to the ring so a SwiftUI HUD
    /// compass can rotate its needle to aim at the target.
    ///   0°  = ring is straight ahead
    ///   +90 = ring is 90° to the right
    ///   -90 = ring is 90° to the left
    ///   ±180 = ring is directly behind the runner
    /// Publishes `nil` when the ring hasn't been positioned yet or the runner
    /// is essentially on top of it (no meaningful direction).
    private func updateRingBearing(frame: ARFrame) {
        guard startRingPositioned,
              let ring = startGPSRingNode else {
            onRingBearing?(nil)
            return
        }

        let cam = frame.camera.transform
        let camX = cam.columns.3.x
        let camZ = cam.columns.3.z
        let ringPos = ring.simdWorldPosition

        let dx = ringPos.x - camX
        let dz = ringPos.z - camZ
        let horizDist = sqrt(dx * dx + dz * dz)
        // Less than 0.5 m: no meaningful heading.  Hide the needle.
        guard horizDist > 0.5 else { onRingBearing?(nil); return }

        // atan2(dx, -dz): 0 → AR -Z axis, + clockwise.
        let ringYaw = atan2(dx, -dz)

        // Camera heading in AR space, derived the same way for consistency.
        let camFwdX = -cam.columns.2.x
        let camFwdZ = -cam.columns.2.z
        let camFwdLen = sqrt(camFwdX * camFwdX + camFwdZ * camFwdZ)
        guard camFwdLen > 0.001 else { onRingBearing?(nil); return }
        let camYaw = atan2(camFwdX, -camFwdZ)

        // Relative bearing, normalised to [-π, π].
        var rel = ringYaw - camYaw
        if rel >  .pi { rel -= 2 * .pi }
        if rel < -.pi { rel += 2 * .pi }

        onRingBearing?(Double(rel) * 180 / .pi)
    }

    // MARK: - Ring Glow Intensity

    /// How intensely should the screen-edge glow overlay shine this frame?
    /// Combines two factors:
    ///   – alignment: how close the camera forward vector is to pointing at
    ///     the ring (dot product, clamped to 0…1)
    ///   – usefulness: only glow while the runner is beyond a few metres; up
    ///     close the ring itself dominates the view.
    private func updateRingGlowIntensity(frame: ARFrame) {
        guard let ring = startGPSRingNode,
              alignmentState == .moveToStart else {
            onRingGlowIntensity?(0)
            return
        }

        let cam = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let ringPos = ring.simdWorldPosition

        let toRing = ringPos - camPos
        let distance = simd_length(toRing)
        guard distance > 0.01 else { onRingGlowIntensity?(0); return }
        let toRingNorm = toRing / distance

        // Camera forward (AR -Z), flattened to horizontal plane for stable dot
        // even as the runner tilts the phone.
        var fwd = SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z)
        let fwdLen = simd_length(fwd)
        guard fwdLen > 0.001 else { onRingGlowIntensity?(0); return }
        fwd /= fwdLen
        let toRingFlat = simd_normalize(SIMD3<Float>(toRingNorm.x, 0, toRingNorm.z))

        // Dot product 1 = dead-on, 0 = 90° off, <0 = behind user.
        let alignment = max(0, simd_dot(fwd, toRingFlat))

        // Distance factor: no glow inside 4 m, ramps to full by ~25 m.
        let distanceFactor = Float(max(0, min(1, (distance - 4) / 21)))

        // Exponent sharpens the falloff so the glow feels "aimed" rather than
        // always-on.  pow(alignment, 4) means user needs to look fairly
        // directly at the ring to get a strong glow.
        let sharpAlignment = pow(alignment, 4)

        let intensity = Double(sharpAlignment * distanceFactor)
        onRingGlowIntensity?(intensity)
    }

    /// Every AR frame while aligning/realigning: project the recorded GPS start
    /// coordinate into AR world space and move the ring there.
    ///
    /// Math summary:
    ///   1. Compute north/east offset in metres from current GPS to route start GPS.
    ///   2. Derive the north direction in AR world space from compass heading and
    ///      camera forward vector (same approach used in autoOrientRoute).
    ///   3. East direction = north rotated 90° clockwise in the XZ plane.
    ///   4. Ring world position = camera XZ  +  northOffset * northVec  +  eastOffset * eastVec.
    ///   5. Ring Y = camera Y − 1.5 m (approximates ground level).
    private func updateStartGPSRing(frame: ARFrame) {
        guard let ringNode = startGPSRingNode,
              let currentLocation = locationService.currentLocation,
              let startLocation   = route.startLocation else { return }

        // Once locked, the ring is a fixed physical-world anchor.  ARKit
        // tracking handles the user's motion relative to it, so we stop
        // recomputing its position every frame — this matches the stable
        // GPS-only distance label as the source of truth for the start.
        if ringWorldLocked { return }

        // --- Quality gate ---
        // Reject only the very worst conditions.  Being too strict leaves the
        // ring permanently unplaced indoors / with weak GPS.  Tracking is
        // acceptable for any state except `.notAvailable`; accuracy just
        // influences how many samples we need before locking.
        if case .notAvailable = frame.camera.trackingState {
            onDebugTick("[Ring] tracking=notAvailable, skipping sample")
            return
        }
        guard currentLocation.horizontalAccuracy > 0 else {
            onDebugTick("[Ring] GPS accuracy unknown, skipping sample")
            return
        }
        // Require a valid, reasonably-calibrated compass reading before sampling.
        // compassHeading == -1 means HeadingManager hasn't delivered its first reading;
        // using that value (or any reading with >30° uncertainty) would place the ring
        // in completely the wrong direction and lock it there after ~1 second.
        guard compassHeading >= 0,
              compassHeadingAccuracy >= 0,
              compassHeadingAccuracy < 30 else {
            onDebugTick(String(format: "[Ring] compass not ready (hdg=%.0f acc=%.0f°), skipping",
                               compassHeading, compassHeadingAccuracy))
            return
        }
        let samplesNeeded = currentLocation.horizontalAccuracy <= ringPreferredGPSAccuracy
            ? ringLockSamples
            : ringLockSamples * 2

        // --- Geographic offset (metres) from current position to route start ---
        let deltaLat = startLocation.coordinate.latitude  - currentLocation.coordinate.latitude
        let deltaLon = startLocation.coordinate.longitude - currentLocation.coordinate.longitude

        let metersPerDegLat = 111_111.0
        let metersPerDegLon = 111_111.0 * cos(currentLocation.coordinate.latitude * .pi / 180)

        let northOffsetM = Float(deltaLat * metersPerDegLat)  // + = start is north of current
        let eastOffsetM  = Float(deltaLon * metersPerDegLon)  // + = start is east of current

        // --- Camera forward direction flattened onto XZ plane ---
        let cam = frame.camera.transform
        let camFwdX = -cam.columns.2.x
        let camFwdZ = -cam.columns.2.z
        let camFwdLen = sqrt(camFwdX * camFwdX + camFwdZ * camFwdZ)
        guard camFwdLen > 0.001 else { return }
        let cfX = camFwdX / camFwdLen
        let cfZ = camFwdZ / camFwdLen

        // --- North direction in AR world space ---
        // Camera forward points toward compass heading degrees.
        // Rotating camera forward by -compassHeading gives the north vector.
        let h = Float(compassHeading * .pi / 180)  // radians, clockwise from north
        let northX =  cos(h) * cfX + sin(h) * cfZ
        let northZ = -sin(h) * cfX + cos(h) * cfZ

        // --- East direction = north rotated -90° around +Y (90° clockwise
        // when viewed from above in a right-handed Y-up coordinate system).
        // For rotation by −π/2: (nx, nz) → (-nz, nx).
        let eastX = -northZ
        let eastZ =  northX

        // --- AR world offset to the GPS start point ---
        let dx = northOffsetM * northX + eastOffsetM * eastX
        let dz = northOffsetM * northZ + eastOffsetM * eastZ

        // Camera world position
        let cameraPos = cam.columns.3
        let groundY   = cameraPos.y - 1.5   // approximate ground: 1.5 m below phone

        // --- Altitude: offset ring Y by the recorded start's altitude delta ---
        // If the user is standing lower than where recording started, the ring
        // should appear higher than their ground; if they're standing higher,
        // it should appear lower.  GPS vertical accuracy is noisy — we only
        // use the delta when both readings have reasonable vertical accuracy,
        // otherwise the ring stays on the user's ground plane.
        var altitudeDeltaY: Float = 0
        if currentLocation.verticalAccuracy > 0,
           currentLocation.verticalAccuracy <= 15,
           startLocation.verticalAccuracy > 0,
           startLocation.verticalAccuracy <= 15 {
            altitudeDeltaY = Float(startLocation.altitude - currentLocation.altitude)
        }

        let sample = SIMD3<Float>(cameraPos.x + dx, groundY + altitudeDeltaY, cameraPos.z + dz)

        // Accumulate samples into a running mean so compass / GPS jitter
        // averages out before we commit to a physical anchor position.
        ringSampleSum   += sample
        ringSampleCount += 1
        let mean = ringSampleSum / Float(ringSampleCount)

        ringNode.simdWorldPosition = mean

        // First successful placement: reveal the ring.  Kept visible for the
        // entire aligning/realigning phase so the runner always has a target.
        if !startRingPositioned {
            startRingPositioned = true
            if runMode == .aligning || runMode == .realigning {
                ringNode.isHidden = false
            }
            onDebugTick(String(format:
                "[Ring] placed @ (%.1f, %.1f, %.1f) camY=%.2f acc=%.1fm",
                mean.x, mean.y, mean.z, cameraPos.y, currentLocation.horizontalAccuracy))
        }

        // Lock the ring as a physical-world anchor after enough good samples.
        if ringSampleCount >= samplesNeeded {
            ringWorldLocked = true
            onDebugTick(String(format:
                "[Ring] LOCKED after %d samples @ (%.1f, %.1f, %.1f)",
                ringSampleCount, mean.x, mean.y, mean.z))
        }
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
