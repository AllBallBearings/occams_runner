import XCTest
import SceneKit
@testable import OccamsRunner

/// Tests for the pure math helpers and CollectionEngine logic.
/// No ARSCNView or ARSession required.
final class ARCoordinatorLogicTests: XCTestCase {

    func test_fireballPreview_loadsBundledSolidEmissiveAsset() throws {
        let asset = try XCTUnwrap(ARPreviewAsset.library.first { $0.displayName == "Fireball" })
        let url = try XCTUnwrap(Bundle.main.url(forResource: (asset.fileName as NSString).deletingPathExtension,
                                               withExtension: "usdz"))
        let scene = try SCNScene(url: url, options: nil)
        var geometries: [SCNGeometry] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if let geometry = node.geometry { geometries.append(geometry) }
            XCTAssertNil(node.camera, "Asset must not include the Blender studio camera")
            XCTAssertNil(node.light, "Asset must not include studio lights")
        }
        XCTAssertEqual(geometries.count, 1)
        let geometry = try XCTUnwrap(geometries.first)
        XCTAssertEqual(geometry.materials.count, 7)
        XCTAssertTrue(geometry.materials.allSatisfy { $0.lightingModel == .physicallyBased })
        XCTAssertTrue(geometry.materials.contains { material in
            guard let color = material.emission.contents as? UIColor else { return false }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            return color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                && max(red, max(green, blue)) > 0.1
        }, "The exported flame must retain emissive materials")
        let (lower, upper) = scene.rootNode.boundingBox
        XCTAssertEqual(upper.y - lower.y, 0.295, accuracy: 0.001)
        XCTAssertGreaterThan(upper.z - lower.z, 0.15, "Fireball must have real volume")
    }

    func test_starCoin_isTheOnlyCoinAndDefaultARPreview() {
        let coins = ARPreviewAsset.library.filter { $0.behavior == .coin }
        XCTAssertEqual(coins.map(\.fileName), ["StarCoin.usdz"])
        XCTAssertEqual(ARPreviewAsset.library.first?.fileName, "StarCoin.usdz")
    }

    func test_starCoin_loadsBundledGeometryUprightAtARSize() throws {
        let node = StarCoinAsset.makeNode()
        var geometries: [SCNGeometry] = []
        node.enumerateChildNodes { child, _ in
            if let geometry = child.geometry { geometries.append(geometry) }
        }
        let geometry = try XCTUnwrap(geometries.first, "Bundled coin must contain visible geometry")
        XCTAssertEqual(geometries.count, 1)
        XCTAssertEqual(geometry.materials.count, 6)
        XCTAssertTrue(geometry.materials.allSatisfy { $0.lightingModel == .physicallyBased })
        let (lower, upper) = node.boundingBox
        XCTAssertEqual(upper.x - lower.x, 0.26, accuracy: 0.001)
        XCTAssertEqual(upper.y - lower.y, 0.26, accuracy: 0.001)
        XCTAssertEqual(upper.z - lower.z, 0.05746, accuracy: 0.001)
        XCTAssertEqual(lower.x + upper.x, 0, accuracy: 0.001)
        XCTAssertEqual(lower.y + upper.y, 0, accuracy: 0.001)
        XCTAssertEqual(lower.z + upper.z, 0, accuracy: 0.001)

        let second = StarCoinAsset.makeNode(bobs: false)
        let spin = try XCTUnwrap(node.childNode(withName: "StarCoinSpin", recursively: false))
        let secondSpin = try XCTUnwrap(second.childNode(withName: "StarCoinSpin", recursively: false))
        XCTAssertFalse(spin === secondSpin)
        spin.removeFromParentNode()
        XCTAssertTrue(secondSpin.parent === second)
        XCTAssertTrue(node.animationKeys.contains("bob"))
        XCTAssertFalse(second.animationKeys.contains("bob"))
    }

    // MARK: - distance3D (ARCoordinator)

    func test_distance3D_samePoint_isZero() {
        XCTAssertEqual(ARCoordinator.distance3D(.init(0, 0, 0), .init(0, 0, 0)), 0.0, accuracy: 1e-6)
    }

    func test_distance3D_xAxis_isAbsoluteDifference() {
        XCTAssertEqual(ARCoordinator.distance3D(.init(0, 0, 0), .init(3, 0, 0)), 3.0, accuracy: 1e-5)
    }

    func test_distance3D_yAxis_isAbsoluteDifference() {
        XCTAssertEqual(ARCoordinator.distance3D(.init(0, 0, 0), .init(0, 4, 0)), 4.0, accuracy: 1e-5)
    }

    func test_distance3D_zAxis_isAbsoluteDifference() {
        XCTAssertEqual(ARCoordinator.distance3D(.init(0, 0, 0), .init(0, 0, 5)), 5.0, accuracy: 1e-5)
    }

    func test_distance3D_diagonal_isPythagorean() {
        let d = ARCoordinator.distance3D(.init(0, 0, 0), .init(1, 1, 1))
        XCTAssertEqual(d, sqrt(3), accuracy: 1e-5)
    }

    func test_distance3D_3_4_5_triangle() {
        let d = ARCoordinator.distance3D(.init(0, 0, 0), .init(3, 4, 0))
        XCTAssertEqual(d, 5.0, accuracy: 1e-5)
    }

    func test_distance3D_isSymmetric() {
        let a = SCNVector3(1.5, -2.3, 4.1)
        let b = SCNVector3(-0.5, 3.7, -1.2)
        XCTAssertEqual(ARCoordinator.distance3D(a, b),
                       ARCoordinator.distance3D(b, a), accuracy: 1e-5)
    }

    // MARK: - CollectionEngine radius (0.15m = half-foot)

    func test_collectionEngine_insideRadius_collects() {
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(0.10, 0, 0)
        XCTAssertLessThan(CollectionEngine.distance3D(camera, coin),
                          CollectionEngine.collectionRadius,
                          "A coin at 0.10m should be inside the 0.15m collection radius")
    }

    func test_collectionEngine_outsideRadius_doesNotCollect() {
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(0.20, 0, 0)
        XCTAssertGreaterThanOrEqual(CollectionEngine.distance3D(camera, coin),
                                    CollectionEngine.collectionRadius,
                                    "A coin at 0.20m should be outside the 0.15m collection radius")
    }

    func test_collectionEngine_exactlyAtRadius_doesNotCollect() {
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(0.15, 0, 0)
        // The condition is `< 0.15`, so exactly 0.15 is NOT collected
        XCTAssertFalse(CollectionEngine.distance3D(camera, coin) < CollectionEngine.collectionRadius)
    }

    // MARK: - CollectionEngine.evaluateCollections

    func test_evaluateCollections_collectsWhenClose() {
        let item = QuestItem(type: .coin, routeProgress: 0.0)
        let positions: [UUID: SCNVector3] = [item.id: SCNVector3(0, 0, 0)]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(0.05, 0, 0),
            items: [item],
            coinWorldPositions: positions,
            pendingIds: [],
            tickSerial: 1
        )
        XCTAssertEqual(result.collectedItemIds, [item.id])
    }

    func test_evaluateCollections_doesNotCollectWhenFar() {
        let item = QuestItem(type: .coin, routeProgress: 0.0)
        let positions: [UUID: SCNVector3] = [item.id: SCNVector3(0, 0, 0)]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(1.0, 0, 0),
            items: [item],
            coinWorldPositions: positions,
            pendingIds: [],
            tickSerial: 1
        )
        XCTAssertTrue(result.collectedItemIds.isEmpty)
    }

    func test_evaluateCollections_skipsPendingItems() {
        let item = QuestItem(type: .coin, routeProgress: 0.0)
        let positions: [UUID: SCNVector3] = [item.id: SCNVector3(0, 0, 0)]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(0, 0, 0),
            items: [item],
            coinWorldPositions: positions,
            pendingIds: [item.id],
            tickSerial: 1
        )
        XCTAssertTrue(result.collectedItemIds.isEmpty)
    }

    func test_evaluateCollections_skipsCollectedItems() {
        var item = QuestItem(type: .coin, routeProgress: 0.0)
        item.collected = true
        let positions: [UUID: SCNVector3] = [item.id: SCNVector3(0, 0, 0)]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(0, 0, 0),
            items: [item],
            coinWorldPositions: positions,
            pendingIds: [],
            tickSerial: 1
        )
        XCTAssertTrue(result.collectedItemIds.isEmpty)
    }

    func test_evaluateCollections_multipleCoins_collectsOnlyClose() {
        let items = (0..<3).map { i in
            QuestItem(type: .coin, routeProgress: Double(i) / 2.0)
        }
        let positions: [UUID: SCNVector3] = [
            items[0].id: SCNVector3(0, 0, 0),
            items[1].id: SCNVector3(5, 0, 0),
            items[2].id: SCNVector3(10, 0, 0),
        ]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(0.05, 0, 0),
            items: items,
            coinWorldPositions: positions,
            pendingIds: [],
            tickSerial: 1
        )
        XCTAssertEqual(result.collectedItemIds, [items[0].id])
    }

    func test_evaluateCollections_debugLogContainsTickSerial() {
        let item = QuestItem(type: .coin, routeProgress: 0.0)
        let positions: [UUID: SCNVector3] = [item.id: SCNVector3(0, 0, 0)]
        let result = CollectionEngine.evaluateCollections(
            cameraPosition: SCNVector3(5, 0, 0),
            items: [item],
            coinWorldPositions: positions,
            pendingIds: [],
            tickSerial: 42
        )
        XCTAssertTrue(result.debugLog.contains("t42"))
    }
}
