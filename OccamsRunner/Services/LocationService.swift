import Foundation
import CoreLocation
import CoreMotion
import Combine
import ARKit
import CryptoKit
import Security
import simd

// MARK: - Location Service

/// Manages GPS + barometer + AR local-frame capture for dual-track route recording.
class LocationService: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let fileManager = FileManager.default

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecording = false
    @Published var recordedPoints: [RoutePoint] = []
    @Published var currentSpeed: Double = 0
    @Published var currentAltitude: Double = 0
    /// Latest compass heading in degrees, true north preferred. `nil` until the
    /// first heading update arrives (or device has no magnetometer).
    @Published var currentHeadingDegrees: Double?

    @Published var preciseCaptureQuality: RouteCaptureQuality = RouteCaptureQuality(
        matchedSampleRatio: 0,
        averageFeaturePoints: 0,
        averageTrackingScore: 0,
        hasEncryptedWorldMap: false
    )

    @Published var preciseCaptureStatus = "Capture quality too low for precise AR replay yet."
    @Published private(set) var captureDebugLogLines: [String] = []
    @Published private(set) var currentCaptureLogPath: String?

    var canSavePreciseRoute: Bool {
        preciseCaptureQuality.isReadyForPreciseReplay
    }

    /// Human-readable list of unmet conditions blocking the Save button.
    /// Empty string when save is allowed. Shown in the Save Route sheet and
    /// written to the debug log whenever the user attempts to save.
    var saveBlockerDescription: String {
        let q = preciseCaptureQuality
        var lines: [String] = []
        if q.matchedSampleRatio < 0.65 {
            lines.append("• Match \(Int(q.matchedSampleRatio * 100))% — needs ≥65% (GPS↔AR correlation too low)")
        }
        if q.averageFeaturePoints < 75 {
            lines.append("• Features \(Int(q.averageFeaturePoints)) — needs ≥75 (scan more textured surfaces)")
        }
        if q.averageTrackingScore < 0.65 {
            lines.append("• Tracking \(Int(q.averageTrackingScore * 100))% — needs ≥65% (move more slowly)")
        }
        if !q.hasEncryptedWorldMap {
            lines.append("• No world map — AR session hasn't captured one yet (keep recording)")
        }
        return lines.joined(separator: "\n")
    }

    /// Called by the Save button when quality or name validation fails.
    /// Writes a timestamped entry to the debug log so the user can copy and share it.
    func logSaveAttemptBlocked(reasons: [String]) {
        logDebug("SAVE ATTEMPT BLOCKED:")
        for reason in reasons {
            // Log each line of a multi-line blocker description individually
            for line in reason.components(separatedBy: "\n") where !line.isEmpty {
                logDebug("  \(line)")
            }
        }
    }

    /// Public entry-point so AR run-time code (e.g. ARCoordinator) can write
    /// to the same rolling debug log without needing access to the private
    /// `logDebug` implementation.
    func logRunEvent(_ message: String) {
        logDebug(message)
    }

    var captureDebugLogText: String {
        captureDebugLogLines.joined(separator: "\n")
    }

    /// Absolute altitude in metres from GPS anchor + barometric deltas.
    @Published var absoluteAltitude: Double = 0

    // MARK: - Altitude internals

    private var lastBaroReading: Double = 0
    private var gpsAnchor: Double?
    private var baroAtAnchor: Double?

    // MARK: - Recording state

    @Published var recordingMode: RecordingMode = .vast
    private var lastRecordedLocation: CLLocation?
    private var minimumRecordingDistance: Double { recordingMode.minimumDistance }

    private struct GeoDraftSample {
        let sampleId: UUID
        let location: CLLocation
        let absoluteAltitude: Double
        let timestamp: Date
    }

    private struct LocalFrameSample {
        let timestamp: Date
        let position: SIMD3<Float>
        let trackingScore: Double
        let featurePointCount: Int
    }

    private struct LocalDraftSample {
        let sampleId: UUID
        let timestamp: Date
        let position: SIMD3<Float>
        let trackingScore: Double
        let featurePointCount: Int
    }

    private var geoDraftSamples: [GeoDraftSample] = []
    private var localFrameBuffer: [LocalFrameSample] = []
    private var localDraftBySampleId: [UUID: LocalDraftSample] = [:]
    private var lastEncryptedWorldMapData: Data?
    /// Compass heading at recording start. Set in `startRecording()` (or
    /// latched on first heading delivery if CLHeading wasn't ready yet) and
    /// persisted into the saved route for replay-time alignment.
    private var headingAtRecordStart: Double?
    /// AR-world camera yaw (radians, CCW around +Y) at recording start.
    /// Latched together with `headingAtRecordStart` so the seed math at
    /// replay time can recover the relationship between the recording
    /// AR-world frame (whose yaw is set at AR session start, not at
    /// recording start) and true north.
    private var arYawAtRecordStart: Double?
    private var captureLogURL: URL?
    private var lastLoggedQualitySignature: String?
    private let logTimestampFormatter = ISO8601DateFormatter()

    // MARK: - AR precise capture

    private let arSession = ARSession()
    private let arCaptureQueue = DispatchQueue(label: "occamsrunner.precisecapture", qos: .userInitiated)
    private var worldMapTimer: Timer?

    // MARK: - Init

    override init() {
        super.init()
        logTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = RecordingMode.vast.distanceFilter
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = true

        arSession.delegate = self
        arSession.delegateQueue = arCaptureQueue
    }

    // MARK: - Public control

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        resetAltitudeState()
        beginAltimeterUpdates()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
        stopPreciseCapture()
    }

    func startRecording(mode: RecordingMode = .vast) {
        recordingMode = mode
        locationManager.distanceFilter = mode.distanceFilter
        recordedPoints = []
        lastRecordedLocation = nil
        isRecording = true

        geoDraftSamples = []
        localFrameBuffer = []
        localDraftBySampleId = [:]
        lastEncryptedWorldMapData = nil
        headingAtRecordStart = currentHeadingDegrees
        arYawAtRecordStart = currentARWorldYaw()

        preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0,
            averageFeaturePoints: 0,
            averageTrackingScore: 0,
            hasEncryptedWorldMap: false
        )
        preciseCaptureStatus = "Scanning environment for precise AR capture..."
        prepareCaptureLogSession(mode: mode)
        logDebug("Thresholds: match>=65%, features>=75, tracking>=65%, worldMap=true")

        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        altimeter.stopRelativeAltitudeUpdates()
        resetAltitudeState()
        beginAltimeterUpdates()
        startPreciseCapture()
    }

    /// Stops active capture streams. Route construction is done by `buildRecordedRoute(name:)`.
    func stopRecording() {
        isRecording = false
        // Invalidate the periodic timer before taking the final snapshot so both
        // don't call getCurrentWorldMap concurrently.
        worldMapTimer?.invalidate()
        worldMapTimer = nil
        logDebug("Recording stopped by user. geoSamples=\(geoDraftSamples.count), matchedLocal=\(localDraftBySampleId.count)")
        captureWorldMapSnapshot()
        stopPreciseCapture()
    }

    func buildRecordedRoute(name: String) -> RecordedRoute? {
        guard geoDraftSamples.count >= 2 else {
            preciseCaptureStatus = "Need at least 2 geo samples to save route."
            logDebug("Save blocked: only \(geoDraftSamples.count) geo samples")
            return nil
        }

        // Build geo track with route-relative progress.
        var geoTrack: [GeoRouteSample] = []
        var cumulativeDistances: [Double] = [0]
        var totalDistance: Double = 0

        for i in 1..<geoDraftSamples.count {
            totalDistance += geoDraftSamples[i].location.distance(from: geoDraftSamples[i - 1].location)
            cumulativeDistances.append(totalDistance)
        }

        for (idx, draft) in geoDraftSamples.enumerated() {
            let progress = totalDistance > 0 ? (cumulativeDistances[idx] / totalDistance) : 0
            let sample = GeoRouteSample(
                sampleId: draft.sampleId,
                latitude: draft.location.coordinate.latitude,
                longitude: draft.location.coordinate.longitude,
                altitude: draft.absoluteAltitude,
                timestamp: draft.timestamp,
                horizontalAccuracy: max(0, draft.location.horizontalAccuracy),
                verticalAccuracy: max(0, draft.location.verticalAccuracy),
                progress: progress
            )
            geoTrack.append(sample)
        }

        // Build local track correlated by sampleId from geo samples.
        var localTrack: [LocalRouteSample] = []
        for geo in geoTrack {
            guard let local = localDraftBySampleId[geo.sampleId] else { continue }
            localTrack.append(
                LocalRouteSample(
                    sampleId: local.sampleId,
                    x: Double(local.position.x),
                    y: Double(local.position.y),
                    z: Double(local.position.z),
                    timestamp: local.timestamp,
                    progress: geo.progress,
                    trackingScore: local.trackingScore,
                    featurePointCount: local.featurePointCount
                )
            )
        }

        // Build checkpoints at start/middle/end local samples.
        let checkpoints = buildCheckpoints(localTrack: localTrack)

        let avgFeaturePoints = localTrack.isEmpty
            ? 0
            : Double(localTrack.reduce(0) { $0 + $1.featurePointCount }) / Double(localTrack.count)

        let avgTracking = localTrack.isEmpty
            ? 0
            : localTrack.reduce(0) { $0 + $1.trackingScore } / Double(localTrack.count)

        let quality = RouteCaptureQuality(
            matchedSampleRatio: Double(localTrack.count) / Double(max(1, geoTrack.count)),
            averageFeaturePoints: avgFeaturePoints,
            averageTrackingScore: avgTracking,
            hasEncryptedWorldMap: lastEncryptedWorldMapData != nil
        )

        preciseCaptureQuality = quality
        logQualitySnapshotIfNeeded(context: "save-attempt")

        guard quality.isReadyForPreciseReplay else {
            preciseCaptureStatus = "Capture quality is below threshold for precise AR replay."
            logDebug("Save blocked by quality gate")
            return nil
        }

        preciseCaptureStatus = "Capture quality passed. Route is ready for precise replay."
        logDebug("Route saved as precise-ready. name=\(name), geoSamples=\(geoTrack.count), localSamples=\(localTrack.count)")
        finalizeCaptureLogSession(reason: "saved")

        return RecordedRoute(
            name: name,
            geoTrack: geoTrack,
            localTrack: localTrack,
            checkpoints: checkpoints,
            encryptedWorldMapData: lastEncryptedWorldMapData,
            captureQuality: quality,
            preciseEnabled: true,
            recordingMode: recordingMode,
            recordedHeadingDegrees: headingAtRecordStart,
            recordedCameraYawAR: arYawAtRecordStart,
            // Auto-flag: if ARKit was struggling during recording (low light,
            // texture-poor surroundings), localTrack is too unreliable to
            // drive item placement at replay. The flag biases replay toward
            // GPS-primary positioning, which doesn't depend on visual
            // feature continuity at all.
            useGPSPrimary: quality.localTrackUnreliable ? true : nil
        )
    }

    // MARK: - Altitude

    private func resetAltitudeState() {
        gpsAnchor = nil
        baroAtAnchor = nil
        lastBaroReading = 0
        absoluteAltitude = 0
    }

    private func beginAltimeterUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            self.lastBaroReading = data.relativeAltitude.doubleValue
            self.recomputeAbsoluteAltitude()
            self.currentAltitude = self.absoluteAltitude
        }
    }

    private func recomputeAbsoluteAltitude() {
        if let anchor = gpsAnchor, let baroBase = baroAtAnchor {
            absoluteAltitude = anchor + (lastBaroReading - baroBase)
        } else if let loc = currentLocation, loc.verticalAccuracy > 0 {
            absoluteAltitude = loc.altitude
        }
    }

    // MARK: - Quest helpers

    func distanceToItem(_ item: QuestItem, route: RecordedRoute) -> Double? {
        guard let current = currentLocation,
              let itemLocation = item.resolvedGeoLocation(on: route) else { return nil }
        return current.distance(from: itemLocation)
    }

    func isWithinCollectionRange(of item: QuestItem, on route: RecordedRoute) -> Bool {
        guard let distance = distanceToItem(item, route: route) else { return false }
        return distance <= QuestItem.collectionRadiusMeters
    }

    // MARK: - World Map decrypt for replay

    func decryptWorldMapData(_ encryptedData: Data) -> Data? {
        RouteCrypto.decrypt(encryptedData)
    }

    // MARK: - Precise capture internals

    private func prepareCaptureLogSession(mode: RecordingMode) {
        captureDebugLogLines = []
        lastLoggedQualitySignature = nil

        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            captureLogURL = nil
            currentCaptureLogPath = nil
            return
        }

        let logsDir = docs.appendingPathComponent("capture-logs", isDirectory: true)
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let stamp = logTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = logsDir.appendingPathComponent("capture-\(stamp).log")
        fileManager.createFile(atPath: url.path, contents: nil)
        captureLogURL = url
        currentCaptureLogPath = url.path

        logDebug("SESSION START mode=\(mode.rawValue)")
    }

    private func finalizeCaptureLogSession(reason: String) {
        logDebug("SESSION END reason=\(reason)")
    }

    private func logDebug(_ message: String) {
        let line = "[\(logTimestampFormatter.string(from: Date()))] \(message)"

        DispatchQueue.main.async {
            self.captureDebugLogLines.append(line)
            if self.captureDebugLogLines.count > 500 {
                self.captureDebugLogLines.removeFirst(self.captureDebugLogLines.count - 500)
            }
        }

        appendLineToCaptureLogFile(line)
        print("CaptureDebug \(line)")
    }

    private func appendLineToCaptureLogFile(_ line: String) {
        guard let url = captureLogURL else { return }
        let payload = Data((line + "\n").utf8)

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: payload)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { handle.closeFile() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            // Ignore log write failures; they should never block capture.
        }
    }

    private func logQualitySnapshotIfNeeded(context: String) {
        let q = preciseCaptureQuality
        let signature = [
            String(Int(q.matchedSampleRatio * 100)),
            String(Int(q.averageFeaturePoints)),
            String(Int(q.averageTrackingScore * 100)),
            q.hasEncryptedWorldMap ? "1" : "0",
            q.isReadyForPreciseReplay ? "1" : "0",
            preciseCaptureStatus
        ].joined(separator: "|")

        guard signature != lastLoggedQualitySignature else { return }
        lastLoggedQualitySignature = signature

        var blockers: [String] = []
        if q.matchedSampleRatio < 0.65 { blockers.append("low_match") }
        if q.averageFeaturePoints < 75  { blockers.append("low_features") }
        if q.averageTrackingScore < 0.65 { blockers.append("low_tracking") }
        if !q.hasEncryptedWorldMap { blockers.append("missing_world_map") }
        if blockers.isEmpty { blockers = ["none"] }

        logDebug(
            "\(context) quality: match=\(Int(q.matchedSampleRatio * 100))% " +
            "features=\(Int(q.averageFeaturePoints)) " +
            "tracking=\(Int(q.averageTrackingScore * 100))% " +
            "worldMap=\(q.hasEncryptedWorldMap ? "yes" : "no") " +
            "ready=\(q.isReadyForPreciseReplay ? "yes" : "no") " +
            "blockers=\(blockers.joined(separator: ","))"
        )
    }

    private func startPreciseCapture() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.environmentTexturing = .none

        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        logDebug("AR precise capture started")

        worldMapTimer?.invalidate()
        worldMapTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.captureWorldMapSnapshot()
        }
        RunLoop.main.add(worldMapTimer!, forMode: .common)
    }

    private func stopPreciseCapture() {
        worldMapTimer?.invalidate()
        worldMapTimer = nil
        arSession.pause()
        logDebug("AR precise capture paused")
    }

    private func captureWorldMapSnapshot() {
        arSession.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            guard error == nil, let worldMap else { return }
            do {
                let archived = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                self.lastEncryptedWorldMapData = RouteCrypto.encrypt(archived)
                DispatchQueue.main.async {
                    self.logDebug("World map snapshot captured (\(archived.count) bytes, encrypted=\(self.lastEncryptedWorldMapData != nil))")
                    self.recomputeCaptureQuality()
                }
            } catch {
                // Keep previous valid map snapshot if current archive fails.
                DispatchQueue.main.async {
                    self.logDebug("World map snapshot archive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func nearestLocalFrame(to timestamp: Date, tolerance: TimeInterval = 0.35) -> LocalFrameSample? {
        guard !localFrameBuffer.isEmpty else { return nil }
        var best: LocalFrameSample?
        var bestDelta = TimeInterval.greatestFiniteMagnitude

        for frame in localFrameBuffer {
            let delta = abs(frame.timestamp.timeIntervalSince(timestamp))
            if delta < bestDelta {
                bestDelta = delta
                best = frame
            }
        }

        guard bestDelta <= tolerance else { return nil }
        return best
    }

    private func recomputeCaptureQuality() {
        let matched = localDraftBySampleId.count
        let total = max(1, geoDraftSamples.count)

        let avgFeature: Double
        let avgTracking: Double

        if localDraftBySampleId.isEmpty {
            avgFeature = 0
            avgTracking = 0
        } else {
            let values = Array(localDraftBySampleId.values)
            avgFeature = Double(values.reduce(0) { $0 + $1.featurePointCount }) / Double(values.count)
            avgTracking = values.reduce(0) { $0 + $1.trackingScore } / Double(values.count)
        }

        preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: Double(matched) / Double(total),
            averageFeaturePoints: avgFeature,
            averageTrackingScore: avgTracking,
            hasEncryptedWorldMap: lastEncryptedWorldMapData != nil
        )

        if preciseCaptureQuality.isReadyForPreciseReplay {
            preciseCaptureStatus = "Precise replay ready."
        } else {
            preciseCaptureStatus = "Keep moving and scanning textured areas to improve precision."
        }

        logQualitySnapshotIfNeeded(context: "live")
    }

    private func buildCheckpoints(localTrack: [LocalRouteSample]) -> [RouteCheckpoint] {
        guard !localTrack.isEmpty else { return [] }

        let checkpointIndices: [Int] = [
            0,
            localTrack.count / 2,
            max(0, localTrack.count - 1)
        ]

        let labels = ["START", "MID", "END"]
        var seen: Set<UUID> = []
        var result: [RouteCheckpoint] = []

        for (idx, index) in checkpointIndices.enumerated() {
            guard index < localTrack.count else { continue }
            let sample = localTrack[index]
            guard !seen.contains(sample.sampleId) else { continue }
            seen.insert(sample.sampleId)

            result.append(
                RouteCheckpoint(
                    id: UUID(),
                    sampleId: sample.sampleId,
                    progress: sample.progress,
                    timestamp: sample.timestamp,
                    label: labels[min(idx, labels.count - 1)],
                    featurePointCount: sample.featurePointCount
                )
            )
        }

        return result
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 50 else { return }

        currentLocation = location
        currentSpeed = max(0, location.speed)

        if gpsAnchor == nil,
           location.verticalAccuracy > 0,
           location.verticalAccuracy < 20 {
            gpsAnchor = location.altitude
            baroAtAnchor = lastBaroReading
            recomputeAbsoluteAltitude()
        }

        guard isRecording else { return }

        // Discard stale cached fixes that iOS delivers as a burst when recording starts.
        // A fix whose timestamp is more than 1 second old at the moment it arrives
        // cannot be correlated to a current AR frame, which unfairly deflates the
        // matched-sample ratio. Fresh fixes (age ≤ 1 s) are always accepted.
        let fixAge = Date().timeIntervalSince(location.timestamp)
        guard fixAge <= 1.0 else { return }

        let shouldRecord: Bool
        if let last = lastRecordedLocation {
            shouldRecord = location.distance(from: last) >= minimumRecordingDistance
        } else {
            shouldRecord = true
        }

        guard shouldRecord else { return }

        let sampleId = UUID()

        let point = RoutePoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: absoluteAltitude,
            timestamp: location.timestamp
        )
        recordedPoints.append(point)

        geoDraftSamples.append(
            GeoDraftSample(
                sampleId: sampleId,
                location: location,
                absoluteAltitude: absoluteAltitude,
                timestamp: location.timestamp
            )
        )

        if let localFrame = nearestLocalFrame(to: location.timestamp) {
            localDraftBySampleId[sampleId] = LocalDraftSample(
                sampleId: sampleId,
                timestamp: localFrame.timestamp,
                position: localFrame.position,
                trackingScore: localFrame.trackingScore,
                featurePointCount: localFrame.featurePointCount
            )
        }

        if geoDraftSamples.count <= 5 || geoDraftSamples.count % 10 == 0 {
            let matched = localDraftBySampleId[sampleId] != nil
            logDebug(
                "geoSample #\(geoDraftSamples.count) " +
                "hAcc=\(Int(location.horizontalAccuracy))m " +
                "vAcc=\(Int(max(0, location.verticalAccuracy)))m " +
                "matchedLocal=\(matched ? "yes" : "no")"
            )
        }

        lastRecordedLocation = location
        recomputeCaptureQuality()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logDebug("Location error: \(error.localizedDescription)")
        print("Location error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true (geographic) north; fall back to magnetic if true north
        // isn't yet calibrated (CLHeading returns -1 in that case).
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }

        // Dedupe sub-degree updates so SwiftUI consumers don't re-render at
        // 10+ Hz when the user's facing direction is essentially unchanged.
        if let prev = currentHeadingDegrees, abs(prev - heading) < 0.5 { return }
        currentHeadingDegrees = heading

        // Latch the first heading after recording starts. Avoids missing the
        // record-start moment if CLHeading hadn't fired yet at that point.
        // Latch the AR-world camera yaw at the same moment so the recording
        // frame ↔ true-north relationship is recoverable at replay time.
        if isRecording, headingAtRecordStart == nil {
            headingAtRecordStart = heading
            arYawAtRecordStart = currentARWorldYaw()
        }
    }

    /// Returns the AR-world camera yaw (CCW around +Y, radians) from the most
    /// recent ARFrame, or `nil` if no frame is available yet. Same convention
    /// used by `ARCoordinator.seedAlignmentFromGPSHeading`.
    private func currentARWorldYaw() -> Double? {
        guard let cam = arSession.currentFrame?.camera.transform else { return nil }
        // Camera looks along its -Z axis. Flatten the forward into the XZ
        // plane and recover yaw via atan2.
        let fx = -cam.columns.2.x
        let fz = -cam.columns.2.z
        let length = (fx * fx + fz * fz).squareRoot()
        guard length > 1e-4 else { return nil }
        let nx = fx / length
        let nz = fz / length
        return Double(atan2(-nx, -nz))
    }
}

