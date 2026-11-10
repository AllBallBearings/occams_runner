import XCTest
import SceneKit
@testable import OccamsRunner

/// Integration tests that exercise the REAL ARCoordinator collection pipeline:
/// buildCoinNodes → performCollectionTick → dataStore update → state healing.
///
/// These tests use actual DataStore, Quest, RecordedRoute, and SCNNode objects.
/// No ARSCNView or ARKit session needed — we call performCollectionTick directly
/// with mock camera positions.
final class CollectionIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var store: DataStore!
    private var locationService: LocationService!

    /// Collected item IDs reported via the onItemCollected callback.
    private var collectedCallbackIds: [UUID] = []
    /// Debug tick logs captured from the onDebugTick callback.
    private var debugLogs: [String] = []
    /// Times a coordinator played the collection chime.
    private var soundCount = 0

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore(directory: tempDir)
        locationService = LocationService()
        collectedCallbackIds = []
        debugLogs = []
        soundCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a dual-track route with both geo and local tracks along the X axis.
    /// Each sample is 1 meter apart starting at the origin.
    private func makeDualTrackRoute(pointCount: Int, mode: RecordingMode = .tight) -> RecordedRoute {
        let geo = (0..<pointCount).map { i in
            GeoRouteSample(
                sampleId: UUID(),
                latitude: 37.33182,
                longitude: -122.03118 + Double(i) * 0.00001,
                altitude: 50.0,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                horizontalAccuracy: 5.0,
                verticalAccuracy: 3.0,
                progress: Double(i) / Double(max(1, pointCount - 1))
            )
        }
        let local = (0..<pointCount).map { i in
            LocalRouteSample(
                sampleId: UUID(),
                x: Double(i),   // 1 meter apart along X
                y: 0.0,
                z: 0.0,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                progress: Double(i) / Double(max(1, pointCount - 1)),
                trackingScore: 1.0,
                featurePointCount: 100
            )
        }
        return RecordedRoute(
            name: "Test Route",
            geoTrack: geo,
            localTrack: local,
            checkpoints: [],
            encryptedWorldMapData: nil,
            captureQuality: RouteCaptureQuality(
                matchedSampleRatio: 1.0,
                averageFeaturePoints: 100,
                averageTrackingScore: 1.0,
                hasEncryptedWorldMap: false
            ),
            preciseEnabled: true,
            recordingMode: mode
        )
    }

    private func makeQuest(routeId: UUID, coinCount: Int) -> Quest {
        let items = (0..<coinCount).map { i in
            QuestItem(type: .coin, routeProgress: Double(i) / Double(max(1, coinCount - 1)))
        }
        return Quest(name: "Test Quest", routeId: routeId, items: items)
    }

    private func makeCoordinator(route: RecordedRoute, quest: Quest) -> ARCoordinator {
        let coordinator = ARCoordinator(
            route: route,
            quest: quest,
            dataStore: store,
            locationService: locationService,
            onAlignmentUpdate: { _ in },
            onNearestItemDistance: { _ in },
            onItemCollected: { [weak self] itemId in
                self?.collectedCallbackIds.append(itemId)
            },
            onDebugTick: { [weak self] log in
                self?.debugLogs.append(log)
            },
            onStartPlacementDebugUpdate: { _ in }
        )
        coordinator.playCollectSound = { [weak self] in self?.soundCount += 1 }
        return coordinator
    }

    private func cameraAt(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 {
        SCNVector3(x, y, z)
    }

    // Default Touch mode uses simple 3D proximity (1 ft) — no direction needed.

    // MARK: - buildCoinNodes Tests

    func test_newQuest_buildsVisibleStarCoinsByDefault() {
        let route = makeDualTrackRoute(pointCount: 11)
        let items = QuestGenerator.generateItems(along: route)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.type == .coin })
        let quest = Quest(name: "Default Coin Quest", routeId: route.id, items: items)
        store.saveRoute(route)
        store.saveQuest(quest)
        let coordinator = makeCoordinator(route: route, quest: quest)
        coordinator.testBuildCoinNodes(forceRebuild: true)

        XCTAssertEqual(coordinator.coinNodes.count, items.count)
        for node in coordinator.coinNodes.values {
            XCTAssertEqual(node.name, "StarCoin")
            var hasGeometry = false
            node.enumerateChildNodes { child, _ in
                if child.geometry != nil { hasGeometry = true }
            }
            XCTAssertTrue(hasGeometry, "Quest coins must render the asset, not an empty placeholder")
        }
    }

    func test_buildCoinNodes_createsNodesForAllUncollectedItems() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 5)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        XCTAssertEqual(coord.testCoinNodeCount, 5,
                       "buildCoinNodes should create a node for each of the 5 uncollected items")
        for item in quest.items {
            XCTAssertTrue(coord.testCoinNodeIds.contains(item.id),
                          "Each item should have a corresponding coin node")
        }
    }

    func test_buildCoinNodes_skipsCollectedItems() {
        let route = makeDualTrackRoute(pointCount: 11)
        var quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        // Mark item 0 as collected in the dataStore
        store.updateQuestItem(questId: quest.id, itemId: quest.items[0].id, collected: true)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        XCTAssertEqual(coord.testCoinNodeCount, 2,
                       "Should create nodes only for the 2 uncollected items")
        XCTAssertFalse(coord.testCoinNodeIds.contains(quest.items[0].id),
                       "Collected item should NOT have a coin node")
    }

    func test_buildCoinNodes_forceRebuild_replacesAllNodes() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)
        let firstBuildIds = coord.testCoinNodeIds

        // Force rebuild should recreate all nodes
        coord.testBuildCoinNodes(forceRebuild: true)
        XCTAssertEqual(coord.testCoinNodeCount, 3)
        // IDs should be the same (same items), but nodes are new objects
        XCTAssertEqual(coord.testCoinNodeIds, firstBuildIds)
    }

    // MARK: - Single Coin Collection

    func test_collectSingleCoin_updatesDataStore() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Item 0 is at progress 0.0 → localTrack position (0, 0, 0)
        // Place camera right on top of it
        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))

        // Verify dataStore was updated directly by the coordinator
        let liveQuest = store.quests.first(where: { $0.id == quest.id })!
        XCTAssertTrue(liveQuest.items[0].collected,
                      "Item 0 should be marked collected in the dataStore")
        XCTAssertFalse(liveQuest.items[1].collected,
                       "Item 1 should NOT be collected yet")
    }

    func test_collectSingleCoin_firesCallback() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 1)
        XCTAssertEqual(collectedCallbackIds.first, quest.items[0].id)
    }

    func test_collectSingleCoin_movesToPending() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))

        XCTAssertTrue(coord.testPendingIds.contains(quest.items[0].id),
                      "Collected item should be in pendingIds after Phase 2")
        XCTAssertFalse(coord.testCoinNodeIds.contains(quest.items[0].id),
                       "Collected item should have its node removed from coinNodes")
    }

    // MARK: - Sequential Collection (THE regression test)

    /// THE critical integration test: collect coin 0, then on a subsequent tick
    /// collect coin 1. This tests the full round-trip that previously failed.
    func test_sequentialCollection_secondCoinCollectableAfterFirst() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)
        XCTAssertEqual(coord.testCoinNodeCount, 3, "Should start with 3 coin nodes")

        // --- Tick 1: Collect coin 0 (at position 0,0,0) ---
        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 1, "First tick should collect coin 0")
        XCTAssertEqual(coord.testCoinNodeCount, 2, "Should have 2 nodes remaining")

        // Verify coin 0 is collected in dataStore
        let afterFirst = store.quests.first(where: { $0.id == quest.id })!
        XCTAssertTrue(afterFirst.items[0].collected)

        // --- Tick 2: Collect coin 1 (at position 5,0,0 for 3-coin quest on 11-point route) ---
        // Item 1 is at progress 0.5 → local position interpolated at x=5.0
        coord.performCollectionTick(cameraPosition: cameraAt(5, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 2,
                       "Second tick should collect coin 1 — THIS IS THE BUG if it fails")
        XCTAssertEqual(collectedCallbackIds[1], quest.items[1].id)

        let afterSecond = store.quests.first(where: { $0.id == quest.id })!
        XCTAssertTrue(afterSecond.items[1].collected,
                      "Item 1 should be marked collected in the dataStore")

        // --- Tick 3: Collect coin 2 (at position 10,0,0) ---
        coord.performCollectionTick(cameraPosition: cameraAt(10, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 3, "Third tick should collect coin 2")
        let afterThird = store.quests.first(where: { $0.id == quest.id })!
        XCTAssertTrue(afterThird.isComplete, "Quest should be complete after collecting all 3 coins")
    }

    // MARK: - Pending State Healing

    func test_pendingIds_clearedOnNextTick_whenDataStoreConfirms() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 2)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Collect coin 0
        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))
        XCTAssertTrue(coord.testPendingIds.contains(quest.items[0].id))

        // On the NEXT tick (camera moved away), the self-healing in Phase 1
        // should clear coin 0 from pendingIds since dataStore confirms collected
        coord.performCollectionTick(cameraPosition: cameraAt(5, 0, 0))
        XCTAssertFalse(coord.testPendingIds.contains(quest.items[0].id),
                       "Pending ID should be cleared after dataStore confirms collection")
    }

    // MARK: - Ghost Node Prevention

    func test_buildCoinNodes_doesNotCreateGhostForPendingItem() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 2)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Collect coin 0 — it enters pendingIds, node removed
        coord.performCollectionTick(cameraPosition: cameraAt(0, 0, 0))
        XCTAssertEqual(coord.testCoinNodeCount, 1, "Only coin 1's node should remain")

        // Simulate a SwiftUI re-render calling buildCoinNodes BEFORE dataStore
        // confirms collected=true. The pending item should NOT get a ghost node.
        // (In reality the dataStore IS updated by Fix 4, but we're testing the
        // guard in case of any timing edge case.)
        coord.testBuildCoinNodes(forceRebuild: false)

        // Coin 0 is pending AND collected in dataStore → no ghost node
        XCTAssertEqual(coord.testCoinNodeCount, 1,
                       "Must NOT recreate a ghost node for the in-flight item")
        XCTAssertFalse(coord.testCoinNodeIds.contains(quest.items[0].id))
    }

    // MARK: - Out of Range

    func test_outOfRange_doesNotCollect() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 2)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Camera at position (50, 0, 0) — far from both coins
        coord.performCollectionTick(cameraPosition: cameraAt(50, 0, 0))

        XCTAssertTrue(collectedCallbackIds.isEmpty, "Should not collect any coins when out of range")
        XCTAssertEqual(coord.testCoinNodeCount, 2, "Both nodes should still exist")
    }

    // MARK: - Collection Radius (1 ft)

    func test_collectsWithinOneFootRadius() {
        let route = makeDualTrackRoute(pointCount: 11, mode: .vast)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Coin at (0,0,0). Camera at (0.25, 0, 0) — within the 1 ft radius
        coord.performCollectionTick(cameraPosition: cameraAt(0.25, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 1,
                       "Should collect within the 1 ft radius")
    }

    func test_doesNotCollectOutsideOneFootRadius() {
        let route = makeDualTrackRoute(pointCount: 11, mode: .vast)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Coin at (0,0,0). Camera at (0.35, 0, 0) — outside the 1 ft radius
        coord.performCollectionTick(cameraPosition: cameraAt(0.35, 0, 0))

        XCTAssertTrue(collectedCallbackIds.isEmpty,
                      "Should NOT collect outside the 1 ft radius")
    }

    // MARK: - Many Coins Sequential

    func test_tenCoins_allCollectableSequentially() {
        let route = makeDualTrackRoute(pointCount: 101) // 0 to 100 meters
        let quest = makeQuest(routeId: route.id, coinCount: 10)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)
        XCTAssertEqual(coord.testCoinNodeCount, 10)

        // Walk to each coin and collect it
        for i in 0..<10 {
            // Each coin is at progress i/9, which maps to local x = (i/9)*100
            let x = Float(i) / 9.0 * 100.0
            coord.performCollectionTick(cameraPosition: cameraAt(x, 0, 0))
        }

        XCTAssertEqual(collectedCallbackIds.count, 10,
                       "All 10 coins should be collected — got \(collectedCallbackIds.count)")

        let finalQuest = store.quests.first(where: { $0.id == quest.id })!
        XCTAssertTrue(finalQuest.isComplete, "Quest should be complete after all coins collected")
        XCTAssertEqual(coord.testCoinNodeCount, 0, "No coin nodes should remain")
    }

    // MARK: - Debug Log Output

    func test_debugLog_showsCorrectStatusPerItem() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 2)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Far from both coins
        coord.performCollectionTick(cameraPosition: cameraAt(50, 0, 0))

        XCTAssertEqual(debugLogs.count, 1)
        let log = debugLogs[0]
        // Both items should show distance readings (not skip)
        XCTAssertTrue(log.contains("far"), "Debug log should show 'far' for out-of-range coins")
        XCTAssertFalse(log.contains("noNode"), "No items should be missing nodes")
        XCTAssertFalse(log.contains("pending"), "No items should be pending")
    }

    // MARK: - Run Mode

    /// Runs the coordinator along +X at walking pace with the phone `phoneHeight`
    /// above the coins and `lateral` metres to the side of the route.
    private func walkRoute(_ coord: ARCoordinator, fromX: Float, toX: Float,
                           lateral: Float, phoneHeight: Float = 0.3) {
        let step: Float = 0.35   // 1.4 m/s at the 0.25 s collection tick
        var x = fromX
        while x <= toX {
            coord.performCollectionTick(cameraPosition: cameraAt(x, phoneHeight, lateral))
            x += step
        }
    }

    private func makeRunCoordinator(coinCount: Int) -> (ARCoordinator, Quest) {
        let route = makeDualTrackRoute(pointCount: 11)
        var quest = makeQuest(routeId: route.id, coinCount: coinCount)
        quest.collectionMode = .run
        store.saveRoute(route)
        store.saveQuest(quest)
        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)
        return (coord, quest)
    }

    func test_run_collectsEveryCoinWhenRunningPast() {
        let (coord, quest) = makeRunCoordinator(coinCount: 3)
        walkRoute(coord, fromX: -2, toX: 12, lateral: 0)

        XCTAssertEqual(collectedCallbackIds, quest.items.map(\.id))
        XCTAssertTrue(store.quests.first(where: { $0.id == quest.id })!.isComplete)
    }

    func test_run_playsSoundForEachCoin() {
        let (coord, _) = makeRunCoordinator(coinCount: 3)
        walkRoute(coord, fromX: -2, toX: 12, lateral: 0.4)

        XCTAssertEqual(collectedCallbackIds.count, 3)
        XCTAssertEqual(soundCount, 3)
    }

    func test_run_noSoundWithoutCollection() {
        let (coord, _) = makeRunCoordinator(coinCount: 3)
        walkRoute(coord, fromX: -2, toX: 12, lateral: 1.0)

        XCTAssertEqual(soundCount, 0)
    }

    func test_run_passingFarFromCoins_collectsNothing() {
        let (coord, _) = makeRunCoordinator(coinCount: 3)
        walkRoute(coord, fromX: -2, toX: 12, lateral: 1.0)

        XCTAssertTrue(collectedCallbackIds.isEmpty)
        XCTAssertEqual(coord.testCoinNodeCount, 3)
    }

    func test_run_stoppingShortOfPlane_collectsNothing() {
        let (coord, _) = makeRunCoordinator(coinCount: 1)
        // Single coin at x = 0, approached from −X, stopping 0.5 m short and to the side.
        walkRoute(coord, fromX: -3, toX: -0.5, lateral: 0.2)

        XCTAssertTrue(collectedCallbackIds.isEmpty)
    }

    /// Same pass 0.4 m to the side: through the Run plane, outside the Touch sphere.
    func test_collectionMode_decidesLateralPass() {
        let (runCoord, _) = makeRunCoordinator(coinCount: 3)
        walkRoute(runCoord, fromX: -2, toX: 12, lateral: 0.4)
        XCTAssertEqual(collectedCallbackIds.count, 3, "Run should take coins passed at 0.4 m")

        collectedCallbackIds = []
        let route = makeDualTrackRoute(pointCount: 11)
        store.saveRoute(route)
        let touchQuest = makeQuest(routeId: route.id, coinCount: 3)
        store.saveQuest(touchQuest)
        let touchCoord = makeCoordinator(route: route, quest: touchQuest)
        touchCoord.testBuildCoinNodes(forceRebuild: true)
        walkRoute(touchCoord, fromX: -2, toX: 12, lateral: 0.4, phoneHeight: 0)
        XCTAssertTrue(collectedCallbackIds.isEmpty, "Touch needs the phone within 1 ft")
    }

    func test_touch_collectsAndPlaysSound() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)
        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        coord.performCollectionTick(cameraPosition: cameraAt(0.25, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 1)
        XCTAssertEqual(soundCount, 1)
    }

    func test_run_debugLogShowsDistance() {
        let (coord, _) = makeRunCoordinator(coinCount: 2)
        coord.performCollectionTick(cameraPosition: cameraAt(50, 0.3, 0))

        XCTAssertTrue(debugLogs[0].contains("run h="))
        XCTAssertTrue(debugLogs[0].contains("far"))
    }

    func test_setCollectionMode_persistsAcrossReload() {
        let route = makeDualTrackRoute(pointCount: 11)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)
        XCTAssertEqual(store.quests.first?.collectionMode, .touch)

        store.setCollectionMode(questId: quest.id, mode: .run)

        let reloaded = DataStore(directory: tempDir)
        XCTAssertEqual(reloaded.quests.first(where: { $0.id == quest.id })?.collectionMode, .run)
    }
}

