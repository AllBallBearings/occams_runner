import Foundation
import CoreLocation
import simd

/// Turns a path drawn on a map into a `RecordedRoute` that can back a quest and be run in
/// AR without an ARWorldMap.
///
/// The drawn path is densified to the recording mode's sample spacing, then every point
/// becomes a geo sample and a local sample that share one sample id. The local track is
/// the path itself in east/north metres from the start, in AR axes (x = east,
/// z = -north), all at the start's height (y = 0). Registering that track against its
/// own geo samples (`RouteGeoRegistration`) is exact — zero yaw, zero shift — so the AR
/// runner places a drawn route through GPS and compass exactly as it places a recorded
/// route before ARKit relocalizes.
enum DrawnRouteBuilder {
    /// Consecutive drawn points closer than this are treated as one.
    static let minimumPointSpacingMeters = 0.5
    /// Accuracy assigned to drawn samples: roughly how precisely a path can be laid on a map.
    static let drawnHorizontalAccuracy = 5.0
    static let drawnVerticalAccuracy = 10.0

    /// Builds a route from drawn coordinates, or nil if fewer than two distinct points remain.
    /// - Parameters:
    ///   - startAltitude: altitude in metres given to every geo sample; drawn routes are flat.
    static func makeRoute(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        startAltitude: Double = 0,
        recordingMode: RecordingMode = .vast,
        date: Date = Date()
    ) -> RecordedRoute? {
        let path = removingDuplicates(coordinates)
        guard path.count >= 2 else { return nil }

        let frame = ENUFrame(origin: path[0])
        let enuPath = densify(path.map(frame.enu), maxSpacingMeters: recordingMode.minimumDistance)
        let cumulative = cumulativeDistances(enuPath)
        guard let total = cumulative.last, total > 0 else { return nil }

        var geoTrack: [GeoRouteSample] = []
        var localTrack: [LocalRouteSample] = []
        for (index, point) in enuPath.enumerated() {
            let sampleId = UUID()
            let progress = index == enuPath.count - 1 ? 1 : cumulative[index] / total
            let coordinate = frame.coordinate(point)
            geoTrack.append(GeoRouteSample(
                sampleId: sampleId,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: startAltitude,
                timestamp: date,
                horizontalAccuracy: drawnHorizontalAccuracy,
                verticalAccuracy: drawnVerticalAccuracy,
                progress: progress
            ))
            // Plan (east, north) → AR (x, z) = (east, -north); see PlanarGeo.
            localTrack.append(LocalRouteSample(
                sampleId: sampleId,
                x: point.x,
                y: 0,
                z: -point.y,
                timestamp: date,
                progress: progress,
                trackingScore: 1,
                featurePointCount: 0
            ))
        }

        return RecordedRoute(
            name: name,
            geoTrack: geoTrack,
            localTrack: localTrack,
            checkpoints: [],
            encryptedWorldMapData: nil,
            captureQuality: RouteCaptureQuality(
                matchedSampleRatio: 1,
                averageFeaturePoints: 0,
                averageTrackingScore: 1,
                hasEncryptedWorldMap: false
            ),
            preciseEnabled: false,
            recordingMode: recordingMode,
            source: .drawn,
            dateRecorded: date
        )
    }

    /// Length of a drawn path in metres.
    static func pathLengthMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard let origin = coordinates.first else { return 0 }
        let frame = ENUFrame(origin: origin)
        return cumulativeDistances(coordinates.map(frame.enu)).last ?? 0
    }

    /// Drops points that sit on top of the previous kept point (double taps, a still finger).
    static func removingDuplicates(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }
        let frame = ENUFrame(origin: first)
        var kept = [first]
        var lastENU = SIMD2<Double>.zero
        for coordinate in coordinates.dropFirst() {
            let enu = frame.enu(coordinate)
            guard simd_distance(enu, lastENU) >= minimumPointSpacingMeters else { continue }
            kept.append(coordinate)
            lastENU = enu
        }
        return kept
    }

    /// Inserts evenly spaced points so no two consecutive points are farther apart than
    /// `maxSpacingMeters`. Original points are kept.
    static func densify(_ points: [SIMD2<Double>], maxSpacingMeters: Double) -> [SIMD2<Double>] {
        guard points.count >= 2, maxSpacingMeters > 0 else { return points }
        var result = [points[0]]
        for i in 1..<points.count {
            let from = points[i - 1], to = points[i]
            let steps = Int((simd_distance(from, to) / maxSpacingMeters).rounded(.up))
            if steps > 1 {
                for step in 1..<steps {
                    result.append(from + (to - from) * (Double(step) / Double(steps)))
                }
            }
            result.append(to)
        }
        return result
    }

    private static func cumulativeDistances(_ points: [SIMD2<Double>]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var cumulative = [0.0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + simd_distance(points[i - 1], points[i]))
        }
        return cumulative
    }
}
