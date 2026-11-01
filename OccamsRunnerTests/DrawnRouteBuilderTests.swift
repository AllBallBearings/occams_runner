import XCTest
import CoreLocation
import simd
@testable import OccamsRunner

/// Drawn coordinates → dual-track route that runs in AR through GPS placement.
final class DrawnRouteBuilderTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 37.33182, longitude: -122.03118)
    private var frame: ENUFrame { ENUFrame(origin: origin) }

    /// Coordinates at the given east/north offsets (metres) from `origin`.
    private func coordinates(_ enu: [SIMD2<Double>]) -> [CLLocationCoordinate2D] {
        enu.map(frame.coordinate)
    }

    /// 60 m north, then 30 m east.
    private var lShape: [CLLocationCoordinate2D] {
        coordinates([SIMD2(0, 0), SIMD2(0, 60), SIMD2(30, 60)])
    }

    // MARK: - Basic shape

    func testRejectsFewerThanTwoDistinctPoints() {
        XCTAssertNil(DrawnRouteBuilder.makeRoute(name: "x", coordinates: []))
        XCTAssertNil(DrawnRouteBuilder.makeRoute(name: "x", coordinates: [origin]))
        XCTAssertNil(DrawnRouteBuilder.makeRoute(name: "x", coordinates: [origin, origin, origin]))
        XCTAssertNil(DrawnRouteBuilder.makeRoute(
            name: "x", coordinates: coordinates([SIMD2(0, 0), SIMD2(0.2, 0.1)])))
    }

    func testRouteIsMarkedDrawnAndRunnableWithoutWorldMap() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "Park loop", coordinates: lShape))
        XCTAssertEqual(route.name, "Park loop")
        XCTAssertEqual(route.source, .drawn)
        XCTAssertEqual(route.recordingMode, .vast)
        XCTAssertNil(route.encryptedWorldMapData)
        XCTAssertFalse(route.captureQuality.isReadyForPreciseReplay)
        XCTAssertTrue(route.canRunInAR)
    }

    func testRecordedRouteWithoutWorldMapCannotRunInAR() {
        let route = RecordedRoute(name: "Legacy", points: [
            RoutePoint(latitude: origin.latitude, longitude: origin.longitude, altitude: 0),
            RoutePoint(latitude: origin.latitude + 0.001, longitude: origin.longitude, altitude: 0),
        ])
        XCTAssertEqual(route.source, .recorded)
        XCTAssertFalse(route.canRunInAR)
    }

    // MARK: - Tracks

    func testTracksArePairedOneToOneBySampleId() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        XCTAssertEqual(route.geoTrack.count, route.localTrack.count)
        XCTAssertEqual(route.geoTrack.map(\.sampleId), route.localTrack.map(\.sampleId))
        XCTAssertEqual(Set(route.geoTrack.map(\.sampleId)).count, route.geoTrack.count)
    }

    func testLocalTrackIsEastNorthFromStartInARAxes() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        let first = try XCTUnwrap(route.localTrack.first)
        let last = try XCTUnwrap(route.localTrack.last)
        XCTAssertEqual(first.vector, SIMD3<Double>(0, 0, 0))
        // 30 m east → +x; 60 m north → -z (ARKit's z points toward the viewer / south).
        XCTAssertEqual(last.x, 30, accuracy: 0.01)
        XCTAssertEqual(last.z, -60, accuracy: 0.01)
        // Corner of the L is kept exactly.
        XCTAssertTrue(route.localTrack.contains {
            abs($0.x) < 0.01 && abs($0.z + 60) < 0.01
        })
    }

    func testLocalTrackIsFlatAtStartHeight() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(
            name: "r", coordinates: lShape, startAltitude: 42))
        XCTAssertTrue(route.localTrack.allSatisfy { $0.y == 0 })
        XCTAssertTrue(route.geoTrack.allSatisfy { $0.altitude == 42 })
        XCTAssertEqual(route.elevationGainMeters, 0)
    }

    func testGeoTrackKeepsDrawnCoordinates() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        for drawn in lShape {
            XCTAssertTrue(route.geoTrack.contains {
                abs($0.latitude - drawn.latitude) < 1e-9 && abs($0.longitude - drawn.longitude) < 1e-9
            }, "drawn point \(drawn) missing from geoTrack")
        }
        XCTAssertEqual(route.totalDistanceMeters, 90, accuracy: 0.5)
    }

    func testTracksAreDensifiedToModeSpacing() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        let spacing = RecordingMode.vast.minimumDistance
        for i in 1..<route.localTrack.count {
            let step = simd_distance(route.localTrack[i].vector, route.localTrack[i - 1].vector)
            XCTAssertLessThanOrEqual(step, spacing + 1e-6)
            XCTAssertGreaterThan(step, 0)
        }
        // 90 m at ≤4.88 m spacing needs at least 19 segments.
        XCTAssertGreaterThanOrEqual(route.localTrack.count, 20)
    }

    // MARK: - Progress

    func testProgressRunsZeroToOneByDistance() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        XCTAssertEqual(route.localTrack.first?.progress, 0)
        XCTAssertEqual(route.localTrack.last?.progress, 1)
        XCTAssertEqual(route.geoTrack.map(\.progress), route.localTrack.map(\.progress))

        let progress = route.localTrack.map(\.progress)
        XCTAssertEqual(progress, progress.sorted())

        // The corner sits 60 m into a 90 m route.
        let corner = try XCTUnwrap(route.localTrack.first { abs($0.x) < 0.01 && abs($0.z + 60) < 0.01 })
        XCTAssertEqual(corner.progress, 60.0 / 90.0, accuracy: 1e-6)
    }

    func testInterpolatedSamplesFollowTheDrawnPath() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        // Halfway along the 90 m route is 45 m up the first (north) leg.
        let local = try XCTUnwrap(route.localSample(atProgress: 0.5))
        XCTAssertEqual(local.x, 0, accuracy: 0.01)
        XCTAssertEqual(local.z, -45, accuracy: 0.01)

        let geo = try XCTUnwrap(route.geoSample(atProgress: 0.5))
        let enu = frame.enu(geo.coordinate)
        XCTAssertEqual(enu.x, 0, accuracy: 0.05)
        XCTAssertEqual(enu.y, 45, accuracy: 0.05)
    }

    // MARK: - Cleanup helpers

    func testDuplicatePointsAreDropped() {
        let drawn = coordinates([SIMD2(0, 0), SIMD2(0.1, 0), SIMD2(10, 0), SIMD2(10, 0.2), SIMD2(10, 10)])
        let kept = DrawnRouteBuilder.removingDuplicates(drawn)
        XCTAssertEqual(kept.count, 3)
    }

    func testDensifyKeepsOriginalsAndCapsSpacing() {
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 1)]
        let dense = DrawnRouteBuilder.densify(points, maxSpacingMeters: 3)
        // 10 m at 3 m spacing → 4 segments; the 1 m leg stays as is.
        XCTAssertEqual(dense.count, 6)
        XCTAssertEqual(dense.first, SIMD2(0, 0))
        XCTAssertTrue(dense.contains(SIMD2(10, 0)))
        XCTAssertEqual(dense.last, SIMD2(10, 1))
        for i in 1..<dense.count {
            XCTAssertLessThanOrEqual(simd_distance(dense[i], dense[i - 1]), 3 + 1e-9)
        }
    }

    func testPathLengthMeters() {
        XCTAssertEqual(DrawnRouteBuilder.pathLengthMeters([]), 0)
        XCTAssertEqual(DrawnRouteBuilder.pathLengthMeters(lShape), 90, accuracy: 0.01)
    }

    // MARK: - Integration

    func testGeoRegistrationOfDrawnRouteIsExact() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        let registration = try XCTUnwrap(RouteGeoRegistration(route: route))
        XCTAssertEqual(registration.gpsPairCount, route.localTrack.count)
        XCTAssertEqual(registration.localToENU.yaw, 0, accuracy: 1e-6)
        XCTAssertEqual(simd_length(registration.localToENU.translation), 0, accuracy: 1e-6)
        XCTAssertEqual(registration.startCoordinate.latitude, origin.latitude, accuracy: 1e-9)
        XCTAssertEqual(registration.startCoordinate.longitude, origin.longitude, accuracy: 1e-9)
        XCTAssertLessThan(registration.yawSigma, .pi)
    }

    func testQuestGenerationWorksOnDrawnRoute() throws {
        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        let items = QuestGenerator.generateItems(along: route, intervalFeet: 10)
        // 90 m ≈ 295 ft → 29 coins at 10 ft.
        XCTAssertEqual(items.count, 29)
        for item in items {
            XCTAssertNotNil(item.resolvedLocalPosition(on: route))
            XCTAssertNotNil(item.resolvedGeoLocation(on: route))
        }
    }

    func testDrawnRouteSurvivesSaveAndReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrawnRouteBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let route = try XCTUnwrap(DrawnRouteBuilder.makeRoute(name: "r", coordinates: lShape))
        DataStore(directory: dir).saveRoute(route)

        let reloaded = try XCTUnwrap(DataStore(directory: dir).route(for: route.id))
        XCTAssertEqual(reloaded.source, .drawn)
        XCTAssertEqual(reloaded.localTrack.count, route.localTrack.count)
        XCTAssertTrue(reloaded.canRunInAR)
    }
}