// MARK: - Run Gate Geometry

/// Pure tests for `RunGate` / `RunGateTracker`: each coin sits on a vertical plane
/// across the route, checked between 0.25 s ticks.
final class RunGateGeometryTests: XCTestCase {

    private let tick: Float = 0.25
    private let coinId = UUID()
    /// Phone height; coins sit 0.3 m lower, like the AR route group places them.
    private let phoneY: Float = 1.3
    private var coinY: Float { phoneY - 0.3 }
    /// Route runs along +X, so plane normals are +X.
    private let alongX = SIMD2<Float>(1, 0)

    /// Feeds the tracker a straight run along X past a fixed coin; returns every sweep.
    private func run(fromX: Float, toX: Float, speed: Float = 1.4, z: Float = 0,
                     coin: SIMD3<Float>) -> [RunGate.Sweep] {
        var tracker = RunGateTracker()
        let step = speed * tick * (toX >= fromX ? 1 : -1)
        let count = Int((abs(toX - fromX) / abs(step)).rounded(.down))
        return (0...count).compactMap { i in
            tracker.advance(camera: SIMD3(fromX + Float(i) * step, phoneY, z),
                            coins: [coinId: coin])[coinId]
        }
    }

    private func touched(_ sweeps: [RunGate.Sweep], normal: SIMD2<Float>?) -> Bool {
        sweeps.contains { RunGate.hitTest(sweep: $0, normal: normal).touches }
    }

