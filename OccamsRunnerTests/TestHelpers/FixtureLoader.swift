import Foundation
@testable import OccamsRunner

enum FixtureLoader {
    static func load<T: Decodable>(_ filename: String) throws -> T {
        guard let url = Bundle(for: RouteModelsTests.self)
            .url(forResource: filename, withExtension: "json") else {
            throw FixtureError.fileNotFound(filename)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Build a straight route moving due east from the given origin for the specified distance.
    /// Points are spaced 10m apart, altitude is constant.
    static func makeStraightRoute(meters: Double,
                                  startLat: Double = 37.33182,
                                  startLon: Double = -122.03118,
                                  altitude: Double = 50.0,
                                  name: String = "Generated Route") -> RecordedRoute {
        // 1 degree longitude ≈ cos(lat) × 111,320 metres
        let metersPerDegreeLon = cos(startLat * .pi / 180) * 111_320.0
        let spacing = 10.0 // metres between points
        let count = Int(ceil(meters / spacing)) + 1

        let points = (0..<count).map { i in
            let distMeters = min(Double(i) * spacing, meters)
            let lon = startLon + distMeters / metersPerDegreeLon
            return RoutePoint(latitude: startLat, longitude: lon,
                              altitude: altitude,
                              timestamp: Date(timeIntervalSince1970: Double(i) * 30))
        }
        return RecordedRoute(name: name, points: points)
    }

    /// Build a route with explicit altitudes. Points are placed 10m apart due east.
    static func makeRouteWithAltitudes(_ altitudes: [Double],
                                       startLat: Double = 37.33182,
                                       startLon: Double = -122.03118) -> RecordedRoute {
        let metersPerDegreeLon = cos(startLat * .pi / 180) * 111_320.0
        let points = altitudes.enumerated().map { i, alt in
            let lon = startLon + (Double(i) * 10.0) / metersPerDegreeLon
            return RoutePoint(latitude: startLat, longitude: lon,
                              altitude: alt,
                              timestamp: Date(timeIntervalSince1970: Double(i) * 30))
        }
        return RecordedRoute(name: "Alt Route", points: points)
    }
}

enum FixtureError: Error {
    case fileNotFound(String)
}
