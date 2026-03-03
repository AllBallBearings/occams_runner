import Foundation
import CoreLocation
import CoreMotion
import Combine

/// Manages GPS location tracking and altitude for recording runs and live quest sessions.
class LocationService: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecording = false
    @Published var recordedPoints: [RoutePoint] = []
    @Published var currentSpeed: Double = 0
    @Published var currentAltitude: Double = 0

    /// Absolute altitude in metres.
    ///
    /// GPS provides the global anchor (which floor / elevation you're actually at);
    /// the barometer tracks precise changes from that anchor (~30 cm resolution).
    /// Computed as: `gpsAnchor + (currentBaro - baroAtAnchor)`
    ///
    /// This is consistent across separate sessions at the same location, so a
    /// route recorded starting on floor 3 and replayed starting on floor 1 still
    /// positions coins at the correct absolute heights.
    @Published var absoluteAltitude: Double = 0

    // MARK: - Altitude internals

    /// Raw cumulative barometric reading from CMAltimeter (resets each session).
    private var lastBaroReading: Double = 0
    /// GPS altitude captured on the first good vertical fix this session.
    private var gpsAnchor: Double?
    /// Barometric reading at the moment gpsAnchor was captured.
    private var baroAtAnchor: Double?

    // MARK: - Recording

    private var lastRecordedLocation: CLLocation?
    /// 5 feet in metres — enough resolution for stairs and tight indoor paths.
    private let minimumRecordingDistance: Double = 1.524

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        // BestForNavigation activates all sensors including baro-assisted GPS.
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Fire every 0.5 m so we never skip past a 5-ft recording interval.
        locationManager.distanceFilter = 0.5
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    // MARK: - Public control

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
        resetAltitudeState()
        beginAltimeterUpdates()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
    }

    func startRecording() {
        recordedPoints = []
        lastRecordedLocation = nil
        isRecording = true
        locationManager.startUpdatingLocation()
        // Reset altitude state so the GPS anchor is re-captured at the recording
        // start location, giving a fresh absolute reference for this route.
        altimeter.stopRelativeAltitudeUpdates()
        resetAltitudeState()
        beginAltimeterUpdates()
    }

    func stopRecording() -> [RoutePoint] {
        isRecording = false
        return recordedPoints
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
            // GPS-anchored absolute altitude refined by precise barometric changes.
            // The baro resolves ~30 cm per step; GPS keeps it tied to real-world height.
            absoluteAltitude = anchor + (lastBaroReading - baroBase)
        } else if let loc = currentLocation, loc.verticalAccuracy > 0 {
            // Fallback: raw GPS altitude while waiting for a good vertical fix.
            absoluteAltitude = loc.altitude
        }
    }

    // MARK: - Quest helpers

    func distanceToItem(_ item: QuestItem) -> Double? {
        guard let current = currentLocation else { return nil }
        return current.distance(from: item.location)
    }

    func isWithinCollectionRange(of item: QuestItem) -> Bool {
        guard let distance = distanceToItem(item) else { return false }
        return distance <= QuestItem.collectionRadiusMeters
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

        // Capture the GPS anchor on the first reading with acceptable vertical accuracy.
        // verticalAccuracy < 20 m is "usable" — the barometer then takes over for
        // floor-level precision from this anchor point onward.
        if gpsAnchor == nil,
           location.verticalAccuracy > 0,
           location.verticalAccuracy < 20 {
            gpsAnchor = location.altitude
            baroAtAnchor = lastBaroReading
            recomputeAbsoluteAltitude()
        }

        if isRecording {
            let shouldRecord: Bool
            if let last = lastRecordedLocation {
                shouldRecord = location.distance(from: last) >= minimumRecordingDistance
            } else {
                shouldRecord = true
            }

            if shouldRecord {
                // Store GPS-anchored, baro-refined absolute altitude.
                // Floor 3 will be ~18 m, floor 1 ~6 m — consistent across sessions.
                let point = RoutePoint(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: absoluteAltitude,
                    timestamp: location.timestamp
                )
                recordedPoints.append(point)
                lastRecordedLocation = location
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