    func test_passThrough_collects() {
        let sweeps = run(fromX: 0, toX: 10, coin: SIMD3(5, coinY, 0))
        XCTAssertTrue(touched(sweeps, normal: alongX))
    }

    func test_passingNearby_collects() {
        let sweeps = run(fromX: 0, toX: 10, z: 0.55, coin: SIMD3(5, coinY, 0))
        XCTAssertTrue(touched(sweeps, normal: alongX))
    }

    func test_passingBeyondHalfWidth_doesNotCollect() {
        for offset: Float in [0.65, 0.8, 2.0] {
            let sweeps = run(fromX: 0, toX: 10, z: offset, coin: SIMD3(5, coinY, 0))
            XCTAssertFalse(touched(sweeps, normal: alongX), "collected at \(offset) m to the side")
        }
    }

    func test_fastCrossingBetweenTicks_collects() {
        // 9 m/s → 2.25 m per tick: phone samples at x = 0, 2.25, 4.5, 6.75, 9.
        let sweeps = run(fromX: 0, toX: 9, speed: 9, coin: SIMD3(5.6, coinY, 0))
        let endpointsOnly = sweeps.contains {
            RunGate.hitTest(sweep: .stationary($0.to), normal: alongX).touches
        }
        XCTAssertFalse(endpointsOnly, "test setup: no single tick lands on the coin")
        XCTAssertTrue(touched(sweeps, normal: alongX), "the crossing between ticks must catch it")
    }