// MARK: - ARSessionDelegate

extension LocationService: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let featureCount = frame.rawFeaturePoints?.points.count ?? 0
        let tracking = trackingScore(frame.camera.trackingState)

        let sample = LocalFrameSample(
            // ARFrame timestamp is not wall-clock time; use capture receipt time
            // so correlation with CLLocation timestamps remains meaningful.
            timestamp: Date(),
            position: position,
            trackingScore: tracking,
            featurePointCount: featureCount
        )

        DispatchQueue.main.async {
            self.localFrameBuffer.append(sample)
            if self.localFrameBuffer.count > 900 {
                self.localFrameBuffer.removeFirst(self.localFrameBuffer.count - 900)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.preciseCaptureStatus = "AR capture unavailable: \(error.localizedDescription)"
            self.logDebug("AR session failed: \(error.localizedDescription)")
        }
    }

    private func trackingScore(_ state: ARCamera.TrackingState) -> Double {
        switch state {
        case .normal:
            return 1.0
        case .limited(let reason):
            switch reason {
            case .initializing:
                return 0.35
            case .excessiveMotion:
                return 0.45
            case .insufficientFeatures:
                return 0.25
            case .relocalizing:
                return 0.55
            @unknown default:
                return 0.3
            }
        case .notAvailable:
            return 0.0
        }
    }
}

