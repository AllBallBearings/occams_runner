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
    /// Reports whether item placement is currently using the GPS-primary
    /// path (true) or the localTrack/ARKit-primary path (false). Drives the
    /// "GPS" / "AR" badge in the alignment HUD.
    var onPlacementModeChanged: (Bool) -> Void = { _ in }

    /// Shared state object written by SwiftUI gesture handlers and read each
    /// AR frame to apply manual position / rotation corrections to the route.
    var manualAlignment: ManualAlignmentState?

    private let routeGroupNode = SCNNode()
    private var pathNodes: [SCNNode] = []
    private(set) var coinNodes: [UUID: SCNNode] = [:]
    private(set) var pendingCollectionIds: Set<UUID> = []
    private(set) var boxNodes: [UUID: SCNNode] = [:]
    private var pendingBoxIds: Set<UUID> = []

    /// ARAnchors we created, keyed by item/box id. Presence in this dict IS
    /// the "committed" placement state — an item is `.committed` iff its
    /// anchor exists here, otherwise it's `.pending`. See
    /// `docs/AR_ALIGNMENT_REFACTOR.md` for the full lifecycle.
    private var itemAnchors: [UUID: QuestItemAnchor] = [:]
    private var boxAnchors:  [UUID: QuestBoxAnchor]  = [:]

    /// Distance (m) from the camera at which a pending item commits to a
    /// permanent ARAnchor. Tuned so coins materialize a comfortable few
    /// strides ahead of the runner without revealing the entire route.
    private let commitHorizonMeters: Float = 12.0

    /// Throttle: don't run the horizon evaluator on every AR frame. 10 Hz is
    /// plenty for spawning coins as a runner approaches at human speeds.
    private var lastCommitHorizonCheckAt: TimeInterval = 0
    private let commitHorizonCheckInterval: TimeInterval = 0.1

    /// GPS+heading-derived base pose for `routeGroupNode`. Manual alignment
    /// gestures add their offsets on top. `nil` when any input was missing
    /// (no GPS, no heading, route lacks recorded heading) — in that case the
    /// route node sits at the AR origin and the user must align manually.
    private struct RouteSeed { var offsetXZ: SIMD2<Float>; var yaw: Float }
    private var routeSeed: RouteSeed?

    /// Slice 4: how often to refresh `routeSeed` from GPS+heading during a run.
    /// CoreLocation typically delivers ~1 Hz; refreshing more often is wasted
    /// work. Each refresh is lowpassed by `seedRefreshSmoothing` so transient
    /// GPS jitter doesn't snap pending-item commit positions.
    private var lastSeedRefreshAt: TimeInterval = 0
    private let seedRefreshInterval: TimeInterval = 1.0
    /// 0.0 = ignore new fixes, 1.0 = snap to each new fix. The first seed
    /// (when `routeSeed == nil`) always snaps regardless of this value.
    private let seedRefreshSmoothing: Float = 0.25

    // MARK: GPS-Primary Placement
    //
    // When ARKit's visual tracking is unreliable (low light, texture-poor
    // environments, big lighting differences vs. recording time), `localTrack`
    // can no longer be trusted to drive item placement. Instead we compute
    // each pending item's world position directly from `geoTrack` projected
    // through the runner's current GPS+heading. Already-committed items live
    // on their own ARAnchors and aren't affected by mode switches.

    /// Wall-clock time at which ARKit first reported `.limited(.insufficientFeatures)`
    /// in the current degradation episode. Cleared when tracking returns to
    /// `.normal` for at least one frame.
    private var arTrackingDegradedSince: TimeInterval?
    /// Once `arTrackingDegradedSince` has persisted this long, flip
    /// `runtimeGPSPrimary` on. Avoids flapping on transient one-frame blips.
    private let trackingDegradedDelay: TimeInterval = 5.0
    /// Runtime override: forces GPS-primary placement until tracking recovers.
    /// Independent of `route.useGPSPrimary` — that is the recording-time hint;
    /// this is the runtime hint. Either being true means we use GPS placement.
    private var runtimeGPSPrimary: Bool = false {
        didSet {
            guard oldValue != runtimeGPSPrimary else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onPlacementModeChanged(self.effectiveGPSPrimary)
            }
        }
    }
    /// Combined recording-time hint + runtime override.
    private var effectiveGPSPrimary: Bool {
        (route.useGPSPrimary == true) || runtimeGPSPrimary
    }

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
    private var alignmentLocked = false {
        didSet {
            guard oldValue != alignmentLocked else { return }
            DispatchQueue.main.async { self.updateRouteNodeVisibility() }
        }
    }
    private var consecutiveGoodFrames = 0
    private var scanStartedAt: Date?
    /// How many consecutive GPS readings have placed the user beyond the start gate.
    /// We require several before resetting an established lock so GPS jitter can't
    /// knock out a good alignment on a single bad reading.
    private var consecutiveOutOfRangeGPS = 0

    private var statusTimer: Timer?
    private var collectionTimer: Timer?

    /// How close (m) the runner must be to the recorded start before scanning
    /// runs at all. Was 40 m initially but felt much too lenient — at 30+ m
    /// the path overlay would appear and the alignment would lock without the
    /// runner ever being in position. ~15 m (≈50 ft) is tight enough to imply
    /// "you're standing at the start" but wide enough to absorb GPS jitter.
    private let startGateDistanceMeters: Double = 15

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
        // (checkCollections, updateNearestItemDistance, cleanupCollectedItems,
        // updateQuest, evaluateCommitHorizon) is single-threaded on main —
        // no dictionary races possible.
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

        // Shift the route's logical reference frame down ~1 ft so coins
        // committed via that frame land at chest/waist height rather than
        // eye/head height. (Path-ribbon nodes are still parented here for
        // the alignment-guide preview; coin/box nodes are NOT parented here
        // — they each get their own ARAnchor when committed.)
        routeGroupNode.position.y = baseRouteY

        buildRoutePath()
        // No pre-spawning: coins and boxes commit just-in-time as the
        // runner crosses each item's commit horizon during .running mode.
        clearAllItemNodes()
        setupArrowIndicator()
        updateAlignmentStatusFromGPS()
        seedAlignmentFromGPSHeading()
        // Fire the initial placement-mode notification so the HUD badge
        // reflects routes that recorded with `useGPSPrimary = true` from
        // the moment the AR view appears.
        let initial = effectiveGPSPrimary
        DispatchQueue.main.async { [weak self] in
            self?.onPlacementModeChanged(initial)
        }
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
            // Slice 4: don't freeze `routeGroupNode`. Committed coins are
            // independent of it (they live on their own ARAnchors), so we
            // can keep refining the seed during the run. The seed only
            // affects pending items via `evaluateCommitHorizon`.
            lastSeedRefreshAt = 0
            // Keep session delegate active for hand pose detection during running.
            arView?.session.delegate = self

        case .aligning, .realigning:
            // Restore frame callbacks for tracking updates.
            arView?.session.delegate = self
            alignmentLocked = false
            consecutiveGoodFrames = 0
            consecutiveOutOfRangeGPS = 0
            scanStartedAt = nil
            alignmentState = .scanning
            // Re-seed on each (re)alignment so the base pose tracks current GPS.
            routeSeed = nil
            seedAlignmentFromGPSHeading()
        }

        updateRouteNodeVisibility()
    }

    private func updateRouteNodeVisibility() {
        assert(Thread.isMainThread)
        // Path overlay (start/end markers + ribbon) is purely an alignment
        // guide — only show it once alignment is actually locked, otherwise
        // a half-aligned route gets drawn while the user is still walking
        // toward the start gate.
        let showPath = alignmentLocked && (runMode == .aligning || runMode == .realigning)
        for node in pathNodes {
            node.isHidden = !showPath
        }
        // Items can be visible regardless of lock state — they're committed
        // by the horizon evaluator during running and live on their own
        // anchors. Hiding them here is just a belt-and-suspenders default.
        let nearStart = alignmentState != .moveToStart
        for node in coinNodes.values {
            node.isHidden = !nearStart
        }
        for node in boxNodes.values {
            node.isHidden = !nearStart
        }
    }

    func updateQuest(_ quest: Quest, dataStore: DataStore) {
        // updateUIView is called on the main thread; keep coinNodes mutations there.
        assert(Thread.isMainThread)
        self.quest = quest
        // Only reconcile state — never spawn from this path. Spawning is the
        // commit-horizon evaluator's job during .running mode.
        cleanupCollectedItems()
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

    /// Tears down every coin/box node and anchor and clears placement state.
    /// Used on initial scene setup and on full rebuilds (e.g. force-rebuild
    /// from tests). After this call every uncollected item is treated as
    /// `.pending` again and will re-commit when the runner crosses its
    /// commit horizon.
    func clearAllItemNodes() {
        assert(Thread.isMainThread)

        if let session = arView?.session {
            for anchor in itemAnchors.values { session.remove(anchor: anchor) }
            for anchor in boxAnchors.values  { session.remove(anchor: anchor) }
        }
        itemAnchors.removeAll()
        boxAnchors.removeAll()

        for node in coinNodes.values { node.removeFromParentNode() }
        coinNodes.removeAll()
        pendingCollectionIds.removeAll()

        for node in boxNodes.values { node.removeFromParentNode() }
        boxNodes.removeAll()
        pendingBoxIds.removeAll()
    }

    /// Reconciles existing node/anchor state against the live quest in dataStore:
    /// removes nodes for items that have become `collected`, and clears stale
    /// `pendingCollectionIds`. Does NOT spawn anything — committing happens via
    /// `evaluateCommitHorizon()` during `.running` mode. Safe to call on every
    /// SwiftUI render pass.
    func cleanupCollectedItems() {
        assert(Thread.isMainThread)
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        for item in currentQuest.items where item.collected {
            // Fix 1: unblock the pending slot now that the dataStore has
            // confirmed this item is collected.
            pendingCollectionIds.remove(item.id)

            if let existing = coinNodes.removeValue(forKey: item.id) {
                existing.removeFromParentNode()
            }
            if let anchor = itemAnchors.removeValue(forKey: item.id) {
                arView?.session.remove(anchor: anchor)
            }
        }
    }

    #if DEBUG
    /// Test-only synchronous spawn path. ARKit cannot run in unit tests, so
    /// there is no `ARSession` to add anchors to. This helper bypasses the
    /// commit-horizon evaluator and the anchor mechanism entirely: it directly
    /// creates SCNNodes for every uncollected item and parents them to
    /// `routeGroupNode` (the legacy parent). Production code never calls
    /// this — `evaluateCommitHorizon()` is the production spawn path.
    func legacyForceSpawnPendingItems() {
        assert(Thread.isMainThread)
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        for item in currentQuest.items {
            guard !item.collected,
                  coinNodes[item.id] == nil,
                  !pendingCollectionIds.contains(item.id),
                  let local = item.resolvedLocalPosition(on: route) else { continue }
            let coinNode = createCoinNode()
            coinNode.simdPosition = local
            coinNode.isHidden = alignmentState == .moveToStart
            routeGroupNode.addChildNode(coinNode)
            coinNodes[item.id] = coinNode
        }

        for box in currentQuest.boxes {
            guard boxNodes[box.id] == nil,
                  !pendingBoxIds.contains(box.id),
                  let local = box.resolvedLocalPosition(on: route) else { continue }
            let node = createBoxNode()
            node.simdPosition = local
            node.isHidden = alignmentState == .moveToStart
            routeGroupNode.addChildNode(node)
            boxNodes[box.id] = node
        }
    }
    #endif

    // MARK: - Commit Horizon (Just-In-Time Anchored Placement)

    /// For every still-`pending` item whose best-guess world position is within
    /// `commitHorizonMeters` of the camera, create a permanent `QuestItemAnchor`
    /// at that position. Box equivalents get `QuestBoxAnchor`. The actual scene
    /// node is attached in `renderer(_:didAdd:for:)` once ARKit creates the
    /// anchor's node.
    ///
    /// Called from the AR frame callback during `.running` mode, throttled to
    /// `commitHorizonCheckInterval` so we don't recompute every coin's distance
    /// 60×/second.
    private func evaluateCommitHorizon(cameraWorldPos: SIMD3<Float>, frame: ARFrame) {
        guard let arView else { return }
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
        let groupTransform = routeGroupNode.simdWorldTransform
        let useGPSPlacement = effectiveGPSPrimary
        // Snapshot the GPS-projection inputs once per call so we don't
        // recompute camera yaw / heading direction vectors per item.
        let gpsCtx: GPSPlacementContext? = useGPSPlacement ? makeGPSPlacementContext(frame: frame) : nil

        for item in currentQuest.items {
            guard !item.collected,
                  itemAnchors[item.id] == nil,
                  !pendingCollectionIds.contains(item.id) else { continue }

            let world: SIMD3<Float>?
            if let gpsCtx {
                world = gpsPrimaryWorldPosition(forProgress: item.routeProgress,
                                                verticalOffset: Float(item.verticalOffset),
                                                ctx: gpsCtx)
            } else if let local = item.resolvedLocalPosition(on: route) {
                world = (groupTransform * SIMD4<Float>(local, 1)).translationXYZ
            } else {
                world = nil
            }
            guard let w = world else { continue }
            if simd_distance(w, cameraWorldPos) <= commitHorizonMeters {
                let anchor = QuestItemAnchor(itemId: item.id, transform: .translation(w))
                arView.session.add(anchor: anchor)
                itemAnchors[item.id] = anchor
            }
        }

        for box in currentQuest.boxes {
            guard boxAnchors[box.id] == nil,
                  !pendingBoxIds.contains(box.id) else { continue }

            let world: SIMD3<Float>?
            if let gpsCtx {
                world = gpsPrimaryWorldPosition(forProgress: box.routeProgress,
                                                verticalOffset: Float(box.verticalOffsetMeters),
                                                lateralOffset: Float(box.lateralOffsetMeters),
                                                ctx: gpsCtx)
            } else if let local = box.resolvedLocalPosition(on: route) {
                world = (groupTransform * SIMD4<Float>(local, 1)).translationXYZ
            } else {
                world = nil
            }
            guard let w = world else { continue }
            if simd_distance(w, cameraWorldPos) <= commitHorizonMeters {
                let anchor = QuestBoxAnchor(boxId: box.id, transform: .translation(w))
                arView.session.add(anchor: anchor)
                boxAnchors[box.id] = anchor
            }
        }
    }

    // MARK: - GPS-Primary Placement Helpers

    /// Per-frame inputs needed to project a recorded GPS sample into runtime
    /// AR-world XZ. Computed once per `evaluateCommitHorizon` call.
    private struct GPSPlacementContext {
        let camPosXZ: SIMD2<Float>
        let cameraY: Float
        let curLatRad: Double
        let curLat: Double
        let curLon: Double
        let northDir: SIMD2<Float>
        let eastDir: SIMD2<Float>
    }

    private func makeGPSPlacementContext(frame: ARFrame) -> GPSPlacementContext? {
        guard let currentLoc = locationService.currentLocation,
              let currentHeading = locationService.currentHeadingDegrees else { return nil }
        let cam = frame.camera.transform
        let fwd = simd_normalize(SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z))
        guard fwd.x.isFinite, fwd.z.isFinite else { return nil }
        let camYawAR = atan2(-fwd.x, -fwd.z)
        let curHeadingRad = Float(currentHeading) * .pi / 180

        let yawN = camYawAR + curHeadingRad
        let yawE = camYawAR + curHeadingRad - .pi / 2
        let northDir = SIMD2<Float>(-sin(yawN), -cos(yawN))
        let eastDir  = SIMD2<Float>(-sin(yawE), -cos(yawE))

        return GPSPlacementContext(
            camPosXZ: SIMD2<Float>(cam.columns.3.x, cam.columns.3.z),
            cameraY: cam.columns.3.y,
            curLatRad: currentLoc.coordinate.latitude * .pi / 180,
            curLat: currentLoc.coordinate.latitude,
            curLon: currentLoc.coordinate.longitude,
            northDir: northDir,
            eastDir: eastDir
        )
    }

    /// Computes a pending item's world position directly from the recorded
    /// `geoTrack` (GPS) interpolated by progress, projected into the runtime
    /// AR-world frame via the camera's current heading. Vertical (Y) is
    /// `localTrack[i].y` when available — falling back to a chest-height
    /// offset below the camera otherwise — because GPS altitude is unreliable
    /// for placement.
    private func gpsPrimaryWorldPosition(
        forProgress progress: Double,
        verticalOffset: Float,
        ctx: GPSPlacementContext
    ) -> SIMD3<Float>? {
        guard let geo = route.geoSample(atProgress: progress) else { return nil }
        let earthRadius = 6_378_137.0
        let dLat = (geo.coordinate.latitude  - ctx.curLat) * .pi / 180
        let dLon = (geo.coordinate.longitude - ctx.curLon) * .pi / 180
        let east  = Float(dLon * cos(ctx.curLatRad) * earthRadius)
        let north = Float(dLat * earthRadius)
        let xz = ctx.camPosXZ + east * ctx.eastDir + north * ctx.northDir

        let y: Float
        if let local = route.localSample(atProgress: progress) {
            y = Float(local.y) + baseRouteY + verticalOffset
        } else {
            y = ctx.cameraY + baseRouteY + verticalOffset
        }
        return SIMD3<Float>(xz.x, y, xz.y)
    }

    /// Watches `frame.camera.trackingState` and flips `runtimeGPSPrimary`
    /// once tracking has been continuously `.limited(.insufficientFeatures)`
    /// for more than `trackingDegradedDelay`. Resets immediately on any
    /// `.normal` frame so a momentary recovery clears the override.
    private func updateTrackingDegradationState(frame: ARFrame, now: TimeInterval) {
        switch frame.camera.trackingState {
        case .normal:
            arTrackingDegradedSince = nil
            if runtimeGPSPrimary { runtimeGPSPrimary = false }
        case .limited(let reason):
            // Only `.insufficientFeatures` indicates a real visual problem
            // we can't recover from on our own. `.relocalizing`,
            // `.initializing`, `.excessiveMotion` are transient and don't
            // imply localTrack is bad — they imply ARKit just hasn't
            // converged yet.
            if reason == .insufficientFeatures {
                if let since = arTrackingDegradedSince {
                    if (now - since) >= trackingDegradedDelay && !runtimeGPSPrimary {
                        runtimeGPSPrimary = true
                    }
                } else {
                    arTrackingDegradedSince = now
                }
            }
        case .notAvailable:
            // Tracking is fully gone. Treat as degraded.
            if arTrackingDegradedSince == nil { arTrackingDegradedSince = now }
            if !runtimeGPSPrimary { runtimeGPSPrimary = true }
        }
    }

    /// Box variant: applies `lateralOffsetMeters` along the route's
    /// right-perpendicular axis in AR-world XZ before returning.
    private func gpsPrimaryWorldPosition(
        forProgress progress: Double,
        verticalOffset: Float,
        lateralOffset: Float,
        ctx: GPSPlacementContext
    ) -> SIMD3<Float>? {
        guard var pos = gpsPrimaryWorldPosition(forProgress: progress,
                                                verticalOffset: verticalOffset,
                                                ctx: ctx) else { return nil }
        // Route forward in AR-world XZ at this progress: tangent of geoTrack.
        // Approximate via small ±epsilon in progress and project to XZ via
        // the same ENU math used for the base position. Right vector is
        // forward rotated -90° in XZ (right-handed: y up, looking down).
        let epsilon = 0.02
        guard let prev = route.geoSample(atProgress: max(0, progress - epsilon)),
              let next = route.geoSample(atProgress: min(1, progress + epsilon)) else {
            return pos
        }
        let earthRadius = 6_378_137.0
        let dLat = (next.coordinate.latitude  - prev.coordinate.latitude)  * .pi / 180
        let dLon = (next.coordinate.longitude - prev.coordinate.longitude) * .pi / 180
        let dE = Float(dLon * cos(ctx.curLatRad) * earthRadius)
        let dN = Float(dLat * earthRadius)
        let tangentXZ = dE * ctx.eastDir + dN * ctx.northDir
        let len = simd_length(tangentXZ)
        guard len > 0.0001 else { return pos }
        let fwd = tangentXZ / len
        let right = SIMD2<Float>(fwd.y, -fwd.x)  // 90° CW in XZ-as-2D
        let lateral = right * lateralOffset
        pos.x += lateral.x
        pos.z += lateral.y
        return pos
    }

    // MARK: - ARSCNViewDelegate

    /// Called by ARKit immediately after it adds a scene node for one of our
    /// custom anchors. We attach the coin or box geometry as a child of that
    /// node. From this moment forward the node's world position is maintained
    /// by ARKit's world tracking — we never reposition it.
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let q = anchor as? QuestItemAnchor {
                let coinNode = self.createCoinNode()
                node.addChildNode(coinNode)
                self.coinNodes[q.itemId] = coinNode
            } else if let b = anchor as? QuestBoxAnchor {
                let boxNode = self.createBoxNode()
                node.addChildNode(boxNode)
                self.boxNodes[b.boxId] = boxNode
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
        // Camera looks along its -Z axis in world space.
        let forward = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
        return t.translationXYZ + simd_normalize(forward) * 0.6  // ~arm's length
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

    // MARK: - GPS + Heading Seed

    /// Which recorded sample to anchor the seed at.
    /// - `.start` (initial alignment): anchor at `localTrack.first` ↔ `route.startLocation`.
    /// - `.nearestToCurrentGPS` (mid-quest realignment): anchor at the recorded
    ///   sample whose GPS is closest to the runner's current location, so the
    ///   route re-aligns around where the runner stands rather than dragging
    ///   them back to the start gate.
    private enum SeedAnchor {
        case start
        case nearestToCurrentGPS
    }

    /// Returns the SeedAnchor appropriate for the current `runMode`.
    /// - `.aligning`: anchor at the route start, since the runner is at the
    ///   start gate and we want the recorded start to land at GPS-start.
    /// - `.running`: anchor at the recorded sample nearest to the runner's
    ///   current GPS, so as they progress the seed auto-corrects locally
    ///   without ever needing the manual realign button. GPS noise is
    ///   absorbed by `seedRefreshSmoothing` in `refineSeedFromGPSHeading`.
    /// - `.realigning`: same as `.running` (manual recalibration around the
    ///   runner's current position).
    private func currentSeedAnchor() -> SeedAnchor {
        switch runMode {
        case .aligning: return .start
        case .running, .realigning: return .nearestToCurrentGPS
        }
    }

    /// Resolves a SeedAnchor to a concrete `(geoLocation, localPosition)` pair.
    /// Returns `nil` if the route lacks the data needed (empty tracks, no GPS).
    private func resolveAnchor(_ anchor: SeedAnchor) -> (CLLocation, LocalRouteSample)? {
        switch anchor {
        case .start:
            guard let start = route.startLocation,
                  let firstLocal = route.localTrack.first else { return nil }
            return (start, firstLocal)
        case .nearestToCurrentGPS:
            guard let currentLoc = locationService.currentLocation,
                  !route.geoTrack.isEmpty,
                  !route.localTrack.isEmpty else { return nil }
            // Find the geoTrack sample closest to current GPS, then match it
            // to its localTrack counterpart by sampleId. Geo and local tracks
            // are correlated by sampleId in `buildRecordedRoute`.
            var bestGeo: GeoRouteSample?
            var bestDist = Double.greatestFiniteMagnitude
            for geo in route.geoTrack {
                let d = currentLoc.distance(from: geo.location)
                if d < bestDist { bestDist = d; bestGeo = geo }
            }
            guard let geo = bestGeo,
                  let local = route.localTrack.first(where: { $0.sampleId == geo.sampleId })
            else { return nil }
            return (geo.location, local)
        }
    }

    /// Computes a coarsely-correct base pose for `routeGroupNode` from a
    /// recorded sample's GPS vs. the runner's current GPS+heading.
    /// No-op (returns false) when any input is missing.
    ///
    /// Math: ENU(current → anchorLoc) projected into AR-world XZ via the
    /// camera's current yaw, plus a global route-yaw rotation derived from
    /// recorded vs. current compass heading and AR yaw. The rotated anchor
    /// local position is subtracted so the anchor sample lands exactly on
    /// the GPS-derived anchor point.
    ///
    /// Which sample to anchor at depends on `runMode` via `currentSeedAnchor()`:
    /// initial alignment uses the route start, mid-quest realignment uses the
    /// recorded sample nearest to the runner's current GPS.
    @discardableResult
    func seedAlignmentFromGPSHeading(frame: ARFrame? = nil) -> Bool {
        seedAlignmentFromGPSHeading(frame: frame, anchor: currentSeedAnchor())
    }

    @discardableResult
    private func seedAlignmentFromGPSHeading(frame: ARFrame?, anchor: SeedAnchor) -> Bool {
        guard let recordedHeading = route.recordedHeadingDegrees,
              let currentHeading = locationService.currentHeadingDegrees,
              let currentLoc = locationService.currentLocation,
              let (anchorLoc, anchorLocal) = resolveAnchor(anchor) else {
            return false
        }
        guard let cam = (frame ?? arView?.session.currentFrame)?.camera.transform else {
            return false
        }

        let earthRadius = 6_378_137.0
        let curLatRad = currentLoc.coordinate.latitude * .pi / 180
        let dLat = (anchorLoc.coordinate.latitude - currentLoc.coordinate.latitude) * .pi / 180
        let dLon = (anchorLoc.coordinate.longitude - currentLoc.coordinate.longitude) * .pi / 180
        let east  = Float(dLon * cos(curLatRad) * earthRadius)
        let north = Float(dLat * earthRadius)

        // The camera's flattened forward in AR world corresponds to compass
        // `currentHeading`. ARKit yaw is CCW around +Y (viewed from above);
        // compass is CW. forward = (-sin(yaw), 0, -cos(yaw)).
        let fwd = simd_normalize(SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z))
        let camYawAR = atan2(-fwd.x, -fwd.z)
        let curHeadingRad = Float(currentHeading) * .pi / 180

        // Direction in AR-world XZ for compass θ: yaw = camYawAR - (θ - curHeading).
        // Pre-compute the two we need (north and east).
        let yawN = camYawAR + curHeadingRad
        let yawE = camYawAR + curHeadingRad - .pi / 2
        let northDir = SIMD2<Float>(-sin(yawN), -cos(yawN))
        let eastDir  = SIMD2<Float>(-sin(yawE), -cos(yawE))

        let camPos = SIMD2<Float>(cam.columns.3.x, cam.columns.3.z)
        let anchorXZ = camPos + east * eastDir + north * northDir

        // Yaw to rotate route-local frame into runtime AR-world frame.
        //
        // The route's `localTrack` lives in the recording AR session's world
        // frame, which was oriented by device pose at *AR session start* —
        // not at recording start. So we need both the recorded compass
        // heading AND the recording AR-world camera yaw at recording start
        // to recover the relationship to true north.
        //
        // True-north angle in recording AR-world: recYaw + recHeading
        // True-north angle in runtime  AR-world: camYawAR + currentHeading
        // Δyaw = runtime − recording rotates recording frame onto runtime.
        //
        // Routes recorded before `recordedCameraYawAR` was captured fall back
        // to the old (often wrong) approximation `recYaw == 0`.
        let recYaw = Float(route.recordedCameraYawAR ?? 0)
        let recHeadingRad = Float(recordedHeading) * .pi / 180
        let routeYaw = (camYawAR + curHeadingRad) - (recYaw + recHeadingRad)

        let lp = SIMD3<Float>(Float(anchorLocal.x), Float(anchorLocal.y), Float(anchorLocal.z))
        let cy = cos(routeYaw)
        let sy = sin(routeYaw)
        let rotatedLP = SIMD2<Float>(cy * lp.x + sy * lp.z, -sy * lp.x + cy * lp.z)

        let wasSeeded = (routeSeed != nil)
        routeSeed = RouteSeed(offsetXZ: anchorXZ - rotatedLP, yaw: routeYaw)

        if !wasSeeded {
            let recYawStr = route.recordedCameraYawAR.map {
                String(format: "%.1f°", $0 * 180 / .pi)
            } ?? "—"
            let anchorTag: String = {
                switch anchor {
                case .start: return "start"
                case .nearestToCurrentGPS: return "nearestSample"
                }
            }()
            locationService.logRunEvent(
                "AR seed[\(anchorTag)]: ENU=(e=\(String(format: "%.1f", east)) n=\(String(format: "%.1f", north)))" +
                " yaw=\(String(format: "%.1f°", Double(routeYaw * 180 / .pi)))" +
                " (recHdg=\(String(format: "%.1f", recordedHeading))° curHdg=\(String(format: "%.1f", currentHeading))°" +
                " recYawAR=\(recYawStr) camYawAR=\(String(format: "%.1f°", Double(camYawAR * 180 / .pi))))"
            )
        }
        return true
    }

    /// Slice 4: blend a freshly-computed GPS+heading seed into the existing
    /// one with a low-pass filter so transient GPS jitter doesn't snap the
    /// route group's pose every refresh. Called periodically during `.running`
    /// so still-pending items track improving GPS as the player moves into
    /// better-localized regions. No effect on already-committed items —
    /// they live on their own ARAnchors and never read `routeGroupNode`.
    private func refineSeedFromGPSHeading(frame: ARFrame) {
        guard let prior = routeSeed else {
            // No prior seed yet — first successful fix snaps directly.
            seedAlignmentFromGPSHeading(frame: frame)
            return
        }

        // Recompute a fresh seed by clearing and calling the full path,
        // then blend prior ↔ fresh. Restore prior on failure.
        routeSeed = nil
        guard seedAlignmentFromGPSHeading(frame: frame), let fresh = routeSeed else {
            routeSeed = prior
            return
        }

        let a = seedRefreshSmoothing
        routeSeed = RouteSeed(
            offsetXZ: prior.offsetXZ * (1 - a) + fresh.offsetXZ * a,
            yaw: blendYaw(prior.yaw, fresh.yaw, alpha: a)
        )
    }

    /// Linearly blends two yaw angles taking the shortest arc, so 359° and
    /// 1° blend toward 0° rather than sweeping through 180°.
    private func blendYaw(_ from: Float, _ to: Float, alpha: Float) -> Float {
        var diff = to - from
        while diff >  .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        return from + diff * alpha
    }

    // MARK: - Manual Alignment

    /// Applies the user's manual position and rotation corrections to the route group.
    /// Called every AR frame while in aligning/realigning mode so the adjustments
    /// are visible in real-time as the user drags/rotates. Manual offsets are
    /// applied **on top of** the GPS+heading seed (when available), so the user's
    /// gestures fine-tune a coarsely-correct base pose rather than starting from
    /// AR-world origin every time.
    private func applyManualAlignment() {
        guard let manual = manualAlignment else { return }

        // Convert camera-relative offsets to AR world-space coordinates so the
        // route slides in the direction the user actually dragged regardless of
        // which way the camera is facing.
        var posX: Float = manual.worldX
        var posZ: Float = manual.worldZ

        if let cam = arView?.session.currentFrame?.camera.transform {
            let rightFlat   = SIMD3<Float>( cam.columns.0.x, 0,  cam.columns.0.z)
            let forwardFlat = SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z)

            if simd_length(rightFlat) > 0.001 && simd_length(forwardFlat) > 0.001 {
                let r = simd_normalize(rightFlat)   * manual.worldX
                let f = simd_normalize(forwardFlat) * manual.worldZ
                posX = r.x + f.x
                posZ = r.z + f.z
            }
        }

        let seedXZ = routeSeed?.offsetXZ ?? SIMD2<Float>(0, 0)
        let seedYaw = routeSeed?.yaw ?? 0

        routeGroupNode.simdPosition = SIMD3<Float>(
            seedXZ.x + posX,
            baseRouteY + manual.worldY,
            seedXZ.y + posZ
        )
        routeGroupNode.simdOrientation = simd_quatf(
            angle: seedYaw + manual.rotationY,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    // MARK: - Alignment

    private func updateAlignmentStatusFromGPS() {
        guard runMode == .aligning || runMode == .realigning else { return }
        let distance = distanceToRouteStart()

        // Mid-quest realignment intentionally skips the start-gate check.
        // The runner is somewhere along the route already; the seed will
        // anchor at the recorded sample nearest to their current GPS, so
        // there's no reason to drag them back to the start.
        if runMode == .aligning,
           let distance, distance > startGateDistanceMeters {
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

            updateTrackingDegradationState(frame: frame, now: now)

            // Slice 4: keep refining the GPS+heading seed during the run so
            // pending items benefit from continued localization. Already-
            // committed items are anchored to the AR world and never move.
            if now - lastSeedRefreshAt >= seedRefreshInterval {
                lastSeedRefreshAt = now
                refineSeedFromGPSHeading(frame: frame)
                applyManualAlignment()
            }

            // Just-in-time placement: as the camera advances, commit any
            // pending coins/boxes that have entered the commit horizon.
            // Throttled to ~10 Hz — far more often than necessary for a
            // human-speed runner, but cheap (a SIMD distance per item).
            if now - lastCommitHorizonCheckAt >= commitHorizonCheckInterval {
                lastCommitHorizonCheckAt = now
                evaluateCommitHorizon(cameraWorldPos: frame.camera.transform.translationXYZ,
                                      frame: frame)
            }
            return
        }
        guard runMode == .aligning || runMode == .realigning else { return }

        // Continuously refresh the seed during alignment. The first call may
        // run before CLHeading delivers or the camera transform is ready, in
        // which case `routeSeed` stays nil and we retry next frame. Once
        // seeded, refresh on the same throttle as running mode so the route
        // tracks GPS as the user walks toward the start (ARKit world drift
        // over a 100+ ft approach is otherwise visible as the start marker
        // sliding away from the actual recorded location).
        let now = frame.timestamp
        if routeSeed == nil {
            seedAlignmentFromGPSHeading(frame: frame)
            lastSeedRefreshAt = now
        } else if now - lastSeedRefreshAt >= seedRefreshInterval {
            lastSeedRefreshAt = now
            refineSeedFromGPSHeading(frame: frame)
        }

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

        // Self-heal: clean up confirmed-collected items from coinNodes/pendingIds
        // and remove their ARAnchors. This runs before the engine so stale state
        // doesn't accumulate.
        for item in currentQuest.items where item.collected {
            pendingCollectionIds.remove(item.id)
            if let staleNode = coinNodes.removeValue(forKey: item.id) {
                staleNode.removeFromParentNode()
            }
            if let anchor = itemAnchors.removeValue(forKey: item.id) {
                arView?.session.remove(anchor: anchor)
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

            // Remove the ARAnchor too — its job is done. The anchor's parent
            // scene node is removed automatically by ARKit on session.remove.
            if let anchor = itemAnchors.removeValue(forKey: itemId) {
                arView?.session.remove(anchor: anchor)
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

    /// Synchronously spawn nodes for the test path. Production uses the
    /// commit-horizon evaluator + ARAnchor mechanism, neither of which can
    /// run in unit tests. `legacyForceSpawnPendingItems()` parents nodes
    /// directly to `routeGroupNode` so collection-engine tests can exercise
    /// the post-placement pipeline.
    func testBuildCoinNodes(forceRebuild: Bool) {
        if forceRebuild {
            clearAllItemNodes()
        }
        cleanupCollectedItems()
        legacyForceSpawnPendingItems()
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

    /// Returns whether the legacy/test spawn path should create a new node
    /// for `item`. Production uses `evaluateCommitHorizon()` instead.
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

// MARK: - SIMD Helpers

extension SIMD4 where Scalar == Float {
    /// The xyz components, i.e. the homogeneous-coordinate position.
    var translationXYZ: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

extension simd_float4x4 {
    /// The translation column (m41/m42/m43) of an affine transform.
    var translationXYZ: SIMD3<Float> { columns.3.translationXYZ }

    /// Pure-translation transform: identity rotation, position at `t`.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }
}

// MARK: - Per-Item Placement Anchors

/// Custom ARAnchor subclass that carries the QuestItem id it represents.
/// Required so renderer(_:didAdd:for:) can identify which item a freshly
/// created scene node belongs to.
final class QuestItemAnchor: ARAnchor {
    let itemId: UUID

    init(itemId: UUID, transform: simd_float4x4) {
        self.itemId = itemId
        super.init(name: "QuestItemAnchor", transform: transform)
    }

    required init(anchor: ARAnchor) {
        if let q = anchor as? QuestItemAnchor {
            self.itemId = q.itemId
        } else {
            self.itemId = UUID()
        }
        super.init(anchor: anchor)
    }

    required init?(coder: NSCoder) {
        guard let raw = coder.decodeObject(of: NSString.self, forKey: "questItemId") as String?,
              let id  = UUID(uuidString: raw) else { return nil }
        self.itemId = id
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(itemId.uuidString as NSString, forKey: "questItemId")
    }

    override class var supportsSecureCoding: Bool { true }
}

/// Custom ARAnchor subclass for punchable boxes.
final class QuestBoxAnchor: ARAnchor {
    let boxId: UUID

    init(boxId: UUID, transform: simd_float4x4) {
        self.boxId = boxId
        super.init(name: "QuestBoxAnchor", transform: transform)
    }

    required init(anchor: ARAnchor) {
        if let b = anchor as? QuestBoxAnchor {
            self.boxId = b.boxId
        } else {
            self.boxId = UUID()
        }
        super.init(anchor: anchor)
    }

    required init?(coder: NSCoder) {
        guard let raw = coder.decodeObject(of: NSString.self, forKey: "questBoxId") as String?,
              let id  = UUID(uuidString: raw) else { return nil }
        self.boxId = id
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(boxId.uuidString as NSString, forKey: "questBoxId")
    }

    override class var supportsSecureCoding: Bool { true }
}