    func test_reversedDirection_collects() {
        let sweeps = run(fromX: 10, toX: 0, coin: SIMD3(5, coinY, 0))
        XCTAssertTrue(touched(sweeps, normal: alongX))
    }

    func test_stoppingShortOfPlane_doesNotCollect() {
        let sweeps = run(fromX: 0, toX: 4.5, z: 0.1, coin: SIMD3(5, coinY, 0))
        XCTAssertFalse(touched(sweeps, normal: alongX))
    }

    func test_verticalReach() {
        let sweeps = { (coinHeight: Float) in self.run(fromX: 0, toX: 10, coin: SIMD3(5, coinHeight, 0)) }
        XCTAssertTrue(touched(sweeps(phoneY - 1.5), normal: alongX), "at the feet")
        XCTAssertTrue(touched(sweeps(phoneY + 0.2), normal: alongX), "at the head")
        XCTAssertFalse(touched(sweeps(phoneY + 0.5), normal: alongX), "overhead")
        XCTAssertFalse(touched(sweeps(phoneY - 2.0), normal: alongX), "below the ground")
    }

    /// Runner cuts the outside of a corner: no straight-line closest approach, but
    /// the fixed plane across the route is still crossed.
    func test_turningAtCoin_crossesFixedPlane() {
        var tracker = RunGateTracker()
        let coin = SIMD3<Float>(0, coinY, 0)
        let path: [SIMD3<Float>] = [
            SIMD3(-0.8, phoneY, -0.3), SIMD3(-0.4, phoneY, -0.4), SIMD3(0.1, phoneY, -0.45), SIMD3(0.1, phoneY, -0.9)
        ]
        let sweeps = path.compactMap { tracker.advance(camera: $0, coins: [coinId: coin])[coinId] }
        XCTAssertTrue(touched(sweeps, normal: alongX))
    }

