import XCTest
import CoreLocation
import simd
@testable import OccamsRunner

/// Synthetic routes with a known recording-space → earth transform, so each estimator
/// can be checked against ground truth under realistic GPS noise.
final class GeoRegistrationTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 37.33182, longitude: -122.03118)

    // MARK: - Deterministic noise

    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func gaussian2D(sigma: Double) -> SIMD2<Double> {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            let r = sqrt(-2 * log(u1)) * sigma
            return SIMD2(r * cos(2 * .pi * u2), r * sin(2 * .pi * u2))
        }
    }

    /// L-shaped walk in plan coordinates: 80 m one way, then 40 m at a right angle.
    private func lShapedPlanPath(step: Double = 5) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        var d = 0.0
        while d <= 80 { points.append(SIMD2(0, d)); d += step }
        d = step
        while d <= 40 { points.append(SIMD2(d, 80)); d += step }
        return points
    }

    private func makeRoute(
        planPath: [SIMD2<Double>],
        truth: PlanarTransform,
        gpsSigma: Double,
        firstFixError: SIMD2<Double> = .zero,
        compassYaw: Double? = nil,
        seed: UInt64 = 7
    ) -> RecordedRoute {
        var noise = SeededNoise(seed: seed)
        let frame = ENUFrame(origin: origin)
        var geo: [GeoRouteSample] = []
        var local: [LocalRouteSample] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, plan) in planPath.enumerated() {
            let id = UUID()
            var enu = truth.apply(plan) + noise.gaussian2D(sigma: gpsSigma)
            var accuracy = gpsSigma
            if i == 0 {
                enu = truth.apply(plan) + firstFixError
                accuracy = max(gpsSigma, simd_length(firstFixError))
            }
            let coordinate = frame.coordinate(enu)
            let progress = Double(i) / Double(planPath.count - 1)
            let time = start.addingTimeInterval(Double(i) * 3)
            geo.append(GeoRouteSample(
                sampleId: id, latitude: coordinate.latitude, longitude: coordinate.longitude,
                altitude: 50, timestamp: time, horizontalAccuracy: accuracy,
                verticalAccuracy: 5, progress: progress
            ))
            // AR plan (x, y) is AR world (x, -z); recording height ~1.4 m.
            local.append(LocalRouteSample(
                sampleId: id, x: plan.x, y: 0, z: -plan.y, timestamp: time,
                progress: progress, trackingScore: 1, featurePointCount: 200
            ))
        }
        return RecordedRoute(
            name: "Synthetic",
            geoTrack: geo,
            localTrack: local,
            checkpoints: [],
            encryptedWorldMapData: Data([1]),
            captureQuality: RouteCaptureQuality(
                matchedSampleRatio: 1, averageFeaturePoints: 200,
                averageTrackingScore: 1, hasEncryptedWorldMap: true
            ),
            compassYawRadians: compassYaw,
            compassYawConsistency: compassYaw == nil ? nil : 0.98
        )
    }

    private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    // MARK: - Planar transform

    func test_planarTransform_inverseAndComposition_roundTrip() {
        let a = PlanarTransform(yaw: 0.7, translation: SIMD2(3, -4))
        let b = PlanarTransform(yaw: -2.1, translation: SIMD2(-10, 2))
        let p = SIMD2<Double>(5, 9)

        let back = a.inverse.apply(a.apply(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)

        let composed = a.then(b).apply(p)
        let sequential = b.apply(a.apply(p))
        XCTAssertEqual(composed.x, sequential.x, accuracy: 1e-9)
        XCTAssertEqual(composed.y, sequential.y, accuracy: 1e-9)
    }

    func test_planYawMatchesSceneKitRotationAboutY() {
        // Placement applies the plan yaw as a SceneKit rotation about +Y; both must
        // move an AR point to the same place.
        let yaw: Float = 0.9
        let point = SIMD3<Float>(2, 0, -5)
        let rotated = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(point)
        let viaPlan = PlanarGeo.rotate(PlanarGeo.plan(fromAR: point), by: Double(yaw))
        XCTAssertEqual(Double(rotated.x), viaPlan.x, accuracy: 1e-5)
        XCTAssertEqual(Double(-rotated.z), viaPlan.y, accuracy: 1e-5)
    }

    func test_enuFrame_roundTripsCoordinates() {
        let frame = ENUFrame(origin: origin)
        let enu = SIMD2<Double>(123.4, -56.7)
        let back = frame.enu(frame.coordinate(enu))
        XCTAssertEqual(back.x, enu.x, accuracy: 0.01)
        XCTAssertEqual(back.y, enu.y, accuracy: 0.01)
    }

    // MARK: - Rigid fit

    func test_rigidFit_recoversExactTransform() throws {
        let truth = PlanarTransform(yaw: 1.1, translation: SIMD2(20, -7))
        let pairs = lShapedPlanPath().map {
            WeightedPair(source: $0, target: truth.apply($0), weight: 1)
        }
        let fit = try XCTUnwrap(RigidFit.fit(pairs))
        XCTAssertEqual(fit.transform.yaw, truth.yaw, accuracy: 1e-9)
        XCTAssertEqual(fit.transform.translation.x, truth.translation.x, accuracy: 1e-6)
        XCTAssertEqual(fit.rmsResidual, 0, accuracy: 1e-6)
    }

    func test_robustFit_ignoresMultipathOutliers() throws {
        let truth = PlanarTransform(yaw: -0.4, translation: SIMD2(5, 5))
        var pairs = lShapedPlanPath().map {
            WeightedPair(source: $0, target: truth.apply($0), weight: 1)
        }
        pairs[5] = WeightedPair(source: pairs[5].source, target: pairs[5].target + SIMD2(60, 0), weight: 1)
        pairs[12] = WeightedPair(source: pairs[12].source, target: pairs[12].target + SIMD2(0, -45), weight: 1)
        let fit = try XCTUnwrap(RigidFit.robustFit(pairs))
        XCTAssertEqual(degrees(fit.transform.yaw), degrees(truth.yaw), accuracy: 0.5)
        XCTAssertLessThan(simd_length(fit.transform.translation - truth.translation), 1)
    }

    // MARK: - Route registration

    func test_registration_placesStartFarBetterThanTheFirstFix() throws {
        let truth = PlanarTransform(yaw: 37 * .pi / 180, translation: SIMD2(40, -25))
        let firstFixError = SIMD2<Double>(9, -9)  // ~12.7 m — a cold-start fix
        let route = makeRoute(planPath: lShapedPlanPath(), truth: truth, gpsSigma: 5, firstFixError: firstFixError)

        let registration = try XCTUnwrap(RouteGeoRegistration(route: route))
        // The registration's frame is centred on the first fix, so compare on the earth.
        let trueStartCoordinate = ENUFrame(origin: origin).coordinate(truth.apply(.zero))
        let trueStart = registration.frame.enu(trueStartCoordinate)
        let startError = simd_length(registration.startENU - trueStart)

        XCTAssertLessThan(startError, 3.5, "Fit through every fix should pin the start to a few metres")
        XCTAssertLessThan(startError, simd_length(firstFixError) / 3)
        XCTAssertEqual(degrees(registration.localToENU.yaw), 37, accuracy: 6)
        XCTAssertEqual(registration.gpsPairCount, route.localTrack.count)
    }

    func test_registration_shortRouteFallsBackOnRecordedCompassYaw() throws {
        let truth = PlanarTransform(yaw: 1.3, translation: SIMD2(2, 3))
        let tinyPath = [SIMD2<Double>(0, 0), SIMD2(0.5, 0.5), SIMD2(1, 1.2)]
        let route = makeRoute(planPath: tinyPath, truth: truth, gpsSigma: 4, compassYaw: 1.25)

        let registration = try XCTUnwrap(RouteGeoRegistration(route: route))
        XCTAssertEqual(registration.localToENU.yaw, 1.25, accuracy: 0.05,
                       "With no usable GPS track shape, the compass yaw decides the heading")
    }

    func test_registration_requiresPairedSamples() {
        let route = RecordedRoute(name: "GPS only", points: [
            RoutePoint(latitude: 37.0, longitude: -122.0, altitude: 0),
            RoutePoint(latitude: 37.001, longitude: -122.0, altitude: 0)
        ])
        XCTAssertNil(RouteGeoRegistration(route: route))
    }

    // MARK: - Live fusion

    func test_fusion_compassAloneGivesHeadingBeforeWalking() throws {
        var fusion = ARGeoFusion()
        let truthYaw = -1.2
        for i in 0..<30 {
            fusion.addCompass(yaw: truthYaw + 0.03 * sin(Double(i)), time: Double(i) * 0.1)
        }
        fusion.addGPS(arPlan: .zero, enu: SIMD2(10, 10), accuracy: 6, timestamp: Date())

        let estimate = try XCTUnwrap(fusion.estimate())
        XCTAssertEqual(estimate.arToENU.yaw, truthYaw, accuracy: 0.03)
        XCTAssertFalse(estimate.usedGPSHeading)
    }

    func test_fusion_walkingTightensPlacementOfARouteStart() throws {
        // Recording space → earth (known), and the live AR session → earth (to estimate).
        // The user walks ~50 m toward a route start that lies just past the walk.
        let arTruth = PlanarTransform(yaw: -1.4, translation: SIMD2(12, -8))
        let localToENU = PlanarTransform(yaw: 0.6, translation: arTruth.apply(SIMD2(60, 25)))
        var noise = SeededNoise(seed: 99)
        var fusion = ARGeoFusion()

        // Compass carries a 10° site bias; the GPS track has to correct it.
        let biasedCompass = arTruth.yaw + 10 * .pi / 180
        for i in 0..<60 {
            fusion.addCompass(yaw: biasedCompass, time: Double(i) * 0.1)
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            let arPlan = SIMD2<Double>(Double(i) * 1.2, Double(i) * 0.4)  // ~50 m walk
            let enu = arTruth.apply(arPlan) + noise.gaussian2D(sigma: 4)
            fusion.addGPS(arPlan: arPlan, enu: enu, accuracy: 4, timestamp: start.addingTimeInterval(Double(i)))
        }

        let estimate = try XCTUnwrap(fusion.estimate())
        XCTAssertTrue(estimate.usedGPSHeading)
        XCTAssertEqual(degrees(estimate.arToENU.yaw), degrees(arTruth.yaw), accuracy: 6)

        let routeStartLocal = SIMD2<Double>(0, 0)
        let estimated = ARGeoFusion.routeToAR(localToENU: localToENU, arToENU: estimate.arToENU)
            .apply(routeStartLocal)
        let truth = ARGeoFusion.routeToAR(localToENU: localToENU, arToENU: arTruth)
            .apply(routeStartLocal)
        XCTAssertLessThan(simd_length(estimated - truth), 3.5)
    }

    func test_fusion_rejectsInaccurateAndOutOfOrderFixes() {
        var fusion = ARGeoFusion()
        let t = Date()
        fusion.addGPS(arPlan: .zero, enu: .zero, accuracy: 40, timestamp: t)
        XCTAssertTrue(fusion.gpsSamples.isEmpty)
        fusion.addGPS(arPlan: .zero, enu: .zero, accuracy: 5, timestamp: t)
        fusion.addGPS(arPlan: .zero, enu: .zero, accuracy: 5, timestamp: t.addingTimeInterval(-1))
        XCTAssertEqual(fusion.gpsSamples.count, 1)
    }

    // MARK: - Compass math

    func test_backCameraHeading_phoneUprightFacingEast() throws {
        // Device upright, back camera facing east: device x = south, y = up, z = west.
        // Reference axes are (north, west, up); the attitude matrix rows are the device
        // axes in reference coordinates, so row 3 (device z = west) is (0, 1, 0).
        let heading = try XCTUnwrap(CompassMath.backCameraHeadingDegrees(m31: 0, m32: 1))
        XCTAssertEqual(heading, 90, accuracy: 1e-9)
    }

    func test_backCameraHeading_nilWhenPointingAtGround() {
        XCTAssertNil(CompassMath.backCameraHeadingDegrees(m31: 0.1, m32: 0.1))
    }

    func test_arToENUYaw_rotatesCameraForwardOntoCompassHeading() throws {
        // Camera looks along AR +x while the compass says north: AR +x must rotate onto north.
        let yaw = try XCTUnwrap(CompassMath.arToENUYaw(headingDegrees: 0, cameraForwardPlan: SIMD2(1, 0)))
        XCTAssertEqual(degrees(yaw), 90, accuracy: 1e-9)
        let forwardInENU = PlanarGeo.rotate(SIMD2(1, 0), by: yaw)
        XCTAssertEqual(forwardInENU.y, 1, accuracy: 1e-9)
    }

    func test_cameraForwardPlan_readsNegativeZColumn() {
        // Identity camera looks down AR -z, which is plan +y.
        let forward = CompassMath.cameraForwardPlan(matrix_identity_float4x4)
        XCTAssertEqual(forward.x, 0, accuracy: 1e-9)
        XCTAssertEqual(forward.y, 1, accuracy: 1e-9)
    }

    func test_circularMean_wrapsAcrossPi() throws {
        var mean = CircularMean()
        mean.add(179 * .pi / 180)
        mean.add(-179 * .pi / 180)
        let value = try XCTUnwrap(mean.mean)
        XCTAssertEqual(abs(degrees(value)), 180, accuracy: 0.01)
        XCTAssertGreaterThan(mean.consistency, 0.99)
    }

    // MARK: - Persistence

    func test_routeWithoutCompassFields_stillDecodes() throws {
        let route = makeRoute(planPath: lShapedPlanPath(), truth: .identity, gpsSigma: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any])
        json.removeValue(forKey: "compassYawRadians")
        json.removeValue(forKey: "compassYawConsistency")
        let decoded = try JSONDecoder().decode(RecordedRoute.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.compassYawRadians)
        XCTAssertEqual(decoded.localTrack.count, route.localTrack.count)
    }
}
