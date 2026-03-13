import Foundation
import CoreLocation
import simd

// MARK: - Legacy-Friendly Route Point

/// Lightweight geographic point used by map views and overlays.
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

    init(sample: GeoRouteSample) {
        self.id = sample.sampleId
        self.latitude = sample.latitude
        self.longitude = sample.longitude
        self.altitude = sample.altitude
        self.timestamp = sample.timestamp
    }

    init(latitude: Double, longitude: Double, altitude: Double, timestamp: Date = Date()) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

// MARK: - Dual-Track Samples

/// Geographic route sample for map visualization and coarse localization.
struct GeoRouteSample: Codable, Identifiable {
    let sampleId: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    /// Route-relative progress in [0, 1].
    let progress: Double

    var id: UUID { sampleId }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: timestamp
        )
    }
}

/// Local AR sample in recording-space meters for precise in-world replay.
struct LocalRouteSample: Codable, Identifiable {
    let sampleId: UUID
    let x: Double
    let y: Double
    let z: Double
    let timestamp: Date
    let progress: Double
    let trackingScore: Double
    let featurePointCount: Int

    var id: UUID { sampleId }

    var vector: SIMD3<Double> {
        SIMD3<Double>(x, y, z)
    }
}

struct RouteCheckpoint: Codable, Identifiable {
    let id: UUID
    let sampleId: UUID
    let progress: Double
    let timestamp: Date
    let label: String
    let featurePointCount: Int
}

struct RouteCaptureQuality: Codable {
    let matchedSampleRatio: Double
    let averageFeaturePoints: Double
    let averageTrackingScore: Double
    let hasEncryptedWorldMap: Bool

    /// Minimum quality bar for exact AR replay.
    var isReadyForPreciseReplay: Bool {
        matchedSampleRatio >= 0.75
        && averageFeaturePoints >= 100
        && averageTrackingScore >= 0.65
        && hasEncryptedWorldMap
    }
}

// MARK: - Recorded Route

/// Dual-track route where geoTrack is for map use and localTrack is for precise AR replay.
struct RecordedRoute: Codable, Identifiable {
    let id: UUID
    var name: String
    let dateRecorded: Date
    var geoTrack: [GeoRouteSample]
    var localTrack: [LocalRouteSample]
    var checkpoints: [RouteCheckpoint]
    var encryptedWorldMapData: Data?
    var preciseEnabled: Bool
    var captureQuality: RouteCaptureQuality

    /// Convenience map points for existing map-driven views.
    var points: [RoutePoint] {
        geoTrack.map(RoutePoint.init(sample:))
    }

    var totalDistanceMeters: Double {
        guard geoTrack.count > 1 else { return 0 }
        var distance: Double = 0
        for i in 1..<geoTrack.count {
            distance += geoTrack[i].location.distance(from: geoTrack[i - 1].location)
        }
        return distance
    }

    var totalDistanceMiles: Double {
        totalDistanceMeters / 1609.344
    }

    var durationSeconds: TimeInterval {
        guard let first = geoTrack.first?.timestamp,
              let last = geoTrack.last?.timestamp else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// Cumulative ascent in metres — sum of all upward steps. Always >= 0.
    var elevationGainMeters: Double {
        guard geoTrack.count > 1 else { return 0 }
        var gain: Double = 0
        for i in 1..<geoTrack.count {
            let diff = geoTrack[i].altitude - geoTrack[i - 1].altitude
            if diff > 0 { gain += diff }
        }
        return gain
    }

    /// Net elevation change in metres: end altitude − start altitude.
    var netElevationChangeMeters: Double {
        guard let first = geoTrack.first?.altitude,
              let last = geoTrack.last?.altitude else { return 0 }
        return last - first
    }

    var centerCoordinate: CLLocationCoordinate2D {
        guard !geoTrack.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }

        let latSum = geoTrack.reduce(0.0) { $0 + $1.latitude }
        let lonSum = geoTrack.reduce(0.0) { $0 + $1.longitude }
        let count = Double(geoTrack.count)

        return CLLocationCoordinate2D(
            latitude: latSum / count,
            longitude: lonSum / count
        )
    }

    var startLocation: CLLocation? {
        geoTrack.first?.location
    }

    init(
        name: String,
        geoTrack: [GeoRouteSample],
        localTrack: [LocalRouteSample],
        checkpoints: [RouteCheckpoint],
        encryptedWorldMapData: Data?,
        captureQuality: RouteCaptureQuality,
        preciseEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.dateRecorded = Date()
        self.geoTrack = geoTrack
        self.localTrack = localTrack
        self.checkpoints = checkpoints
        self.encryptedWorldMapData = encryptedWorldMapData
        self.captureQuality = captureQuality
        self.preciseEnabled = preciseEnabled
    }