    /// The route correction slides the coin behind the phone between ticks: the phone
    /// was before the plane and is now past it, so it still counts.
    func test_coinSlidingPastPhone_stillCrosses() {
        var tracker = RunGateTracker()
        _ = tracker.advance(camera: SIMD3(0, phoneY, 0.4), coins: [coinId: SIMD3(0.1, coinY, 0)])
        let sweep = tracker.advance(camera: SIMD3(0.05, phoneY, 0.4), coins: [coinId: SIMD3(-0.1, coinY, 0)])[coinId]!
        XCTAssertTrue(RunGate.hitTest(sweep: sweep, normal: alongX).touches)
    }

    func test_withoutNormal_planeFacesTravel() {
        let sweeps = run(fromX: 0, toX: 10, z: 0.5, coin: SIMD3(5, coinY, 0))
        XCTAssertTrue(touched(sweeps, normal: nil))
        let stationary = RunGate.Sweep.stationary(SIMD3(0.5, 0.3, 0))
        XCTAssertFalse(RunGate.hitTest(sweep: stationary, normal: nil).touches)
    }

    func test_withinTouchSphere_collectsWithoutCrossing() {
        let sweep = RunGate.Sweep.stationary(SIMD3(0.2, 0.1, 0))
        XCTAssertTrue(RunGate.hitTest(sweep: sweep, normal: alongX).touches)
    }

