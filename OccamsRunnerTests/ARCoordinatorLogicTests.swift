import XCTest
import SceneKit
@testable import OccamsRunner

/// Tests for the pure math helpers and CollectionEngine logic.
/// No ARSCNView or ARSession required.
final class ARCoordinatorLogicTests: XCTestCase {

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

    // MARK: - RecordingReadinessEvaluator

    func test_recordingReadiness_staleGPSBlocksRecordingStart() {
        let result = RecordingReadinessEvaluator.evaluate(
            RecordingReadinessInput(
                gpsAge: 5,
                gpsHorizontalAccuracy: 4,
                headingAccuracy: 8,
                trackingScore: 1,
                featurePointCount: 200,
                worldMappingStatus: "mapped",
                stableFrameCount: 30,
                hasStartReference: false
            )
        )

        XCTAssertEqual(result.state, .gettingReady)
        XCTAssertFalse(result.canCaptureStartReference)
    }

    func test_recordingReadiness_poorTrackingAsksUserToSettle() {
        let result = RecordingReadinessEvaluator.evaluate(
            RecordingReadinessInput(
                gpsAge: 0.2,
                gpsHorizontalAccuracy: 4,
                headingAccuracy: 8,
                trackingScore: 0.3,
                featurePointCount: 200,
                worldMappingStatus: "mapped",
                stableFrameCount: 30,
                hasStartReference: false
            )
        )

        XCTAssertEqual(result.state, .gettingReady)
        XCTAssertFalse(result.canCaptureStartReference)
    }

    func test_recordingReadiness_goodSignalsCaptureStartReference() {
        let result = RecordingReadinessEvaluator.evaluate(
            RecordingReadinessInput(
                gpsAge: 0.2,
                gpsHorizontalAccuracy: 4,
                headingAccuracy: 8,
                trackingScore: 1,
                featurePointCount: 200,
                worldMappingStatus: "mapped",
                stableFrameCount: RecordingReadinessEvaluator.stableFramesForStart,
                hasStartReference: false
            )
        )

        XCTAssertEqual(result.state, .scanStartArea)
        XCTAssertTrue(result.canCaptureStartReference)
    }

    // MARK: - RouteLocalizationEvaluator

    func test_routeLocalization_outsideGateReturnsGoToStart() {
        let result = RouteLocalizationEvaluator.evaluate(
            RouteLocalizationInput(
                distanceToStart: 10,
                gpsHorizontalAccuracy: 4,
                trackingScore: 1,
                featurePointCount: 250,
                worldMappingStatus: "mapped",
                consecutiveGoodFrames: 30,
                scanDuration: 1,
                startPoseDelta: 0.2
            )
        )

        XCTAssertEqual(result.state, .goToStart)
        XCTAssertFalse(result.ready)
    }

    func test_routeLocalization_insideGateWithWeakARKeepsScanning() {
        let result = RouteLocalizationEvaluator.evaluate(
            RouteLocalizationInput(
                distanceToStart: 1,
                gpsHorizontalAccuracy: 4,
                trackingScore: 0.3,
                featurePointCount: 20,
                worldMappingStatus: "limited",
                consecutiveGoodFrames: 0,
                scanDuration: 1,
                startPoseDelta: 0.2
            )
        )

        XCTAssertEqual(result.state, .scanStartArea)
        XCTAssertFalse(result.ready)
    }

    func test_routeLocalization_stableARAndPoseDeltaLocalizes() {
        let result = RouteLocalizationEvaluator.evaluate(
            RouteLocalizationInput(
                distanceToStart: 1,
                gpsHorizontalAccuracy: 4,
                trackingScore: 1,
                featurePointCount: 250,
                worldMappingStatus: "mapped",
                consecutiveGoodFrames: RouteLocalizationEvaluator.stableFramesForLock,
                scanDuration: 1,
                startPoseDelta: 0.2
            )
        )

        XCTAssertEqual(result.state, .localized)
        XCTAssertTrue(result.ready)
    }

    func test_routeLocalization_missingStartReferenceFallsBackWithoutCrashing() {
        let result = RouteLocalizationEvaluator.evaluate(
            RouteLocalizationInput(
                distanceToStart: 1,
                gpsHorizontalAccuracy: 4,
                trackingScore: 1,
                featurePointCount: 250,
                worldMappingStatus: "mapped",
                consecutiveGoodFrames: RouteLocalizationEvaluator.stableFramesForLock,
                scanDuration: 1,
                startPoseDelta: nil
            )
        )

        XCTAssertEqual(result.state, .localized)
        XCTAssertTrue(result.ready)
    }
}
