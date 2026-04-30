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

// MARK: - Recording Readiness

enum RecordingCoachingState: String, Codable {
    case gettingReady
    case scanStartArea
    case recording
    case needsMoreScan
}

struct RecordingReadinessInput {
    let gpsAge: TimeInterval?
    let gpsHorizontalAccuracy: Double?
    let headingAccuracy: Double?
    let trackingScore: Double
    let featurePointCount: Int
    let worldMappingStatus: String
    let stableFrameCount: Int
    let hasStartReference: Bool
}

struct RecordingReadinessResult {
    let state: RecordingCoachingState
    let canCaptureStartReference: Bool
    let message: String
}

enum RecordingReadinessEvaluator {
    static let maximumFreshGPSAge: TimeInterval = 1.0
    static let maximumGPSAccuracy: Double = 25
    static let maximumHeadingAccuracy: Double = 35
    static let minimumTrackingScore: Double = 0.65
    static let minimumFeaturePoints = 90
    static let stableFramesForStart = 18

    static func evaluate(_ input: RecordingReadinessInput) -> RecordingReadinessResult {
        guard let gpsAge = input.gpsAge,
              gpsAge <= maximumFreshGPSAge,
              let gpsAccuracy = input.gpsHorizontalAccuracy,
              gpsAccuracy >= 0,
              gpsAccuracy <= maximumGPSAccuracy else {
            return RecordingReadinessResult(
                state: .gettingReady,
                canCaptureStartReference: false,
                message: "Hold still while GPS settles."
            )
        }

        if let headingAccuracy = input.headingAccuracy,
           headingAccuracy >= 0,
           headingAccuracy > maximumHeadingAccuracy {
            return RecordingReadinessResult(
                state: .gettingReady,
                canCaptureStartReference: false,
                message: "Hold still while compass heading settles."
            )
        }

        guard input.trackingScore >= minimumTrackingScore else {
            return RecordingReadinessResult(
                state: input.hasStartReference ? .needsMoreScan : .gettingReady,
                canCaptureStartReference: false,
                message: "Move slowly while AR tracking settles."
            )
        }

        guard input.featurePointCount >= minimumFeaturePoints else {
            return RecordingReadinessResult(
                state: input.hasStartReference ? .needsMoreScan : .scanStartArea,
                canCaptureStartReference: false,
                message: "Scan the ground and nearby surroundings at the start."
            )
        }

        guard input.worldMappingStatus == "extending" || input.worldMappingStatus == "mapped" else {
            return RecordingReadinessResult(
                state: input.hasStartReference ? .needsMoreScan : .scanStartArea,
                canCaptureStartReference: false,
                message: "Keep scanning the start area until AR mapping improves."
            )
        }

        let canCapture = input.stableFrameCount >= stableFramesForStart
        return RecordingReadinessResult(
            state: input.hasStartReference ? .recording : .scanStartArea,
            canCaptureStartReference: canCapture,
            message: canCapture
                ? "Start reference locked. Recording route."
                : "Keep the phone steady on the start area."
        )
    }
}

// MARK: - Route Localization

struct RouteLocalizationInput {
    let distanceToStart: Double?
    let gpsHorizontalAccuracy: Double?
    let trackingScore: Double
    let featurePointCount: Int
    let worldMappingStatus: String
    let consecutiveGoodFrames: Int
    let scanDuration: TimeInterval
    let startPoseDelta: Double?
}

struct RouteLocalizationResult {
    let state: ARAlignmentState
    let confidence: Double
    let ready: Bool
    let coachingMessage: String
}

enum RouteLocalizationEvaluator {
    static let startGateDistanceMeters: Double = 3
    static let minimumFeaturePoints = 120
    static let stableFramesForLock = 15
    static let maximumStartPoseDelta: Double = 1.5

