import XCTest
import CoreLocation
import simd
@testable import OccamsRunner

final class RouteModelsTests: XCTestCase {

    // MARK: - Helpers

    private func makePoint(lat: Double, lon: Double, alt: Double,
                           offset: TimeInterval = 0) -> RoutePoint {
        RoutePoint(latitude: lat, longitude: lon, altitude: alt,
                   timestamp: Date(timeIntervalSince1970: offset))
    }

    // MARK: - totalDistanceMeters

    func test_totalDistance_emptyRoute_returnsZero() {
        let route = RecordedRoute(name: "Test", points: [])
        XCTAssertEqual(route.totalDistanceMeters, 0)
    }

    func test_totalDistance_singlePoint_returnsZero() {
        let route = RecordedRoute(name: "Test", points: [makePoint(lat: 37.33, lon: -122.03, alt: 50)])
        XCTAssertEqual(route.totalDistanceMeters, 0)
    }

    func test_totalDistance_twoPoints_matchesCLLocationDistance() {
        let p1 = makePoint(lat: 37.33182, lon: -122.03118, alt: 50)
        let p2 = makePoint(lat: 37.33182, lon: -122.03005, alt: 50)
        let route = RecordedRoute(name: "Test", points: [p1, p2])

        let expected = p2.location.distance(from: p1.location)
        XCTAssertEqual(route.totalDistanceMeters, expected, accuracy: 0.001)
    }

    func test_totalDistance_multiplePoints_accumulates() {
        let p1 = makePoint(lat: 37.33182, lon: -122.03118, alt: 50)
        let p2 = makePoint(lat: 37.33182, lon: -122.03060, alt: 50)
        let p3 = makePoint(lat: 37.33182, lon: -122.03005, alt: 50)
        let route = RecordedRoute(name: "Test", points: [p1, p2, p3])

        let expected = p2.location.distance(from: p1.location)
                     + p3.location.distance(from: p2.location)
        XCTAssertEqual(route.totalDistanceMeters, expected, accuracy: 0.001)
    }

    func test_totalDistanceMiles_usesCorrectConversionFactor() {
        let p1 = makePoint(lat: 37.33182, lon: -122.03118, alt: 50)
        let p2 = makePoint(lat: 37.33182, lon: -122.03005, alt: 50)
        let route = RecordedRoute(name: "Test", points: [p1, p2])

        XCTAssertEqual(route.totalDistanceMiles, route.totalDistanceMeters / 1609.344, accuracy: 0.0001)
    }

    // MARK: - elevationGainMeters

    func test_elevationGain_emptyRoute_returnsZero() {
        XCTAssertEqual(RecordedRoute(name: "Test", points: []).elevationGainMeters, 0)
    }

    func test_elevationGain_flatRoute_returnsZero() {
        let points = [0, 1, 2].map { makePoint(lat: 37.33, lon: -122.03 - Double($0) * 0.001, alt: 50) }
        XCTAssertEqual(RecordedRoute(name: "Test", points: points).elevationGainMeters, 0)
    }

    func test_elevationGain_pureAscent_returnsTotalRise() {
        // 50 → 55 → 60: gain = 10
        let p1 = makePoint(lat: 37.331, lon: -122.031, alt: 50)
        let p2 = makePoint(lat: 37.332, lon: -122.031, alt: 55)
        let p3 = makePoint(lat: 37.333, lon: -122.031, alt: 60)
        let route = RecordedRoute(name: "Test", points: [p1, p2, p3])
        XCTAssertEqual(route.elevationGainMeters, 10.0, accuracy: 0.001)
    }

    func test_elevationGain_pureDescent_returnsZero() {
        // Descents do NOT count toward gain
        let p1 = makePoint(lat: 37.331, lon: -122.031, alt: 60)
        let p2 = makePoint(lat: 37.332, lon: -122.031, alt: 55)
        let p3 = makePoint(lat: 37.333, lon: -122.031, alt: 50)
        let route = RecordedRoute(name: "Test", points: [p1, p2, p3])
        XCTAssertEqual(route.elevationGainMeters, 0.0)
    }

    func test_elevationGain_mixedProfile_sumsOnlyPositiveDeltas() {
        // 50 → 55 (+5) → 52 (−3) → 58 (+6) → 54 (−4): gain = 5 + 6 = 11
        let alts = [50.0, 55.0, 52.0, 58.0, 54.0]
        let points = alts.enumerated().map { i, alt in
            makePoint(lat: 37.331 + Double(i) * 0.0002, lon: -122.031, alt: alt)
        }
        let route = RecordedRoute(name: "Test", points: points)
        XCTAssertEqual(route.elevationGainMeters, 11.0, accuracy: 0.001)
    }

    // MARK: - netElevationChangeMeters

    func test_netElevation_emptyRoute_returnsZero() {
        XCTAssertEqual(RecordedRoute(name: "Test", points: []).netElevationChangeMeters, 0)
    }

