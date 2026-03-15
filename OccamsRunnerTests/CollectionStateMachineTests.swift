import XCTest
import SceneKit
@testable import OccamsRunner

/// Pure state-machine tests for the collection-eligibility logic extracted from ARCoordinator.
///
/// No ARKit, no ARSCNView, no timers, no camera — just UUID→SCNNode dictionaries and
/// QuestItem arrays. All methods under test are static so tests are synchronous and
/// deterministic regardless of simulator or device.
final class CollectionStateMachineTests: XCTestCase {

    // MARK: - Helpers

    /// Creates `count` QuestItems spread evenly across routeProgress [0,1].
    private func makeItems(count: Int) -> [QuestItem] {
        (0..<count).map { i in
            QuestItem(type: .coin, routeProgress: Double(i) / Double(max(1, count - 1)))
        }
    }

    /// Creates a node dictionary keyed by every item's id.
    private func makeNodes(for items: [QuestItem]) -> [UUID: SCNNode] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, SCNNode()) })
    }

    // MARK: - eligibleItems

    func test_eligibleItems_allUncollected_allEligible() {
        let items = makeItems(count: 5)
        let nodes = makeNodes(for: items)
        let result = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: [])
        XCTAssertEqual(result.count, 5, "All 5 items should be eligible when nothing is collected or pending")
    }

    func test_eligibleItems_collectedItemExcluded() {
        var items = makeItems(count: 3)
        items[1].collected = true
        let nodes = makeNodes(for: items)
        let result = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: [])
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains(where: { $0.id == items[1].id }),
                       "Collected item must not appear in eligible set")
    }

    func test_eligibleItems_pendingItemExcluded() {
        let items = makeItems(count: 3)
        let nodes = makeNodes(for: items)
        let pending: Set<UUID> = [items[0].id]
        let result = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pending)
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains(where: { $0.id == items[0].id }),
                       "In-flight (pending) item must not appear in eligible set")
    }

    func test_eligibleItems_noNodeExcluded() {
        let items = makeItems(count: 3)
        var nodes = makeNodes(for: items)
        nodes.removeValue(forKey: items[0].id)     // item[0] has no node
        let result = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: [])
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains(where: { $0.id == items[0].id }),
                       "Item without a scene node must not appear in eligible set")
    }

    func test_eligibleItems_multipleFiltersStack() {
        var items = makeItems(count: 5)
        items[0].collected = true                   // excluded: collected
        var nodes = makeNodes(for: items)
        nodes.removeValue(forKey: items[1].id)      // excluded: no node
        let pending: Set<UUID> = [items[2].id]      // excluded: pending
        // items[3] and items[4] are the only eligible ones

        let result = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pending)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(where: { $0.id == items[3].id }))
        XCTAssertTrue(result.contains(where: { $0.id == items[4].id }))
    }

    // MARK: - shouldCreateNode

    func test_shouldCreateNode_createsWhenMissing() {
        let item = QuestItem(type: .coin, routeProgress: 0.5)
        XCTAssertTrue(ARCoordinator.shouldCreateNode(for: item, coinNodes: [:], pendingIds: []),
                      "A new node should be created when the item is uncollected, not pending, and has no node")
    }

    func test_shouldCreateNode_skipsWhenPending() {
        // This is the ghost-node bug (Root Cause #2):
        // The node was just removed in Phase 2 of checkCollections, but the
        // dataStore hasn't confirmed collected=true yet. Without Fix 2,
        // buildCoinNodes would create a new ghost node here.
        let item = QuestItem(type: .coin, routeProgress: 0.5)
        let pending: Set<UUID> = [item.id]
        XCTAssertFalse(ARCoordinator.shouldCreateNode(for: item, coinNodes: [:], pendingIds: pending),
                       "Must NOT create a ghost node for an in-flight (pending) item — this is the Fix 2 regression guard")
    }

    func test_shouldCreateNode_skipsWhenCollected() {
        var item = QuestItem(type: .coin, routeProgress: 0.5)
        item.collected = true
        XCTAssertFalse(ARCoordinator.shouldCreateNode(for: item, coinNodes: [:], pendingIds: []),
                       "Must not create a node for an item that is already collected")
    }

    func test_shouldCreateNode_skipsWhenNodeExists() {
        let item = QuestItem(type: .coin, routeProgress: 0.5)
        let nodes: [UUID: SCNNode] = [item.id: SCNNode()]
        XCTAssertFalse(ARCoordinator.shouldCreateNode(for: item, coinNodes: nodes, pendingIds: []),
                       "Must not create a duplicate node when one already exists")
    }

    // MARK: - Sequential collection regression

    /// THE regression test for the primary bug.
    ///
    /// Reproduces the full lifecycle that caused only the first coin to be collectible:
    ///   1. Both items are initially eligible.
    ///   2. Item 0 is collected → moved to pendingIds, its node removed.
    ///   3. Item 1 must STILL be eligible (was being blocked by the stale pendingIds bug).
    ///   4. DataStore confirms item 0 collected → Fix 1 clears it from pendingIds.
    ///   5. Item 1 remains eligible; item 0 is now excluded via collected=true.
    func test_sequentialCollection_secondItemStillEligibleAfterFirst() {
        var items = makeItems(count: 2)
        var nodes = makeNodes(for: items)

        // ── Tick 1: both items are eligible ─────────────────────────────────
        let tick1 = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: [])
        XCTAssertEqual(tick1.count, 2, "Both items should start eligible")

        // ── Phase 2: item[0] enters pendingIds, its node is removed ─────────
        var pendingIds: Set<UUID> = [items[0].id]
        nodes.removeValue(forKey: items[0].id)

        // ── Tick 2: item[0] is pending — item[1] must still be eligible ─────
        let tick2 = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pendingIds)
        XCTAssertEqual(tick2.count, 1,
                       "Second item must remain eligible while first is in-flight (pending)")
        XCTAssertEqual(tick2.first?.id, items[1].id)

        // ── Fix 1 fires: dataStore confirms collected=true for item[0] ──────
        // buildCoinNodes sees item.collected == true → pendingCollectionIds.remove(item.id)
        items[0].collected = true
        pendingIds.remove(items[0].id)

        // ── Tick 3: item[0] excluded via collected; item[1] still eligible ──
        let tick3 = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pendingIds)
        XCTAssertEqual(tick3.count, 1)
        XCTAssertEqual(tick3.first?.id, items[1].id,
                       "Second item must remain eligible after first item is confirmed collected — regression guard for the primary 'only first coin' bug")
    }

    func test_pendingCleared_whenItemConfirmedCollected() {
        let items = makeItems(count: 2)
        var nodes = makeNodes(for: items)

        // Simulate item[0] in-flight: in pendingIds, node removed
        var pendingIds: Set<UUID> = [items[0].id]
        nodes.removeValue(forKey: items[0].id)

        // Before confirmation: item[1] is eligible
        let before = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pendingIds)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?.id, items[1].id)

        // Fix 1 clears the pending slot when dataStore confirms collected=true
        pendingIds.remove(items[0].id)

        // After clear: item[1] is still eligible (was never blocked by item[0]'s state)
        let after = ARCoordinator.eligibleItems(from: items, coinNodes: nodes, pendingIds: pendingIds)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, items[1].id,
                       "Clearing a confirmed item from pendingIds must not affect eligibility of other items")
    }
}