// MARK: - Local crypto helper

private enum RouteCrypto {
    private static let fallbackDefaultsKey = "occamsrunner.preciseRouteCryptoKeyBase64"

    static func encrypt(_ plaintext: Data) -> Data? {
        guard let key = loadOrCreateKey() else { return nil }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            return sealed.combined
        } catch {
            print("RouteCrypto encrypt error: \(error.localizedDescription)")
            return nil
        }
    }

    static func decrypt(_ ciphertext: Data) -> Data? {
        guard let key = loadOrCreateKey() else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            print("RouteCrypto decrypt error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        if let keyData = loadKeyDataFromKeychain() {
            return SymmetricKey(data: keyData)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        if storeKeyDataInKeychain(keyData) {
            return key
        }

        // Fallback for environments where Keychain write is unavailable.
        let base64 = keyData.base64EncodedString()
        UserDefaults.standard.set(base64, forKey: fallbackDefaultsKey)
        print("RouteCrypto: fell back to UserDefaults key storage")
        return key
    }

    private static func loadKeyDataFromKeychain() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "route-key",
            kSecAttrService: "com.occamsrunner",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }

        if let base64 = UserDefaults.standard.string(forKey: fallbackDefaultsKey),
           let data = Data(base64Encoded: base64) {
            return data
        }

        if status != errSecItemNotFound {
            print("RouteCrypto keychain load failed: \(status)")
        }
        return nil
    }

    private static func storeKeyDataInKeychain(_ data: Data) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "route-key",
            kSecAttrService: "com.occamsrunner",
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("RouteCrypto keychain store failed: \(status)")
        }
        return status == errSecSuccess
    }
}