    func test_netElevation_ascent_returnsPositive() {
        let p1 = makePoint(lat: 37.331, lon: -122.031, alt: 50)
        let p2 = makePoint(lat: 37.332, lon: -122.031, alt: 60)
        let route = RecordedRoute(name: "Test", points: [p1, p2])
        XCTAssertEqual(route.netElevationChangeMeters, 10.0, accuracy: 0.001)
    }

    func test_netElevation_descent_returnsNegative() {
        let p1 = makePoint(lat: 37.331, lon: -122.031, alt: 60)
        let p2 = makePoint(lat: 37.332, lon: -122.031, alt: 50)
        let route = RecordedRoute(name: "Test", points: [p1, p2])
        XCTAssertEqual(route.netElevationChangeMeters, -10.0, accuracy: 0.001)
    }

    func test_netElevation_hillRoute_isEndMinusStart() {
        // 50 → 55 → 52 → 58 → 54: net = 54 - 50 = 4
        let alts = [50.0, 55.0, 52.0, 58.0, 54.0]
        let points = alts.enumerated().map { i, alt in
            makePoint(lat: 37.331 + Double(i) * 0.0002, lon: -122.031, alt: alt)
        }
        XCTAssertEqual(RecordedRoute(name: "Test", points: points).netElevationChangeMeters, 4.0, accuracy: 0.001)
    }

    // MARK: - durationSeconds

    func test_duration_emptyRoute_returnsZero() {
        XCTAssertEqual(RecordedRoute(name: "Test", points: []).durationSeconds, 0)
    }

    func test_duration_singlePoint_returnsZero() {
        let route = RecordedRoute(name: "Test", points: [makePoint(lat: 37.33, lon: -122.03, alt: 50, offset: 0)])
        XCTAssertEqual(route.durationSeconds, 0)
    }

    func test_duration_twoPoints_returnsCorrectInterval() {
        let p1 = makePoint(lat: 37.331, lon: -122.031, alt: 50, offset: 0)
        let p2 = makePoint(lat: 37.332, lon: -122.031, alt: 50, offset: 300) // 5 minutes later
        let route = RecordedRoute(name: "Test", points: [p1, p2])
        XCTAssertEqual(route.durationSeconds, 300, accuracy: 0.001)
    }

    // MARK: - centerCoordinate

    func test_center_emptyRoute_returnsOrigin() {
        let center = RecordedRoute(name: "Test", points: []).centerCoordinate
        XCTAssertEqual(center.latitude, 0)
        XCTAssertEqual(center.longitude, 0)
    }

    func test_center_singlePoint_returnsThatPoint() {
        let p = makePoint(lat: 37.33182, lon: -122.03118, alt: 50)
        let center = RecordedRoute(name: "Test", points: [p]).centerCoordinate
        XCTAssertEqual(center.latitude, 37.33182, accuracy: 0.00001)
        XCTAssertEqual(center.longitude, -122.03118, accuracy: 0.00001)
    }

    func test_center_twoSymmetricPoints_returnsMidpoint() {
        let p1 = makePoint(lat: 37.330, lon: -122.030, alt: 50)
        let p2 = makePoint(lat: 37.334, lon: -122.034, alt: 50)
        let center = RecordedRoute(name: "Test", points: [p1, p2]).centerCoordinate
        XCTAssertEqual(center.latitude, 37.332, accuracy: 0.00001)
        XCTAssertEqual(center.longitude, -122.032, accuracy: 0.00001)
    }

    // MARK: - Quest progress

    func test_quest_collectionRadiusMeters_isConstant() {
        XCTAssertEqual(QuestItem.collectionRadiusMeters, 1.524, accuracy: 0.001)
    }

    func test_quest_isComplete_whenAllItemsCollected() {
        let items = (0..<3).map { _ in
            QuestItem(type: .coin, routeProgress: 0.5)
        }
        var quest = Quest(name: "Q", routeId: UUID(), items: items)
        XCTAssertFalse(quest.isComplete)
        for i in quest.items.indices { quest.items[i].collected = true }
        XCTAssertTrue(quest.isComplete)
    }

    func test_quest_isNotComplete_whenSomeUncollected() {
        var items = (0..<3).map { _ in
            QuestItem(type: .coin, routeProgress: 0.5)
        }
        items[0].collected = true
        let quest = Quest(name: "Q", routeId: UUID(), items: items)
        XCTAssertFalse(quest.isComplete)
        XCTAssertEqual(quest.collectedItems, 1)
    }

    func test_quest_collectedPoints_sumsByItemType() {
        let items = (0..<3).map { _ in
            QuestItem(type: .coin, routeProgress: 0.5)
        }
        var quest = Quest(name: "Q", routeId: UUID(), items: items)
        quest.items[0].collected = true
        quest.items[1].collected = true
        // coin.pointValue = 10, 2 collected = 20
        XCTAssertEqual(quest.collectedPoints, 20)
        XCTAssertEqual(quest.totalPoints, 30)
    }

