import XCTest
import CoreLocation
@testable import OccamsRunner

final class QuestGeneratorTests: XCTestCase {

    // MARK: - Edge cases

    func test_generateItems_emptyRoute_returnsEmpty() {
        let route = RecordedRoute(name: "Test", points: [])
        XCTAssertTrue(QuestGenerator.generateItems(along: route).isEmpty)
    }

    func test_generateItems_singlePoint_returnsEmpty() {
        let p = RoutePoint(latitude: 37.33, longitude: -122.03, altitude: 50)
        let route = RecordedRoute(name: "Test", points: [p])
        XCTAssertTrue(QuestGenerator.generateItems(along: route).isEmpty)
    }

    // MARK: - Interval conversion

    func test_intervalFeetToMeters_conversionFactor() {
        // 1 foot = 0.3048 metres exactly (pinned by international standard)
        let route = FixtureLoader.makeStraightRoute(meters: 1000)
        let at10ft = QuestGenerator.generateItems(along: route, intervalFeet: 10)
        let at20ft = QuestGenerator.generateItems(along: route, intervalFeet: 20)
        // Halving the interval should approximately double the count
        XCTAssertGreaterThan(at10ft.count, at20ft.count)
        XCTAssertEqual(Double(at10ft.count) / Double(at20ft.count), 2.0, accuracy: 0.15)
    }

    func test_10feet_is3_048Metres() {
        // A 100m route at 10ft intervals should produce ≈ 100/3.048 ≈ 32 items
        let route = FixtureLoader.makeStraightRoute(meters: 100)
        let items = QuestGenerator.generateItems(along: route, intervalFeet: 10)
        let expectedInterval = 10.0 * 0.3048 // 3.048m
        let expectedCount = Int(100.0 / expectedInterval)
        XCTAssertEqual(items.count, expectedCount, accuracy: 2)
    }

    // MARK: - Item properties

    func test_allItemsUncollectedOnCreation() {
        let route = FixtureLoader.makeStraightRoute(meters: 50)
        let items = QuestGenerator.generateItems(along: route)
        XCTAssertTrue(items.allSatisfy { !$0.collected })
    }

    func test_itemType_isPassedThrough() {
        let route = FixtureLoader.makeStraightRoute(meters: 50)
        let items = QuestGenerator.generateItems(along: route, itemType: .coin)
        XCTAssertTrue(items.allSatisfy { $0.type == .coin })
    }

    func test_allItemsHaveUniqueIds() {
        let route = FixtureLoader.makeStraightRoute(meters: 200)
        let items = QuestGenerator.generateItems(along: route)
        let ids = Set(items.map { $0.id })
        XCTAssertEqual(ids.count, items.count)
    }

    // MARK: - Spacing invariant (most important)

    func test_spacingBetweenConsecutiveItems_matchesInterval() {
        // On a straight route, item spacing should equal intervalMeters within 5%
        let route = FixtureLoader.makeStraightRoute(meters: 500)
        let intervalFeet = 20.0
        let intervalMeters = intervalFeet * 0.3048
        let items = QuestGenerator.generateItems(along: route, intervalFeet: intervalFeet)

        guard items.count > 1 else {
            XCTFail("Expected more than 1 item")
            return
        }

        for i in 1..<items.count {
            guard let locA = items[i - 1].resolvedGeoLocation(on: route),
                  let locB = items[i].resolvedGeoLocation(on: route) else {
                XCTFail("Could not resolve item geo location at index \(i)")
                return
            }
            let dist = locB.distance(from: locA)
            XCTAssertEqual(dist, intervalMeters, accuracy: intervalMeters * 0.05,
                           "Gap \(i): expected ≈\(intervalMeters)m, got \(dist)m")
        }
    }

    func test_spacingInvariant_withShortSegments_shorterThanInterval() {
        // Route with segments much shorter than the interval.
        // The accumulator must cross the interval boundary correctly.
        let route = FixtureLoader.makeStraightRoute(meters: 100)
        // Use a very large interval (50ft = 15.24m) against short 10m segments.
        let intervalFeet = 50.0
        let intervalMeters = intervalFeet * 0.3048
        let items = QuestGenerator.generateItems(along: route, intervalFeet: intervalFeet)

        guard items.count > 1 else { return } // may be only 1 on 100m route with 15m interval

        for i in 1..<items.count {
            guard let locA = items[i - 1].resolvedGeoLocation(on: route),
                  let locB = items[i].resolvedGeoLocation(on: route) else {
                XCTFail("Could not resolve item geo location at index \(i)")
                return
            }
            let dist = locB.distance(from: locA)
            XCTAssertEqual(dist, intervalMeters, accuracy: intervalMeters * 0.05)
        }
    }

    // MARK: - Altitude interpolation

    func test_altitudeInterpolation_midpointOfElevationSegment_isLinear() {
        // Route: 10m segment with 10m elevation gain (50 → 60).
        // An item placed at the midpoint of that segment should have altitude ≈ 55.
        let p1 = RoutePoint(latitude: 37.33182, longitude: -122.03118, altitude: 50)
        let p2 = RoutePoint(latitude: 37.33182, longitude: -122.03005, altitude: 60)
        let route = RecordedRoute(name: "Test", points: [p1, p2])

        let dist = p2.location.distance(from: p1.location)
        // Interval slightly more than half the segment so first item lands near midpoint
        let halfDist = dist / 2.0
        let intervalFeet = (halfDist / 0.3048) + 0.01

        let items = QuestGenerator.generateItems(along: route, intervalFeet: intervalFeet)
        guard let first = items.first,
              let loc = first.resolvedGeoLocation(on: route) else {
            XCTFail("Expected at least one item with resolvable location")
            return
        }
        // Altitude should be near the midpoint (55m), allow ±1m
        XCTAssertEqual(loc.altitude, 55.0, accuracy: 1.0)
    }

    func test_itemsOnFlatRoute_allHaveSameAltitude() {
        let route = FixtureLoader.makeStraightRoute(meters: 200, altitude: 42.0)
        let items = QuestGenerator.generateItems(along: route)
        XCTAssertTrue(items.allSatisfy { item in
            guard let loc = item.resolvedGeoLocation(on: route) else { return false }
            return abs(loc.altitude - 42.0) < 0.001
        })
    }

    // MARK: - Default parameters

    func test_defaultIntervalFeet_is5() {
        let route = FixtureLoader.makeStraightRoute(meters: 100)
        let defaultItems = QuestGenerator.generateItems(along: route)
        let explicit5ftItems = QuestGenerator.generateItems(along: route, intervalFeet: 5.0)
        XCTAssertEqual(defaultItems.count, explicit5ftItems.count)
    }
}

/// Free-function overload of XCTAssertEqual for `Int` with an integer accuracy tolerance.
/// Must be a free function (not an instance method on XCTestCase) — if defined as an
/// instance method it shadows the global XCTAssertEqual overloads for all types inside
/// any XCTestCase subclass, causing build errors across the entire test target.
func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "",
                    file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy,
                  "(\(a)) is not equal to (\(b)) with accuracy (\(accuracy)). \(message)",
                  file: file, line: line)
}
