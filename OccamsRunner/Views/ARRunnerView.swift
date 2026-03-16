import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import AVFoundation

// MARK: - Coin Sound Player

/// Generates a pleasant two-note chime entirely in software — no audio file needed.
/// Two sine tones (E5 → G#5, a major third) with a fast attack and smooth exponential
/// decay so it sounds warm rather than harsh. Safe to call from any thread.
final class CoinSoundPlayer {
    static let shared = CoinSoundPlayer()

    private let engine = AVAudioEngine()
    private let mixer: AVAudioMixerNode

    private init() {
        mixer = engine.mainMixerNode
        mixer.outputVolume = 1.0
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            // Non-fatal — game continues without sound
        }
    }

    func playCollect() {
        // Two-note chime: E5 (659 Hz) → G#5 (830 Hz), major third interval
        scheduleNote(frequency: 659.26, startOffset: 0.0,   duration: 0.18)
        scheduleNote(frequency: 830.61, startOffset: 0.06,  duration: 0.22)
    }

    private func scheduleNote(frequency: Float, startOffset: TimeInterval, duration: TimeInterval) {
        let sampleRate: Double = 44100
        let totalFrames = AVAudioFrameCount(sampleRate * (duration + 0.1))

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!,
            frameCapacity: totalFrames
        ) else { return }

        buffer.frameLength = totalFrames

        let channelData = buffer.floatChannelData![0]
        let attackFrames = Int(sampleRate * 0.008)   // 8 ms attack
        let sustainEnd   = Int(sampleRate * duration)
        let totalInt     = Int(totalFrames)

        for i in 0..<totalInt {
            let t = Float(i) / Float(sampleRate)
            let sine = sin(2 * Float.pi * frequency * t)

            // Envelope: linear attack → exponential decay
            let envelope: Float
            if i < attackFrames {
                envelope = Float(i) / Float(attackFrames)
            } else {
                let decayT = Float(i - attackFrames) / Float(max(1, sustainEnd - attackFrames))
                envelope = exp(-4.5 * decayT)   // exponential decay → sounds natural
            }

            channelData[i] = sine * envelope * 0.35   // 0.35 keeps it gentle, not piercing
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: buffer.format)

        if !engine.isRunning {
            try? engine.start()
        }

        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + secondsToHostTime(startOffset)
        )
        player.scheduleBuffer(buffer, at: startTime, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.engine.detach(player)
        }
        player.play()
    }

    private func secondsToHostTime(_ seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = UInt64(seconds * 1_000_000_000)
        return nanos * UInt64(info.denom) / UInt64(info.numer)
    }
}

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
    @State private var showingCompletionAlert = false
    @State private var nearestItemDistance: Double?
    @State private var runMode: ARRunMode = .aligning
    @State private var debugTickLog: String = ""

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
                if route.encryptedWorldMapData == nil {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("AR Precision Data Missing")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("This route was not recorded with AR precision data and cannot be replayed in AR.\nRe-record the route to enable precise AR placement.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 32)
                        Button("Dismiss") { dismiss() }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                } else {
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
                        },
                        onDebugTick: { log in
                            debugTickLog = log
                        }
                    )
                    .ignoresSafeArea()
                }
            } else {
                Color.black.ignoresSafeArea()
                Text("Route not found for this quest.")
                    .foregroundColor(.white)
            }

            if route?.encryptedWorldMapData != nil {
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
                        debugOverlay
                        bottomBar
                    }
                }
            }
        }
        .onAppear {
            locationService.startUpdating()
            let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
            collectedCount = currentQuest.collectedItems
        }
        .alert("Quest Complete!", isPresented: $showingCompletionAlert) {
            Button("Finish") { dismiss() }
        } message: {
            Text("You collected all \(quest.totalItems) coins!")
        }
    }

    // MARK: - Alignment HUD

    private var alignmentTopBanner: some View {
        HStack(alignment: .top) {
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
            .frame(maxWidth: .infinity)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
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
                Group {
                    switch alignmentState {
                    case .moveToStart:
                        Text("Walk to within 40 ft of where you started recording.")
                    case .scanning:
                        Text("Move your phone around slowly to scan the environment.")
                    case .lowConfidence:
                        Text("Low confidence — try scanning from a different angle or retrace a few steps.")
                    case .locked:
                        EmptyView()
                    }
                }
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
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.circle.fill")
                    .foregroundColor(.yellow)
                Text("\(collectedCount)/\(quest.totalItems)")
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer()

            Text(String(format: "Align %.0f%%", alignmentConfidence * 100))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(alignmentConfidence >= 0.75 ? .green : .orange)
                .lineLimit(1)
                .fixedSize()

            Button(action: { runMode = .aligning }) {
                Label("Realign", systemImage: "location.north.line")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    // MARK: - Debug

    private var debugOverlay: some View {
        Group {
            if !debugTickLog.isEmpty {
                Text(debugTickLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Collection

    private func handleCollection(itemId: UUID) {
        dataStore.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)
        collectedCount += 1

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
    let onDebugTick: (String) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []

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

        // Fix 3: Refresh callbacks on every render pass so the coordinator always
        // holds closures that close over the current @State / @EnvironmentObject
        // values. makeCoordinator() is called only once, so without this the
        // callbacks capture a frozen struct that goes stale after the first
        // SwiftUI re-render (e.g. after the first coin collection).
        context.coordinator.onItemCollected       = onItemCollected
        context.coordinator.onAlignmentUpdate     = onAlignmentUpdate
        context.coordinator.onNearestItemDistance = onNearestItemDistance
        context.coordinator.onDebugTick          = onDebugTick

        // Always pull the live quest from dataStore rather than using the
        // struct-captured snapshot — the snapshot goes stale the moment any
        // item is marked collected, which would cause buildCoinNodes to
        // re-create already-collected coin nodes and break subsequent collections.
        let liveQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
        context.coordinator.updateQuest(liveQuest, dataStore: dataStore)
    }

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(
            route: route,
            quest: quest,
            dataStore: dataStore,
            locationService: locationService,
            onAlignmentUpdate: onAlignmentUpdate,
            onNearestItemDistance: onNearestItemDistance,
            onItemCollected: onItemCollected,
            onDebugTick: onDebugTick
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
        runMode = newMode

        let showPath = newMode == .aligning
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

    private func buildCoinNodes(forceRebuild: Bool) {
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
                // ID stays in pendingCollectionIds forever. If the collection
                // callback ever fires but the dataStore write is delayed, the
                // item will be re-blockable on the next cycle rather than
                // permanently invisible to checkCollections.
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
            // in-flight item — it re-appears in coinNodes and confuses the next
            // checkCollections tick even though the item has already been "taken".
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
        performCollectionTick(
            cameraPosition: cameraNode.worldPosition,
            cameraForward: cameraNode.simdWorldFront
        )
    }

    /// Core collection logic extracted from checkCollections so it can be
    /// tested without an ARSCNView. Accepts the camera pose directly.
    func performCollectionTick(
        cameraPosition: SCNVector3,
        cameraForward: SIMD3<Float>
    ) {
        let currentQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest

        // ─────────────────────────────────────────────────────────────────────
        // Phase 1 — geometry check only.
        //
        // IMPORTANT: Do NOT mutate coinNodes or call onItemCollected inside this
        // loop. Doing so triggers dataStore @Published → SwiftUI updateUIView →
        // buildCoinNodes — which mutates coinNodes while the for-loop is still
        // iterating. That is Swift dictionary undefined behaviour and silently
        // breaks all collections after the first one.
        // ─────────────────────────────────────────────────────────────────────
        var toCollect: [(id: UUID, node: SCNNode)] = []
        var logParts: [String] = []

        for item in currentQuest.items {
            if item.collected {
                // Fix 5: Self-heal pendingCollectionIds and stale nodes
                // directly in checkCollections. Previously this cleanup only
                // ran in buildCoinNodes (Fix 1), which depends on
                // updateUIView firing. Doing it here on every 250ms tick
                // ensures confirmed-collected items are cleared regardless
                // of SwiftUI's render cycle.
                pendingCollectionIds.remove(item.id)
                if let staleNode = coinNodes.removeValue(forKey: item.id) {
                    staleNode.removeFromParentNode()
                }
                logParts.append("\(item.id.uuidString.prefix(4)):skip(done)")
                continue
            }
            if pendingCollectionIds.contains(item.id) {
                logParts.append("\(item.id.uuidString.prefix(4)):skip(pending)")
                continue
            }
            guard let node = coinNodes[item.id] else {
                logParts.append("\(item.id.uuidString.prefix(4)):skip(noNode)")
                continue
            }

            let coinPos = node.worldPosition
            let dx = cameraPosition.x - coinPos.x
            let dy = cameraPosition.y - coinPos.y
            let dz = cameraPosition.z - coinPos.z

            let inRange: Bool
            switch route.recordingMode {
            case .tight:
                // 1.2 m ≈ 4 ft — generous enough to absorb ARKit drift
                // that accumulates over longer walks. The original 0.457 m
                // (1.5 ft) was too tight; coins 0.6 m+ away in AR space
                // despite the user physically standing on them.
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                inRange = dist < 1.2
                logParts.append("\(item.id.uuidString.prefix(4)):dist=\(String(format: "%.2f", dist))m \(inRange ? "✓" : "far")")

            case .vast:
                let delta   = SIMD3<Float>(dx, dy, dz)
                let fwdDist = simd_dot(delta, cameraForward)
                let latVec  = delta - cameraForward * fwdDist
                let latDist = simd_length(latVec)
                // Increased from 0.5/1.5 to absorb outdoor AR drift.
                let fwdHalf: Float = 1.5
                let latHalf: Float = 3.0
                let e = (fwdDist / fwdHalf) * (fwdDist / fwdHalf)
                      + (latDist / latHalf) * (latDist / latHalf)
                inRange = e < 1.0
                logParts.append("\(item.id.uuidString.prefix(4)):fwd=\(String(format: "%.2f", fwdDist))m lat=\(String(format: "%.2f", latDist))m e=\(String(format: "%.2f", e)) \(inRange ? "✓" : "far")")
            }

            if inRange {
                toCollect.append((item.id, node))
            }
        }

        // Log every tick so collection behaviour is visible in the debug log.
        let collectTag = toCollect.isEmpty ? "" : "COLLECT×\(toCollect.count) | "
        let tickLog = "\(collectTag)\(logParts.joined(separator: " | "))"
        locationService.logRunEvent("[Tick] \(tickLog)")
        onDebugTick(tickLog)

        // ─────────────────────────────────────────────────────────────────────
        // Phase 2 — act on collected items AFTER the loop is fully done.
        // It is now safe to mutate coinNodes and fire onItemCollected because
        // the for-loop over currentQuest.items has already finished.
        // ─────────────────────────────────────────────────────────────────────
        for (itemId, node) in toCollect {
            pendingCollectionIds.insert(itemId)
            coinNodes.removeValue(forKey: itemId)

            // Audio and animation require a live AR session; skip in tests.
            if arView != nil {
                CoinSoundPlayer.shared.playCollect()

                let scaleUp = SCNAction.scale(to: 2.0, duration: 0.2)
                let fadeOut = SCNAction.fadeOut(duration: 0.3)
                let group   = SCNAction.group([scaleUp, fadeOut])
                let remove  = SCNAction.removeFromParentNode()
                node.runAction(SCNAction.sequence([group, remove]))
            } else {
                node.removeFromParentNode()
            }

            // Fix 4: Update dataStore directly from the coordinator.
            dataStore.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)

            // Still fire the callback for UI-layer updates.
            onItemCollected(itemId)
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
    /// Extracted as a pure static function so collection-state logic can be unit-tested
    /// without any ARKit or SceneKit dependencies.
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
    /// A node must not be created when the item is in-flight (pending) — doing so
    /// produces a ghost node that appears collected on the next tick but is then
    /// permanently skipped because `pendingCollectionIds` still contains the ID.
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