    func test_quest_resetProgress_clearsAllCollected() {
        var items = (0..<3).map { _ in
            QuestItem(type: .coin, routeProgress: 0.5)
        }
        for i in items.indices { items[i].collected = true }
        var quest = Quest(name: "Q", routeId: UUID(), items: items)
        XCTAssertEqual(quest.collectedItems, 3)

        quest.resetProgress()
        XCTAssertEqual(quest.collectedItems, 0)
        XCTAssertFalse(quest.isComplete)
    }

    // MARK: - Fixture round-trip

    func test_fixture_straightRoute_loadsCorrectly() {
        let route = FixtureLoader.makeStraightRoute(meters: 100)
        XCTAssertGreaterThanOrEqual(route.points.count, 2)
        XCTAssertEqual(route.totalDistanceMeters, 100.0, accuracy: 1.0)
        XCTAssertEqual(route.elevationGainMeters, 0)
        XCTAssertEqual(route.netElevationChangeMeters, 0)
    }

    func test_fixture_hillRoute_elevationGainIs11() {
        let route = FixtureLoader.makeRouteWithAltitudes([50.0, 55.0, 52.0, 58.0, 54.0])
        // 50→55(+5), 55→52(-3), 52→58(+6), 58→54(-4): gain = 11
        XCTAssertEqual(route.elevationGainMeters, 11.0, accuracy: 0.001)
        // net = 54 - 50 = 4
        XCTAssertEqual(route.netElevationChangeMeters, 4.0, accuracy: 0.001)
    }

    // MARK: - Route start reference

    func test_routeStartReference_roundTripsThroughJSON() throws {
        let sampleId = UUID()
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(1.2, -0.3, 4.5, 1)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.33182, longitude: -122.03118),
            altitude: 52,
            horizontalAccuracy: 4,
            verticalAccuracy: 3,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let reference = RouteStartReference(
            sampleId: sampleId,
            location: location,
            headingDegrees: 215,
            headingAccuracy: 8,
            headingTimestamp: Date(timeIntervalSince1970: 11),
            headingIsTrueNorth: true,
            cameraTransform: transform,
            featurePointCount: 180,
            trackingScore: 1,
            worldMappingStatus: "mapped",
            timestamp: Date(timeIntervalSince1970: 12)
        )

        let route = RecordedRoute(
            name: "With Start Reference",
            geoTrack: [],
            localTrack: [],
            checkpoints: [],
            encryptedWorldMapData: nil,
            captureQuality: RouteCaptureQuality(
                matchedSampleRatio: 1,
                averageFeaturePoints: 180,
                averageTrackingScore: 1,
                hasEncryptedWorldMap: true
            ),
            startReference: reference
        )

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(RecordedRoute.self, from: data)

        XCTAssertEqual(decoded.startReference?.sampleId, sampleId)
        XCTAssertEqual(decoded.startReference?.cameraPosition?.x ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(decoded.startReference?.cameraPosition?.z ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(decoded.startReference?.worldMappingStatus, "mapped")
    }

    func test_routeStartReference_missingFieldDecodesAsNil() throws {
        let route = RecordedRoute(name: "Legacy", points: [
            makePoint(lat: 37.331, lon: -122.031, alt: 50),
            makePoint(lat: 37.332, lon: -122.031, alt: 50)
        ])

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(RecordedRoute.self, from: data)

        XCTAssertNil(decoded.startReference)
    }

    // MARK: - Render path simplification

    func test_simplifiedLocalTrack_capsThreeMileTightRouteUnderRenderLimit() {
        let samples = (0..<16_100).map { i in
            LocalRouteSample(
                sampleId: UUID(),
                x: Double(i) * 0.3,
                y: 0,
                z: 0,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                progress: Double(i) / 16_099.0,
                trackingScore: 1,
                featurePointCount: 180
            )
        }

        let simplified = RecordedRoute.simplifiedLocalTrack(samples, maxSegments: 1_500)

        XCTAssertLessThanOrEqual(simplified.count, 1_501)
        XCTAssertEqual(simplified.first?.id, samples.first?.id)
        XCTAssertEqual(simplified.last?.id, samples.last?.id)
    }

    func test_simplifiedLocalTrack_preservesMonotonicProgress() {
        let samples = (0..<5_000).map { i in
            LocalRouteSample(
                sampleId: UUID(),
                x: Double(i),
                y: 0,
                z: 0,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                progress: Double(i) / 4_999.0,
                trackingScore: 1,
                featurePointCount: 180
            )
        }

        let simplified = RecordedRoute.simplifiedLocalTrack(samples, maxSegments: 1_500)
        let progressValues = simplified.map(\.progress)

        XCTAssertEqual(progressValues, progressValues.sorted())
    }
}
