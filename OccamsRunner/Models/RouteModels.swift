import Foundation
import CoreLocation
import simd

// MARK: - Recording Mode

enum RecordingMode: String, Codable, CaseIterable {
    case tight = "tight"
    case vast  = "vast"

    var displayName: String {
        switch self {
        case .tight: return "Tight"
        case .vast:  return "Vast"
        }
    }

    /// Minimum distance between recorded geographic points (metres).
    var minimumDistance: Double {
        switch self {
        case .tight: return 0.3    // ~1 foot — stairs, indoor hallways
        case .vast:  return 4.877  // ~16 feet — outdoor runs
        }
    }

    /// CLLocationManager distanceFilter (metres).
    var distanceFilter: Double {
        switch self {
        case .tight: return 0.1
        case .vast:  return 2.0
        }
    }
}

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
    /// Match threshold is 0.65 (not 0.75) because iOS often delivers a burst of
    /// cached GPS fixes at recording start — all with the same stale timestamp —
    /// and only one of that burst can correlate to an AR frame, which unfairly
    /// deflates the ratio. Feature density and tracking score are the stronger
    /// quality signals for AR replay accuracy.
    /// Feature density threshold is 75 (not 100) because outdoor environments have
    /// less surface texture than indoors, so ARKit naturally produces fewer feature
    /// points. 75 still ensures solid tracking while being achievable outdoors.
    var isReadyForPreciseReplay: Bool {
        matchedSampleRatio >= 0.65
        && averageFeaturePoints >= 75
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
    /// The mode used when this route was recorded — determines coin collection geometry.
    var recordingMode: RecordingMode

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

    /// Convenience init that converts a flat ``RoutePoint`` array to a dual-track route.
    /// Progress is computed from cumulative distance. Used for fixtures and UI-test helpers.
    init(name: String, points: [RoutePoint]) {
        self.id = UUID()
        self.name = name
        self.dateRecorded = Date()
        self.localTrack = []
        self.checkpoints = []
        self.encryptedWorldMapData = nil
        self.preciseEnabled = false
        self.recordingMode = .vast
        self.captureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0,
            averageFeaturePoints: 0,
            averageTrackingScore: 0,
            hasEncryptedWorldMap: false
        )
        guard !points.isEmpty else { self.geoTrack = []; return }
        var totalDist: Double = 0
        var cumulative: [Double] = [0]
        for i in 1..<points.count {
            totalDist += points[i].location.distance(from: points[i - 1].location)
            cumulative.append(totalDist)
        }
        self.geoTrack = points.enumerated().map { i, p in
            let progress: Double = totalDist > 0
                ? cumulative[i] / totalDist
                : (points.count > 1 ? Double(i) / Double(points.count - 1) : 0)
            return GeoRouteSample(
                sampleId: p.id,
                latitude: p.latitude,
                longitude: p.longitude,
                altitude: p.altitude,
                timestamp: p.timestamp,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                progress: progress
            )
        }
    }

    init(
        name: String,
        geoTrack: [GeoRouteSample],
        localTrack: [LocalRouteSample],
        checkpoints: [RouteCheckpoint],
        encryptedWorldMapData: Data?,
        captureQuality: RouteCaptureQuality,
        preciseEnabled: Bool = true,
        recordingMode: RecordingMode = .vast
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
        self.recordingMode = recordingMode
    }

    // Custom decoder so routes saved before `recordingMode` was added
    // still load correctly — missing key defaults to .vast.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decode(UUID.self,                  forKey: .id)
        name               = try c.decode(String.self,                forKey: .name)
        dateRecorded       = try c.decode(Date.self,                  forKey: .dateRecorded)
        geoTrack           = try c.decode([GeoRouteSample].self,      forKey: .geoTrack)
        localTrack         = try c.decode([LocalRouteSample].self,    forKey: .localTrack)
        checkpoints        = try c.decode([RouteCheckpoint].self,     forKey: .checkpoints)
        encryptedWorldMapData = try c.decodeIfPresent(Data.self,      forKey: .encryptedWorldMapData)
        preciseEnabled     = try c.decode(Bool.self,                  forKey: .preciseEnabled)
        captureQuality     = try c.decode(RouteCaptureQuality.self,   forKey: .captureQuality)
        // Default to .vast for routes recorded before this field existed.
        recordingMode      = try c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .vast
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

    /// Collection radius in meters (~5 feet, generous for AR drift).
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
    /// `true` when the user paused mid-run. The quest item collected states are
    /// persisted separately; this flag just tells QuestDetailView to show
    /// "Resume AR Run" instead of (or alongside) "Start AR Run".
    var isPaused: Bool

    init(questId: UUID) {
        self.id = UUID()
        self.questId = questId
        self.startTime = Date()
        self.collectedItemIds = []
        self.isPaused = false
    }

    // Custom decoder so sessions saved before `isPaused` was added still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(UUID.self,    forKey: .id)
        questId          = try c.decode(UUID.self,    forKey: .questId)
        startTime        = try c.decode(Date.self,    forKey: .startTime)
        endTime          = try c.decodeIfPresent(Date.self,   forKey: .endTime)
        collectedItemIds = try c.decode([UUID].self,  forKey: .collectedItemIds)
        isPaused         = try c.decodeIfPresent(Bool.self,   forKey: .isPaused) ?? false
    }
}
