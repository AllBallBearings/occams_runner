import XCTest
import SceneKit
@testable import OccamsRunner

/// Tests for the pure math helpers extracted from ARCoordinator.
/// No ARSCNView or ARSession required.
final class ARCoordinatorLogicTests: XCTestCase {

    // MARK: - distance3D

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
        // (1,1,1) to origin = √3 ≈ 1.7320508
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

    // MARK: - Collection threshold

    func test_distance3D_insideCollectionThreshold_lessThan2() {
        // The game collects a coin when distance < 2.0 in AR scene space
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(1.5, 0, 0)
        XCTAssertLessThan(ARCoordinator.distance3D(camera, coin), 2.0)
    }

    func test_distance3D_outsideCollectionThreshold_greaterThanOrEqual2() {
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(2.5, 0, 0)
        XCTAssertGreaterThanOrEqual(ARCoordinator.distance3D(camera, coin), 2.0)
    }

    func test_distance3D_exactlyAtThreshold_isNotCollected() {
        let camera = SCNVector3(0, 0, 0)
        let coin = SCNVector3(2.0, 0, 0)
        // The production condition is `< 2.0`, so exactly 2.0 is NOT collected
        XCTAssertFalse(ARCoordinator.distance3D(camera, coin) < 2.0)
    }

    // MARK: - Tight-mode collection sphere (< 0.457 m)

    func test_distance3D_coinInTightRadius_isCollectible() {
        // Tight mode uses a 0.457 m sphere (~1.5 ft).
        // A coin at 0.4 m should be within the threshold.
        let camera = SCNVector3(0, 0, 0)
        let coin   = SCNVector3(0.4, 0, 0)
        let dist = ARCoordinator.distance3D(camera, coin)
        XCTAssertLessThan(dist, 0.457,
                          "A coin at 0.4 m should be inside the tight-mode collection radius of 0.457 m")
    }

    func test_distance3D_coinOutsideTightRadius_notCollectible() {
        // A coin at 0.5 m is just outside the tight-mode threshold.
        let camera = SCNVector3(0, 0, 0)
        let coin   = SCNVector3(0.5, 0, 0)
        let dist = ARCoordinator.distance3D(camera, coin)
        XCTAssertGreaterThanOrEqual(dist, 0.457,
                                    "A coin at 0.5 m should be outside the tight-mode collection radius of 0.457 m")
    }

}
