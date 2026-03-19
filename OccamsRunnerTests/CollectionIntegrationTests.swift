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

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore(directory: tempDir)
        locationService = LocationService()
        collectedCallbackIds = []
        debugLogs = []
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
        ARCoordinator(
            route: route,
            quest: quest,
            dataStore: store,
            locationService: locationService,
            onAlignmentUpdate: { _, _, _, _ in },
            onNearestItemDistance: { _ in },
            onItemCollected: { [weak self] itemId in
                self?.collectedCallbackIds.append(itemId)
            },
            onDebugTick: { [weak self] log in
                self?.debugLogs.append(log)
            }
        )
    }

    private func cameraAt(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 {
        SCNVector3(x, y, z)
    }

    // Collection uses simple 3D proximity (0.15m) — no direction needed.

    // MARK: - buildCoinNodes Tests

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

    // MARK: - Collection Radius (0.15m, mode-independent)

    func test_collectsWithinHalfFootRadius() {
        let route = makeDualTrackRoute(pointCount: 11, mode: .vast)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Coin at (0,0,0). Camera at (0.10, 0, 0) — within 0.15m radius
        coord.performCollectionTick(cameraPosition: cameraAt(0.10, 0, 0))

        XCTAssertEqual(collectedCallbackIds.count, 1,
                       "Should collect within the 0.15m half-foot radius")
    }

    func test_doesNotCollectOutsideHalfFootRadius() {
        let route = makeDualTrackRoute(pointCount: 11, mode: .vast)
        let quest = makeQuest(routeId: route.id, coinCount: 1)
        store.saveRoute(route)
        store.saveQuest(quest)

        let coord = makeCoordinator(route: route, quest: quest)
        coord.testBuildCoinNodes(forceRebuild: true)

        // Coin at (0,0,0). Camera at (0.20, 0, 0) — outside 0.15m radius
        coord.performCollectionTick(cameraPosition: cameraAt(0.20, 0, 0))

        XCTAssertTrue(collectedCallbackIds.isEmpty,
                      "Should NOT collect outside the 0.15m radius")
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
}