    func geoSample(atProgress progress: Double) -> GeoRouteSample? {
        interpolateGeo(at: progress)
    }

    func localSample(atProgress progress: Double) -> LocalRouteSample? {
        interpolateLocal(at: progress)
    }

    private func interpolateGeo(at progress: Double) -> GeoRouteSample? {
        guard !geoTrack.isEmpty else { return nil }

        let p = max(0, min(1, progress))
        if let exact = geoTrack.first(where: { abs($0.progress - p) < 0.0001 }) {
            return exact
        }

        guard let upperIndex = geoTrack.firstIndex(where: { $0.progress >= p }) else {
            return geoTrack.last
        }
        guard upperIndex > 0 else { return geoTrack.first }

        let lower = geoTrack[upperIndex - 1]
        let upper = geoTrack[upperIndex]
        let span = max(upper.progress - lower.progress, 0.00001)
        let t = (p - lower.progress) / span

        return GeoRouteSample(
            sampleId: UUID(),
            latitude: lower.latitude + (upper.latitude - lower.latitude) * t,
            longitude: lower.longitude + (upper.longitude - lower.longitude) * t,
            altitude: lower.altitude + (upper.altitude - lower.altitude) * t,
            timestamp: lower.timestamp.addingTimeInterval(upper.timestamp.timeIntervalSince(lower.timestamp) * t),
            horizontalAccuracy: lower.horizontalAccuracy + (upper.horizontalAccuracy - lower.horizontalAccuracy) * t,
            verticalAccuracy: lower.verticalAccuracy + (upper.verticalAccuracy - lower.verticalAccuracy) * t,
            progress: p
        )
    }

    private func interpolateLocal(at progress: Double) -> LocalRouteSample? {
        guard !localTrack.isEmpty else { return nil }

        let p = max(0, min(1, progress))
        if let exact = localTrack.first(where: { abs($0.progress - p) < 0.0001 }) {
            return exact
        }

        guard let upperIndex = localTrack.firstIndex(where: { $0.progress >= p }) else {
            return localTrack.last
        }
        guard upperIndex > 0 else { return localTrack.first }

        let lower = localTrack[upperIndex - 1]
        let upper = localTrack[upperIndex]
        let span = max(upper.progress - lower.progress, 0.00001)
        let t = (p - lower.progress) / span

        return LocalRouteSample(
            sampleId: UUID(),
            x: lower.x + (upper.x - lower.x) * t,
            y: lower.y + (upper.y - lower.y) * t,
            z: lower.z + (upper.z - lower.z) * t,
            timestamp: lower.timestamp.addingTimeInterval(upper.timestamp.timeIntervalSince(lower.timestamp) * t),
            progress: p,
            trackingScore: lower.trackingScore + (upper.trackingScore - lower.trackingScore) * t,
            featurePointCount: Int(Double(lower.featurePointCount) + Double(upper.featurePointCount - lower.featurePointCount) * t)
        )
    }
}

// MARK: - Quest Item

/// An item placed along a route for the runner to collect.
enum QuestItemType: String, Codable, CaseIterable {
    case coin = "coin"

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

/// Canonical placement is route progress + vertical offset.
struct QuestItem: Codable, Identifiable {
    let id: UUID
    let type: QuestItemType
    let routeProgress: Double
    let verticalOffset: Double
    var collected: Bool

    /// Collection radius in meters (~5 feet).
    static let collectionRadiusMeters: Double = 1.524

    init(type: QuestItemType, routeProgress: Double, verticalOffset: Double = 0) {
        self.id = UUID()
        self.type = type
        self.routeProgress = max(0, min(1, routeProgress))
        self.verticalOffset = verticalOffset
        self.collected = false
    }

    func resolvedGeoLocation(on route: RecordedRoute) -> CLLocation? {
        guard let sample = route.geoSample(atProgress: routeProgress) else { return nil }
        return CLLocation(
            coordinate: sample.coordinate,
            altitude: sample.altitude + verticalOffset,
            horizontalAccuracy: sample.horizontalAccuracy,
            verticalAccuracy: sample.verticalAccuracy,
            timestamp: sample.timestamp
        )
    }

    func resolvedLocalPosition(on route: RecordedRoute) -> SIMD3<Float>? {
        guard let sample = route.localSample(atProgress: routeProgress) else { return nil }
        return SIMD3<Float>(
            Float(sample.x),
            Float(sample.y + verticalOffset),
            Float(sample.z)
        )
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
