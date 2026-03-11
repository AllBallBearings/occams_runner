import Foundation
import CoreLocation

// MARK: - Route Point

/// A single GPS point along a recorded route, including altitude.
struct RoutePoint: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double // meters
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: timestamp
        )
    }

    init(from location: CLLocation) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.timestamp = location.timestamp
    }

    init(latitude: Double, longitude: Double, altitude: Double, timestamp: Date = Date()) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

// MARK: - Recorded Route

/// A complete recorded running route.
struct RecordedRoute: Codable, Identifiable {
    let id: UUID
    var name: String
    let dateRecorded: Date
    var points: [RoutePoint]

    var totalDistanceMeters: Double {
        guard points.count > 1 else { return 0 }
        var distance: Double = 0
        for i in 1..<points.count {
            let prev = points[i - 1].location
            let curr = points[i].location
            distance += curr.distance(from: prev)
        }
        return distance
    }

    var totalDistanceMiles: Double {
        totalDistanceMeters / 1609.344
    }

    var durationSeconds: TimeInterval {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// Cumulative ascent in metres — sum of all upward steps. Always ≥ 0.
    var elevationGainMeters: Double {
        guard points.count > 1 else { return 0 }
        var gain: Double = 0
        for i in 1..<points.count {
            let diff = points[i].altitude - points[i - 1].altitude
            if diff > 0 { gain += diff }
        }
        return gain
    }

    /// Net elevation change in metres: end altitude − start altitude.
    /// Negative means you finished lower than you started (e.g., descending stairs).
    var netElevationChangeMeters: Double {
        guard let first = points.first?.altitude,
              let last  = points.last?.altitude else { return 0 }
        return last - first
    }

    var centerCoordinate: CLLocationCoordinate2D {
        guard !points.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let latSum = points.reduce(0.0) { $0 + $1.latitude }
        let lonSum = points.reduce(0.0) { $0 + $1.longitude }
        let count = Double(points.count)
        return CLLocationCoordinate2D(latitude: latSum / count, longitude: lonSum / count)
    }

    init(name: String, points: [RoutePoint]) {
        self.id = UUID()
        self.name = name
        self.dateRecorded = Date()
        self.points = points
    }
}

// MARK: - Quest Item

/// An item placed along a route for the runner to collect.
enum QuestItemType: String, Codable, CaseIterable {
    case coin = "coin"
    // Future types:
    // case gem = "gem"
    // case powerup = "powerup"
    // case boss = "boss"

    var displayName: String {
        switch self {
        case .coin: return "Gold Coin"
        }
    }

    var pointValue: Int {
        switch self {
        case .coin: return 10
        }
    }
}

struct QuestItem: Codable, Identifiable {
    let id: UUID
    let type: QuestItemType
    let latitude: Double
    let longitude: Double
    let altitude: Double
    var collected: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: Date()
        )
    }

    /// Collection radius in meters (~5 feet)
    static let collectionRadiusMeters: Double = 1.524

    init(type: QuestItemType, latitude: Double, longitude: Double, altitude: Double) {
        self.id = UUID()
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.collected = false
    }
}

// MARK: - Quest

/// A quest tied to a recorded route, containing items to collect.
struct Quest: Codable, Identifiable {
    let id: UUID
    var name: String
    let routeId: UUID
    let dateCreated: Date
    var items: [QuestItem]

    var totalItems: Int { items.count }
    var collectedItems: Int { items.filter { $0.collected }.count }
    var totalPoints: Int { items.reduce(0) { $0 + $1.type.pointValue } }
    var collectedPoints: Int { items.filter { $0.collected }.reduce(0) { $0 + $1.type.pointValue } }
    var isComplete: Bool { collectedItems == totalItems }

    init(name: String, routeId: UUID, items: [QuestItem]) {
        self.id = UUID()
        self.name = name
        self.routeId = routeId
        self.dateCreated = Date()
        self.items = items
    }

    /// Reset all items to uncollected for a fresh run.
    mutating func resetProgress() {
        for i in items.indices {
            items[i].collected = false
        }
    }
}

// MARK: - Run Session

/// Tracks a live quest run session.
struct RunSession: Codable, Identifiable {
    let id: UUID
    let questId: UUID
    let startTime: Date
    var endTime: Date?
    var collectedItemIds: [UUID]

    init(questId: UUID) {
        self.id = UUID()
        self.questId = questId
        self.startTime = Date()
        self.collectedItemIds = []
    }
}
