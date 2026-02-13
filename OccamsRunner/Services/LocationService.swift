import Foundation
import CoreLocation
import Combine

/// Manages GPS location tracking for recording runs and live quest sessions.
class LocationService: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecording = false
    @Published var recordedPoints: [RoutePoint] = []
    @Published var currentSpeed: Double = 0 // m/s
    @Published var currentAltitude: Double = 0

    private var lastRecordedLocation: CLLocation?
    /// Minimum distance in meters between recorded points to avoid noise
    private let minimumRecordingDistance: Double = 3.0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2.0 // meters
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }

    func startRecording() {
        recordedPoints = []
        lastRecordedLocation = nil
        isRecording = true
        locationManager.startUpdatingLocation()
    }

    func stopRecording() -> [RoutePoint] {
        isRecording = false
        let points = recordedPoints
        return points
    }

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

        // Filter out inaccurate readings
        guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 50 else { return }

        currentLocation = location
        currentSpeed = max(0, location.speed)
        currentAltitude = location.altitude

        if isRecording {
            let shouldRecord: Bool
            if let last = lastRecordedLocation {
                shouldRecord = location.distance(from: last) >= minimumRecordingDistance
            } else {
                shouldRecord = true
            }

            if shouldRecord {
                let point = RoutePoint(from: location)
                recordedPoints.append(point)
                lastRecordedLocation = location
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
