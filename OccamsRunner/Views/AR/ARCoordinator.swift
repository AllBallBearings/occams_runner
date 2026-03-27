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

    private let startGateDistanceMeters: Double = 40

    // Base Y offset applied to the route group so objects sit at chest height.
    // The manual alignment adds onto this baseline.
    private let baseRouteY: Float = -0.3

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

        buildRoutePath()
        buildCoinNodes(forceRebuild: true)
        buildBoxNodes(forceRebuild: true)
        setupArrowIndicator()
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
        // Flat arrow using UIBezierPath + SCNShape, extruded slightly for a 3D tile / embossed look.
        // The path is centred at origin with the tip in +Y direction.
        let halfHeadW: CGFloat = 0.040   // half-width of arrowhead
        let halfShaftW: CGFloat = 0.016  // half-width of shaft
        let totalLen: CGFloat  = 0.095   // total arrow length
        let headLen: CGFloat   = 0.038   // arrowhead length

        let tipY  =  totalLen / 2
        let neckY =  tipY - headLen      // where arrowhead meets shaft
        let baseY = -totalLen / 2

        let path = UIBezierPath()
        path.move(to: CGPoint(x:  0,          y: tipY))   // tip
        path.addLine(to: CGPoint(x:  halfHeadW,  y: neckY))   // right shoulder
        path.addLine(to: CGPoint(x:  halfShaftW, y: neckY))   // right neck
        path.addLine(to: CGPoint(x:  halfShaftW, y: baseY))   // right shaft base
        path.addLine(to: CGPoint(x: -halfShaftW, y: baseY))   // left shaft base
        path.addLine(to: CGPoint(x: -halfShaftW, y: neckY))   // left neck
        path.addLine(to: CGPoint(x: -halfHeadW,  y: neckY))   // left shoulder
        path.close()

        let shape = SCNShape(path: path, extrusionDepth: 0.009)
        shape.chamferRadius = 0.003

        let mat = SCNMaterial()
        mat.diffuse.contents  = UIColor(red: 1.0, green: 0.50, blue: 0.0, alpha: 1.0)
        mat.emission.contents = UIColor(red: 1.0, green: 0.30, blue: 0.0, alpha: 0.45)
        mat.metalness.contents = 0.45
        mat.roughness.contents = 0.30
        mat.isDoubleSided = true
        shape.materials = [mat]

        // Rotating -90° around X maps +Y → -Z (camera forward) and extrusion (+Z) → +Y
        // so the slab lies flat in the horizontal XZ plane, tip pointing forward by default.
        let shapeNode = SCNNode(geometry: shape)
        shapeNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        let container = SCNNode()
        container.addChildNode(shapeNode)

        // Subtle scale pulse so the arrow draws the eye
        let pulseAction = SCNAction.sequence([
            SCNAction.scale(to: 1.10, duration: 0.65),
            SCNAction.scale(to: 1.00, duration: 0.65)
        ])
        container.runAction(SCNAction.repeatForever(pulseAction))

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

        // Direction to coin in camera-local space, projected onto the horizontal (XZ) plane only.
        // Y is ignored so the flat arrow never tilts up/down — it only spins around its vertical axis.
        let coinCamLocal = cameraNode.convertPosition(target.worldPosition, from: nil)
        let arrowPos = arrow.position
        let dx = coinCamLocal.x - arrowPos.x
        let dz = coinCamLocal.z - arrowPos.z

        guard dx * dx + dz * dz > 1e-4 else { return }

        // The flat arrow geometry points in –Z (camera forward) when Y rotation is 0.
        // atan2(-dx, -dz) maps: coin ahead → 0, coin right → –π/2, coin left → +π/2.
        let angle = atan2(-dx, -dz)
        arrow.simdEulerAngles = simd_float3(0, angle, 0)
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
        var posX: Float = manual.worldX
        var posZ: Float = manual.worldZ

        if let cam = arView?.session.currentFrame?.camera.transform {
            // Camera's right vector is its X column; forward is -Z column (ARKit looks in -Z).
            let rightFlat   = SIMD3<Float>( cam.columns.0.x, 0,  cam.columns.0.z)
            let forwardFlat = SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z)

            // Guard against degenerate vectors (phone pointing nearly straight up/down).
            if simd_length(rightFlat) > 0.001 && simd_length(forwardFlat) > 0.001 {
                let r = simd_normalize(rightFlat)   * manual.worldX
                let f = simd_normalize(forwardFlat) * manual.worldZ
                posX = r.x + f.x
                posZ = r.z + f.z
            }
        }

        routeGroupNode.simdPosition = SIMD3<Float>(posX, baseRouteY + manual.worldY, posZ)
        routeGroupNode.simdOrientation = simd_quatf(
            angle: manual.rotationY,
            axis: SIMD3<Float>(0, 1, 0)
        )
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
            if consecutiveOutOfRangeGPS >= 3 {
                alignmentState = .moveToStart
                alignmentConfidence = min(alignmentConfidence, 0.2)
                alignmentLocked = false
                consecutiveGoodFrames = 0
                scanStartedAt = nil
            }
            publishAlignment(distance: distance)
            return
        }
        consecutiveOutOfRangeGPS = 0

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
        if runMode == .running {
            let now = frame.timestamp
            if now - lastHandPoseTime >= handPoseInterval {
                lastHandPoseTime = now
                processHandPose(frame: frame)
            }
            return
        }
        guard runMode == .aligning || runMode == .realigning else { return }

        // Apply manual position/rotation corrections every frame so the
        // AR view updates in real-time as the user adjusts.
        applyManualAlignment()

        guard (distanceToRouteStart() ?? 0) <= startGateDistanceMeters else { return }
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