    static func evaluate(_ input: RouteLocalizationInput) -> RouteLocalizationResult {
        if let distance = input.distanceToStart, distance > startGateDistanceMeters {
            return RouteLocalizationResult(
                state: .goToStart,
                confidence: 0.2,
                ready: false,
                coachingMessage: "Follow the marker to the recorded start."
            )
        }

        let featureScore = min(1.0, Double(input.featurePointCount) / 300.0)
        let mappingScore: Double
        switch input.worldMappingStatus {
        case "mapped":
            mappingScore = 1.0
        case "extending":
            mappingScore = 0.8
        case "limited":
            mappingScore = 0.45
        default:
            mappingScore = 0.2
        }
        let gpsScore: Double
        if let accuracy = input.gpsHorizontalAccuracy, accuracy >= 0 {
            gpsScore = max(0, min(1, 1 - (accuracy / 30.0)))
        } else {
            gpsScore = 0.4
        }
        let poseScore: Double
        if let delta = input.startPoseDelta {
            poseScore = max(0, min(1, 1 - (delta / maximumStartPoseDelta)))
        } else {
            poseScore = 0.8
        }

        let confidence = max(0.0, min(1.0,
            (featureScore * 0.25)
            + (input.trackingScore * 0.25)
            + (mappingScore * 0.25)
            + (gpsScore * 0.10)
            + (poseScore * 0.15)
        ))

        let poseAcceptable = input.startPoseDelta.map { $0 <= maximumStartPoseDelta } ?? true
        let canLock =
            input.consecutiveGoodFrames >= stableFramesForLock
            && input.trackingScore >= 0.70
            && input.featurePointCount >= minimumFeaturePoints
            && (input.worldMappingStatus == "extending" || input.worldMappingStatus == "mapped")
            && poseAcceptable
            && confidence >= 0.70

        if canLock {
            return RouteLocalizationResult(
                state: .localized,
                confidence: confidence,
                ready: true,
                coachingMessage: "Localized. Route is ready."
            )
        }

        if input.scanDuration > 14, confidence >= 0.45 {
            return RouteLocalizationResult(
                state: .lowConfidence,
                confidence: confidence,
                ready: false,
                coachingMessage: "Low confidence. Scan textured ground and nearby surroundings."
            )
        }

        return RouteLocalizationResult(
            state: .scanStartArea,
            confidence: confidence,
            ready: false,
            coachingMessage: "Point at where recording began and scan slowly."
        )
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

struct RouteStartReference: Codable {
    let sampleId: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let headingDegrees: Double?
    let headingAccuracy: Double?
    let headingTimestamp: Date?
    let headingIsTrueNorth: Bool?
    let cameraTransform: [Float]
    let featurePointCount: Int
    let trackingScore: Double
    let worldMappingStatus: String
    let timestamp: Date

    init(
        sampleId: UUID,
        location: CLLocation,
        headingDegrees: Double?,
        headingAccuracy: Double?,
        headingTimestamp: Date?,
        headingIsTrueNorth: Bool?,
        cameraTransform: simd_float4x4,
        featurePointCount: Int,
        trackingScore: Double,
        worldMappingStatus: String,
        timestamp: Date
    ) {
        self.sampleId = sampleId
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.headingDegrees = headingDegrees
        self.headingAccuracy = headingAccuracy
        self.headingTimestamp = headingTimestamp
        self.headingIsTrueNorth = headingIsTrueNorth
        self.cameraTransform = Self.flatten(cameraTransform)
        self.featurePointCount = featurePointCount
        self.trackingScore = trackingScore
        self.worldMappingStatus = worldMappingStatus
        self.timestamp = timestamp
    }

    var cameraPosition: SIMD3<Float>? {
        guard cameraTransform.count == 16 else { return nil }
        return SIMD3<Float>(cameraTransform[12], cameraTransform[13], cameraTransform[14])
    }

    static func flatten(_ transform: simd_float4x4) -> [Float] {
        [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
        ]
    }
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
    /// Device heading captured when route recording started, in degrees clockwise from north.
    /// Optional so routes recorded before heading capture still decode cleanly.
    var startHeadingDegrees: Double?
    var startHeadingAccuracy: Double?
    var startHeadingTimestamp: Date?
    var startHeadingIsTrueNorth: Bool?
    var startReference: RouteStartReference?

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
        self.startHeadingDegrees = nil
        self.startHeadingAccuracy = nil
        self.startHeadingTimestamp = nil
        self.startHeadingIsTrueNorth = nil
        self.startReference = nil
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
        recordingMode: RecordingMode = .vast,
        startHeadingDegrees: Double? = nil,
        startHeadingAccuracy: Double? = nil,
        startHeadingTimestamp: Date? = nil,
        startHeadingIsTrueNorth: Bool? = nil,
        startReference: RouteStartReference? = nil
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
        self.startHeadingDegrees = startHeadingDegrees
        self.startHeadingAccuracy = startHeadingAccuracy
        self.startHeadingTimestamp = startHeadingTimestamp
        self.startHeadingIsTrueNorth = startHeadingIsTrueNorth
        self.startReference = startReference
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
        startHeadingDegrees = try c.decodeIfPresent(Double.self,       forKey: .startHeadingDegrees)
        startHeadingAccuracy = try c.decodeIfPresent(Double.self,      forKey: .startHeadingAccuracy)
        startHeadingTimestamp = try c.decodeIfPresent(Date.self,       forKey: .startHeadingTimestamp)
        startHeadingIsTrueNorth = try c.decodeIfPresent(Bool.self,     forKey: .startHeadingIsTrueNorth)
        startReference = try c.decodeIfPresent(RouteStartReference.self, forKey: .startReference)
    }

    func geoSample(atProgress progress: Double) -> GeoRouteSample? {
        interpolateGeo(at: progress)
    }

    func localSample(atProgress progress: Double) -> LocalRouteSample? {
        interpolateLocal(at: progress)
    }

    static let defaultRenderableLocalSegmentLimit = 1_500

    var renderLocalTrack: [LocalRouteSample] {
        Self.simplifiedLocalTrack(localTrack, maxSegments: Self.defaultRenderableLocalSegmentLimit)
    }

    static func simplifiedLocalTrack(
        _ samples: [LocalRouteSample],
        maxSegments: Int = defaultRenderableLocalSegmentLimit
    ) -> [LocalRouteSample] {
        guard maxSegments > 0 else { return samples.prefix(1).map { $0 } }
        let maxPoints = maxSegments + 1
        guard samples.count > maxPoints else { return samples }

        var result: [LocalRouteSample] = []
        result.reserveCapacity(maxPoints)
        var lastIndex = -1
        let lastSampleIndex = samples.count - 1
        for outputIndex in 0..<maxPoints {
            let ratio = Double(outputIndex) / Double(maxPoints - 1)
            let index = Int((ratio * Double(lastSampleIndex)).rounded())
            let clampedIndex = min(lastSampleIndex, max(index, lastIndex + 1))
            guard clampedIndex < samples.count else { break }
            result.append(samples[clampedIndex])
            lastIndex = clampedIndex
        }
        if result.last?.id != samples.last?.id {
            result[result.count - 1] = samples[samples.count - 1]
        }
        return result
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

// MARK: - Quest Box

/// A punchable box placed along a route at every 10th coin position.
/// Position is one of 9 grid slots on a vertical plane the runner walks through:
/// 3 columns (left / center / right) × 3 rows (low / mid / high).
struct QuestBox: Codable, Identifiable {
    let id: UUID
    /// Position along the route in [0, 1].
    let routeProgress: Double
    /// Left/right offset from route centerline in meters (negative = left, positive = right).
    let lateralOffsetMeters: Double
    /// Up/down offset from route altitude in meters (negative = low, positive = high).
    let verticalOffsetMeters: Double

    init(routeProgress: Double, lateralOffsetMeters: Double, verticalOffsetMeters: Double) {
        self.id = UUID()
        self.routeProgress = max(0, min(1, routeProgress))
        self.lateralOffsetMeters = lateralOffsetMeters
        self.verticalOffsetMeters = verticalOffsetMeters
    }

    /// Returns the box position in AR local space on the vertical plane the runner walks through.
    /// Lateral offset is applied along the route's right-perpendicular axis so left/right
    /// is always relative to the direction of travel, not world axes.
    func resolvedLocalPosition(on route: RecordedRoute) -> SIMD3<Float>? {
        guard let sample = route.localSample(atProgress: routeProgress) else { return nil }

        // Compute route tangent from adjacent samples
        let epsilon = 0.02
        let prev = route.localSample(atProgress: max(0, routeProgress - epsilon))
        let next = route.localSample(atProgress: min(1, routeProgress + epsilon))

        let tangent: SIMD3<Float>
        if let p = prev, let n = next {
            let dir = SIMD3<Float>(Float(n.x - p.x), 0, Float(n.z - p.z))
            tangent = simd_length(dir) > 0.001 ? simd_normalize(dir) : SIMD3<Float>(1, 0, 0)
        } else {
            tangent = SIMD3<Float>(1, 0, 0)
        }

        // Right-perpendicular in the horizontal plane: cross(up, tangent)
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, tangent))

        let base = SIMD3<Float>(Float(sample.x), Float(sample.y), Float(sample.z))
        return base
            + right * Float(lateralOffsetMeters)
            + up    * Float(verticalOffsetMeters)
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
    /// Punchable boxes placed at every 10th coin position.
    var boxes: [QuestBox]

    var totalItems: Int { items.count }
    var collectedItems: Int { items.filter { $0.collected }.count }
    var totalPoints: Int { items.reduce(0) { $0 + $1.type.pointValue } }
    var collectedPoints: Int { items.filter { $0.collected }.reduce(0) { $0 + $1.type.pointValue } }
    var isComplete: Bool { collectedItems == totalItems }

    init(name: String, routeId: UUID, items: [QuestItem], boxes: [QuestBox] = []) {
        self.id = UUID()
        self.name = name
        self.routeId = routeId
        self.dateCreated = Date()
        self.items = items
        self.boxes = boxes
    }

    // Custom decoder so quests saved before `boxes` was added still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self,        forKey: .id)
        name        = try c.decode(String.self,      forKey: .name)
        routeId     = try c.decode(UUID.self,        forKey: .routeId)
        dateCreated = try c.decode(Date.self,        forKey: .dateCreated)
        items       = try c.decode([QuestItem].self, forKey: .items)
        boxes       = try c.decodeIfPresent([QuestBox].self, forKey: .boxes) ?? []
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