    func test_trackingJump_doesNotCross() {
        var tracker = RunGateTracker()
        let coin = SIMD3<Float>(5, coinY, 0)
        _ = tracker.advance(camera: SIMD3(0, phoneY, 0), coins: [coinId: coin])
        let jump = tracker.advance(camera: SIMD3(10, phoneY, 0), coins: [coinId: coin])[coinId]!
        XCTAssertEqual(jump.from, jump.to)
        XCTAssertFalse(RunGate.hitTest(sweep: jump, normal: alongX).touches)
    }

    func test_reset_startsFreshSweep() {
        var tracker = RunGateTracker()
        let coin = SIMD3<Float>(5, coinY, 0)
        _ = tracker.advance(camera: SIMD3(4, phoneY, 0), coins: [coinId: coin])
        tracker.reset()
        let sweep = tracker.advance(camera: SIMD3(6, phoneY, 0), coins: [coinId: coin])[coinId]!
        XCTAssertEqual(sweep, .stationary(SIMD3(1, 0.3, 0)))
    }

    // MARK: Route direction

    func test_localDirection_followsTrack() throws {
        let samples = (0...10).map { i in
            LocalRouteSample(sampleId: UUID(), x: 0, y: 0, z: Double(i),
                             timestamp: Date(timeIntervalSince1970: Double(i)),
                             progress: Double(i) / 10, trackingScore: 1, featurePointCount: 100)
        }
        let route = RecordedRoute(name: "Z", geoTrack: [], localTrack: samples, checkpoints: [],
                                  encryptedWorldMapData: nil,
                                  captureQuality: RouteCaptureQuality(matchedSampleRatio: 1, averageFeaturePoints: 100,
                                                                      averageTrackingScore: 1, hasEncryptedWorldMap: false),
                                  preciseEnabled: true, recordingMode: .tight)
        for progress in [0.0, 0.5, 1.0] {
            let direction = try XCTUnwrap(route.localDirection(atProgress: progress))
            XCTAssertEqual(direction.z, 1, accuracy: 1e-4)
        }
    }

