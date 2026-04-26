import XCTest
@testable import OccamsRunner

final class DataStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: DataStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRoute(name: String = "Test Route") -> RecordedRoute {
        let p1 = RoutePoint(latitude: 37.33182, longitude: -122.03118, altitude: 50)
        let p2 = RoutePoint(latitude: 37.33182, longitude: -122.03005, altitude: 50)
        return RecordedRoute(name: name, points: [p1, p2])
    }

    private func makeQuest(routeId: UUID, name: String = "Test Quest") -> Quest {
        let items = [QuestItem(type: .coin, routeProgress: 0.5)]
        return Quest(name: name, routeId: routeId, items: items)
    }

    // MARK: - Routes

    func test_saveRoute_appendsToInMemoryList() {
        let route = makeRoute()
        store.saveRoute(route)
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertEqual(store.routes.first?.id, route.id)
    }

    func test_saveRoute_persistsToDisk() {
        let route = makeRoute()
        store.saveRoute(route)

        let store2 = DataStore(directory: tempDir)
        XCTAssertEqual(store2.routes.count, 1)
        XCTAssertEqual(store2.routes.first?.id, route.id)
        XCTAssertEqual(store2.routes.first?.name, route.name)
    }

    func test_saveMultipleRoutes_allPersist() {
        let r1 = makeRoute(name: "Route A")
        let r2 = makeRoute(name: "Route B")
        store.saveRoute(r1)
        store.saveRoute(r2)

        let store2 = DataStore(directory: tempDir)
        XCTAssertEqual(store2.routes.count, 2)
    }

    func test_deleteRoute_removesFromInMemory() {
        let route = makeRoute()
        store.saveRoute(route)
        store.deleteRoute(route)
        XCTAssertTrue(store.routes.isEmpty)
    }

    func test_deleteRoute_persistsRemoval() {
        let route = makeRoute()
        store.saveRoute(route)
        store.deleteRoute(route)

        let store2 = DataStore(directory: tempDir)
        XCTAssertTrue(store2.routes.isEmpty)
    }

    func test_deleteRoute_cascadeDeletesAssociatedQuests() {
        let route = makeRoute()
        store.saveRoute(route)
        let quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)
        XCTAssertEqual(store.quests.count, 1)

        store.deleteRoute(route)
        XCTAssertEqual(store.quests.count, 0)

        let store2 = DataStore(directory: tempDir)
        XCTAssertTrue(store2.quests.isEmpty)
    }

    func test_deleteRoute_doesNotDeleteQuestsForOtherRoutes() {
        let r1 = makeRoute(name: "Route 1")
        let r2 = makeRoute(name: "Route 2")
        store.saveRoute(r1)
        store.saveRoute(r2)
        store.saveQuest(makeQuest(routeId: r1.id, name: "Q1"))
        store.saveQuest(makeQuest(routeId: r2.id, name: "Q2"))

        store.deleteRoute(r1)
        XCTAssertEqual(store.quests.count, 1)
        XCTAssertEqual(store.quests.first?.routeId, r2.id)
    }

    func test_route_forId_returnsCorrectRoute() {
        let route = makeRoute()
        store.saveRoute(route)
        XCTAssertEqual(store.route(for: route.id)?.id, route.id)
    }

    func test_route_forUnknownId_returnsNil() {
        XCTAssertNil(store.route(for: UUID()))
    }

    // MARK: - Quests

    func test_saveQuest_newQuest_appendsToList() {
        let route = makeRoute()
        store.saveRoute(route)
        let quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)
        XCTAssertEqual(store.quests.count, 1)
    }

    func test_saveQuest_existingId_updatesInPlace() {
        let route = makeRoute()
        store.saveRoute(route)
        var quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)

        quest.name = "Updated Name"
        store.saveQuest(quest)

        XCTAssertEqual(store.quests.count, 1)
        XCTAssertEqual(store.quests.first?.name, "Updated Name")
    }

    func test_deleteQuest_removesFromList() {
        let route = makeRoute()
        store.saveRoute(route)
        let quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)
        store.deleteQuest(quest)
        XCTAssertTrue(store.quests.isEmpty)
    }

    func test_questsForRouteId_filtersCorrectly() {
        let r1 = makeRoute(name: "R1")
        let r2 = makeRoute(name: "R2")
        store.saveRoute(r1)
        store.saveRoute(r2)
        store.saveQuest(makeQuest(routeId: r1.id, name: "Q1a"))
        store.saveQuest(makeQuest(routeId: r1.id, name: "Q1b"))
        store.saveQuest(makeQuest(routeId: r2.id, name: "Q2"))

        XCTAssertEqual(store.quests(for: r1.id).count, 2)
        XCTAssertEqual(store.quests(for: r2.id).count, 1)
        XCTAssertEqual(store.quests(for: UUID()).count, 0)
    }

    func test_updateQuestItem_marksItemCollected() {
        let route = makeRoute()
        store.saveRoute(route)
        let quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)

        let itemId = quest.items[0].id
        store.updateQuestItem(questId: quest.id, itemId: itemId, collected: true)

        XCTAssertEqual(store.quests.first?.items.first?.collected, true)
    }

    func test_updateQuestItem_unknownQuestId_isNoOp() {
        // Should not crash
        store.updateQuestItem(questId: UUID(), itemId: UUID(), collected: true)
    }

    func test_updateQuestItem_persistsToLoad() {
        let route = makeRoute()
        store.saveRoute(route)
        let quest = makeQuest(routeId: route.id)
        store.saveQuest(quest)

        store.updateQuestItem(questId: quest.id, itemId: quest.items[0].id, collected: true)

        let store2 = DataStore(directory: tempDir)
        XCTAssertEqual(store2.quests.first?.items.first?.collected, true)
    }

    func test_resetQuestProgress_clearsAllItems() {
        let route = makeRoute()
        store.saveRoute(route)

        let items = (0..<3).map { i in
            QuestItem(type: .coin, routeProgress: Double(i) / 2.0)
        }
        let quest = Quest(name: "Q", routeId: route.id, items: items)
        store.saveQuest(quest)

        for item in quest.items {
            store.updateQuestItem(questId: quest.id, itemId: item.id, collected: true)
        }
        XCTAssertEqual(store.quests.first?.collectedItems, 3)

        store.resetQuestProgress(questId: quest.id)
        XCTAssertEqual(store.quests.first?.collectedItems, 0)
    }

    // MARK: - Run Sessions

    func test_saveSession_newSession_appendsToList() {
        let session = RunSession(questId: UUID())
        store.saveSession(session)
        XCTAssertEqual(store.runSessions.count, 1)
    }

    func test_saveSession_existingId_updatesInPlace() {
        var session = RunSession(questId: UUID())
        store.saveSession(session)

        session.endTime = Date()
        store.saveSession(session)

        XCTAssertEqual(store.runSessions.count, 1)
        XCTAssertNotNil(store.runSessions.first?.endTime)
    }

    // MARK: - Persistence edge cases

    func test_missingRoutesFile_initializesEmpty() {
        // Fresh directory — no JSON files exist
        let freshDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: freshDir) }

        let freshStore = DataStore(directory: freshDir)
        XCTAssertTrue(freshStore.routes.isEmpty)
        XCTAssertTrue(freshStore.quests.isEmpty)
        XCTAssertTrue(freshStore.runSessions.isEmpty)
    }

    func test_corruptRoutesFile_doesNotCrash_returnsEmpty() {
        let routesURL = tempDir.appendingPathComponent("routes.json")
        try! "not valid json {{{{".data(using: .utf8)!.write(to: routesURL)

        let corruptStore = DataStore(directory: tempDir)
        XCTAssertTrue(corruptStore.routes.isEmpty)
    }

    func test_dateEncoding_usesISO8601() {
        let route = makeRoute()
        store.saveRoute(route)

        let routesURL = tempDir.appendingPathComponent("routes.json")
        let json = try! String(contentsOf: routesURL, encoding: .utf8)
        // ISO8601 format contains "T" and "Z" — epoch seconds would not
        XCTAssertTrue(json.contains("T") && json.contains("Z"),
                      "Expected ISO8601 date encoding, got: \(json.prefix(200))")
    }

    // MARK: - Full round-trip

    func test_fullRoundTrip_routeQuestSessionAndItemCollection() {
        // 1. Save route
        let route = makeRoute()
        store.saveRoute(route)

        // 2. Save quest with 3 items
        let items = (0..<3).map { i in
            QuestItem(type: .coin, routeProgress: Double(i) / 2.0)
        }
        let quest = Quest(name: "Full Round-Trip Quest", routeId: route.id, items: items)
        store.saveQuest(quest)

        // 3. Mark 2 items collected
        store.updateQuestItem(questId: quest.id, itemId: items[0].id, collected: true)
        store.updateQuestItem(questId: quest.id, itemId: items[1].id, collected: true)

        // 4. Save session
        var session = RunSession(questId: quest.id)
        session.collectedItemIds = [items[0].id, items[1].id]
        store.saveSession(session)

        // 5. Reload from disk with a new store
        let loaded = DataStore(directory: tempDir)

        XCTAssertEqual(loaded.routes.count, 1)
        XCTAssertEqual(loaded.routes.first?.id, route.id)

        XCTAssertEqual(loaded.quests.count, 1)
        let loadedQuest = loaded.quests.first!
        XCTAssertEqual(loadedQuest.collectedItems, 2)
        XCTAssertFalse(loadedQuest.isComplete)
        XCTAssertEqual(loadedQuest.items.filter { $0.collected }.map { $0.id }.sorted { $0.uuidString < $1.uuidString },
                       [items[0].id, items[1].id].sorted { $0.uuidString < $1.uuidString })

        XCTAssertEqual(loaded.runSessions.count, 1)
        XCTAssertEqual(loaded.runSessions.first?.questId, quest.id)

        // Computed properties still work after reload
        XCTAssertGreaterThan(loaded.routes.first!.totalDistanceMeters, 0)
    }
}