    // MARK: Quest persistence

    func test_questDecode_withoutMode_defaultsToTouch() throws {
        let quest = Quest(name: "Legacy", routeId: UUID(), items: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quest)) as! [String: Any]
        json.removeValue(forKey: "collectionMode")
        let decoded = try JSONDecoder().decode(Quest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.collectionMode, .touch)
    }

    func test_questDecode_unknownMode_defaultsToTouch() throws {
        let quest = Quest(name: "Future", routeId: UUID(), items: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quest)) as! [String: Any]
        json["collectionMode"] = "milestone"
        let decoded = try JSONDecoder().decode(Quest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.collectionMode, .touch)
    }

    /// Quests saved as Phone Touch / Body Touch keep working under the new names.
    func test_questDecode_legacyRawValues() throws {
        let quest = Quest(name: "Legacy", routeId: UUID(), items: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quest)) as! [String: Any]
        json["collectionMode"] = "body"
        var decoded = try JSONDecoder().decode(Quest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.collectionMode, .run)
        json["collectionMode"] = "phone"
        decoded = try JSONDecoder().decode(Quest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.collectionMode, .touch)
    }

    func test_questRoundTrip_keepsRun() throws {
        let quest = Quest(name: "Run", routeId: UUID(), items: [], collectionMode: .run)
        let decoded = try JSONDecoder().decode(Quest.self, from: JSONEncoder().encode(quest))
        XCTAssertEqual(decoded.collectionMode, .run)
    }
}
