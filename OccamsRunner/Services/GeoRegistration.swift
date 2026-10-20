import Foundation
import CoreLocation
import CoreMotion
import simd

// MARK: - Planar Conventions
//
// All registration math happens in a 2D "plan" frame: x = east-like, y = north-like,
// angles counter-clockwise in radians. ARKit world points (x right, y up, z toward the
// viewer) enter the plan frame as (x, -z). A counter-clockwise plan rotation by `a`
// equals a SceneKit rotation of `a` about +Y, so a fitted yaw can be applied to a node
// directly.

enum PlanarGeo {
    static let earthRadiusMeters = 6_371_000.0

    static func plan(fromAR p: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2(Double(p.x), Double(-p.z))
    }

    static func arXZ(fromPlan p: SIMD2<Double>) -> SIMD2<Float> {
        SIMD2(Float(p.x), Float(-p.y))
    }

    /// Wraps an angle into (-pi, pi].
    static func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        if a > .pi { a -= 2 * .pi }
        return a
    }

    static func rotate(_ p: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y)
    }
}

/// Local east/north tangent plane around an origin coordinate. Accurate to centimetres
/// over the few-kilometre extent of a run.
struct ENUFrame {
    let origin: CLLocationCoordinate2D

    func enu(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        let lat0 = origin.latitude * .pi / 180
        let east = (coordinate.longitude - origin.longitude) * .pi / 180
            * cos(lat0) * PlanarGeo.earthRadiusMeters
        let north = (coordinate.latitude - origin.latitude) * .pi / 180
            * PlanarGeo.earthRadiusMeters
        return SIMD2(east, north)
    }

    func coordinate(_ enu: SIMD2<Double>) -> CLLocationCoordinate2D {
        let lat0 = origin.latitude * .pi / 180
        let lat = origin.latitude + enu.y / PlanarGeo.earthRadiusMeters * 180 / .pi
        let lon = origin.longitude
            + enu.x / (PlanarGeo.earthRadiusMeters * cos(lat0)) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Rigid 2D transform: rotate by `yaw`, then translate.
struct PlanarTransform: Equatable {
    var yaw: Double
    var translation: SIMD2<Double>

    static let identity = PlanarTransform(yaw: 0, translation: .zero)

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        PlanarGeo.rotate(p, by: yaw) + translation
    }

    var inverse: PlanarTransform {
        PlanarTransform(yaw: -yaw, translation: -PlanarGeo.rotate(translation, by: -yaw))
    }

    /// `other ∘ self`: applies `self` first, then `other`.
    func then(_ other: PlanarTransform) -> PlanarTransform {
        PlanarTransform(
            yaw: PlanarGeo.normalizeAngle(yaw + other.yaw),
            translation: PlanarGeo.rotate(translation, by: other.yaw) + other.translation
        )
    }
}

// MARK: - Weighted Rigid Fit

struct WeightedPair {
    let source: SIMD2<Double>
    let target: SIMD2<Double>
    let weight: Double
}

enum RigidFit {
    struct Result {
        let transform: PlanarTransform
        /// Weighted RMS of target - transform(source).
        let rmsResidual: Double
        /// Weighted RMS distance of the sources from their centroid. Yaw is only
        /// observable when this is a few metres or more.
        let spread: Double
        let sourceCentroid: SIMD2<Double>
        let count: Int
    }

    /// Closed-form weighted least-squares rotation + translation (2D Kabsch).
    /// With `fixedYaw`, only the translation is solved.
    static func fit(_ pairs: [WeightedPair], fixedYaw: Double? = nil) -> Result? {
        let totalWeight = pairs.reduce(0) { $0 + $1.weight }
        guard !pairs.isEmpty, totalWeight > 0 else { return nil }

        let sourceCentroid = pairs.reduce(SIMD2<Double>.zero) { $0 + $1.source * $1.weight } / totalWeight
        let targetCentroid = pairs.reduce(SIMD2<Double>.zero) { $0 + $1.target * $1.weight } / totalWeight

        let yaw: Double
        if let fixedYaw {
            yaw = fixedYaw
        } else {
            guard pairs.count >= 2 else { return nil }
            var sinSum = 0.0, cosSum = 0.0
            for pair in pairs {
                let s = pair.source - sourceCentroid
                let t = pair.target - targetCentroid
                sinSum += pair.weight * (s.x * t.y - s.y * t.x)
                cosSum += pair.weight * (s.x * t.x + s.y * t.y)
            }
            guard abs(sinSum) + abs(cosSum) > 1e-9 else { return nil }
            yaw = atan2(sinSum, cosSum)
        }

        let translation = targetCentroid - PlanarGeo.rotate(sourceCentroid, by: yaw)
        let transform = PlanarTransform(yaw: yaw, translation: translation)

        var residualSum = 0.0, spreadSum = 0.0
        for pair in pairs {
            residualSum += pair.weight * simd_length_squared(pair.target - transform.apply(pair.source))
            spreadSum += pair.weight * simd_length_squared(pair.source - sourceCentroid)
        }

        return Result(
            transform: transform,
            rmsResidual: sqrt(residualSum / totalWeight),
            spread: sqrt(spreadSum / totalWeight),
            sourceCentroid: sourceCentroid,
            count: pairs.count
        )
    }

    /// Fits, drops pairs whose residual is far beyond the typical one (GPS multipath
    /// jumps), and refits on the inliers.
    static func robustFit(_ pairs: [WeightedPair], fixedYaw: Double? = nil) -> Result? {
        guard let first = fit(pairs, fixedYaw: fixedYaw), pairs.count >= 4 else {
            return fit(pairs, fixedYaw: fixedYaw)
        }
        let residuals = pairs.map { simd_length($0.target - first.transform.apply($0.source)) }
        let median = residuals.sorted()[residuals.count / 2]
        let threshold = max(3 * median, 6)
        let inliers = zip(pairs, residuals).filter { $0.1 <= threshold }.map(\.0)
        guard inliers.count >= max(3, pairs.count / 2), inliers.count < pairs.count else {
            return first
        }
        return fit(inliers, fixedYaw: fixedYaw) ?? first
    }

    /// One-sigma yaw uncertainty (radians) of a fit. GPS errors are strongly
    /// correlated over a few seconds, so only every ~4th sample counts as independent.
    static func yawSigma(of result: Result, positionSigma: Double) -> Double {
        guard result.count >= 3, result.spread >= 4 else { return .pi }
        let effectiveCount = max(1.0, Double(result.count) / 4)
        let sigma = max(positionSigma, result.rmsResidual) / (result.spread * sqrt(effectiveCount))
        return min(.pi, max(sigma, 1.0 * .pi / 180))
    }
}

// MARK: - Angle Fusion

enum AngleFusion {
    struct Estimate {
        let angle: Double
        let sigma: Double
    }

    /// Inverse-variance weighted circular mean.
    static func fuse(_ estimates: [Estimate]) -> Estimate? {
        var sinSum = 0.0, cosSum = 0.0, weightSum = 0.0
        for e in estimates where e.sigma < .pi {
            let w = 1 / (e.sigma * e.sigma)
            sinSum += w * sin(e.angle)
            cosSum += w * cos(e.angle)
            weightSum += w
        }
        guard weightSum > 0 else { return nil }
        return Estimate(angle: atan2(sinSum, cosSum), sigma: 1 / sqrt(weightSum))
    }
}

/// Running circular mean of angle samples (radians).
struct CircularMean: Codable, Equatable {
    private(set) var sinSum = 0.0
    private(set) var cosSum = 0.0
    private(set) var count = 0

    mutating func add(_ angle: Double) {
        sinSum += sin(angle)
        cosSum += cos(angle)
        count += 1
    }

    var mean: Double? {
        guard count > 0 else { return nil }
        return atan2(sinSum, cosSum)
    }

    /// Mean resultant length in [0, 1]; 1 means every sample agreed.
    var consistency: Double {
        guard count > 0 else { return 0 }
        return sqrt(sinSum * sinSum + cosSum * cosSum) / Double(count)
    }

    /// Circular standard deviation of the samples (radians).
    var spreadSigma: Double {
        let r = consistency
        guard r > 1e-6 else { return .pi }
        return min(.pi, sqrt(-2 * log(r)))
    }
}

// MARK: - Compass

enum CompassMath {
    /// Magnetometer heading has a site-dependent bias (rebar, cars, phone cases) that
    /// averaging does not remove, so a compass yaw is never trusted beyond this.
    static let biasFloorSigma = 8.0 * .pi / 180

    /// Heading of the back camera in degrees clockwise from north, from a
    /// `CMAttitude.rotationMatrix` in an `xNorthZVertical` reference frame
    /// (reference axes: X north, Y west, Z up; the matrix maps reference to device).
    /// Nil when the camera points too steeply up or down for a meaningful heading.
    static func backCameraHeadingDegrees(m31: Double, m32: Double) -> Double? {
        // Back camera = device -Z; in reference coordinates that is -(row 3).
        let north = -m31
        let east = m32  // west component is -m32
        guard hypot(north, east) > 0.35 else { return nil }
        let degrees = atan2(east, north) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Rotation (radians, CCW) taking AR plan directions to east/north directions,
    /// given the compass heading of the camera and its forward vector in plan coordinates.
    static func arToENUYaw(headingDegrees: Double, cameraForwardPlan: SIMD2<Double>) -> Double? {
        guard simd_length(cameraForwardPlan) > 0.3 else { return nil }
        let arAngle = atan2(cameraForwardPlan.y, cameraForwardPlan.x)
        let enuAngle = (90 - headingDegrees) * .pi / 180
        return PlanarGeo.normalizeAngle(enuAngle - arAngle)
    }

    /// Camera forward (-Z column) of an ARKit camera transform, in plan coordinates.
    static func cameraForwardPlan(_ transform: simd_float4x4) -> SIMD2<Double> {
        SIMD2(Double(-transform.columns.2.x), Double(transform.columns.2.z))
    }
}

/// Publishes the back-camera compass heading from Core Motion's fused attitude, which —
/// unlike `CLHeading` — is well defined when the phone is held upright for AR.
final class CompassHeadingProvider {
    struct Reading {
        let degrees: Double
        /// Seconds since boot; same clock as `ARFrame.timestamp`.
        let timestamp: TimeInterval
    }

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var latest: Reading?

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    deinit { stop() }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let reference: CMAttitudeReferenceFrame
        if frames.contains(.xTrueNorthZVertical) {
            reference = .xTrueNorthZVertical
        } else if frames.contains(.xMagneticNorthZVertical) {
            reference = .xMagneticNorthZVertical
        } else {
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: reference, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let m = motion.attitude.rotationMatrix
            guard let degrees = CompassMath.backCameraHeadingDegrees(m31: m.m31, m32: m.m32) else { return }
            self.lock.lock()
            self.latest = Reading(degrees: degrees, timestamp: motion.timestamp)
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock()
        latest = nil
        lock.unlock()
    }

    var latestReading: Reading? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Yaw from the AR frame to east/north for this camera pose, if a fresh heading exists.
    func arToENUYaw(cameraTransform: simd_float4x4, frameTimestamp: TimeInterval) -> Double? {
        guard let reading = latestReading,
              abs(reading.timestamp - frameTimestamp) < 0.2 else { return nil }
        return CompassMath.arToENUYaw(
            headingDegrees: reading.degrees,
            cameraForwardPlan: CompassMath.cameraForwardPlan(cameraTransform)
        )
    }
}

// MARK: - Recorded Route → Earth

/// Registers a recorded route's AR track to the earth by fitting one rigid transform
/// through every GPS fix paired with an AR position, plus the compass yaw averaged over
/// the recording. Dozens of fixes pin the route far tighter than its first fix alone,
/// which is often the worst fix of the run because GPS is still settling.
struct RouteGeoRegistration {
    let frame: ENUFrame
    /// Maps recording-space plan coordinates to east/north metres in `frame`.
    let localToENU: PlanarTransform
    let yawSigma: Double
    /// One-sigma uncertainty of the route start's earth position, metres.
    let startSigmaMeters: Double
    /// AR position of the route start in recording space.
    let localStart: SIMD3<Float>
    let gpsPairCount: Int

    var startENU: SIMD2<Double> {
        localToENU.apply(PlanarGeo.plan(fromAR: localStart))
    }

    var startCoordinate: CLLocationCoordinate2D {
        frame.coordinate(startENU)
    }

    var startLocation: CLLocation {
        let coordinate = startCoordinate
        return CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: startSigmaMeters,
            verticalAccuracy: -1,
            timestamp: Date()
        )
    }

    init?(route: RecordedRoute) {
        guard let firstGeo = route.geoTrack.first,
              let firstLocal = route.localTrack.first else { return nil }

        frame = ENUFrame(origin: firstGeo.coordinate)
        localStart = SIMD3(Float(firstLocal.x), Float(firstLocal.y), Float(firstLocal.z))

        let geoById = Dictionary(route.geoTrack.map { ($0.sampleId, $0) }, uniquingKeysWith: { a, _ in a })
        var pairs: [WeightedPair] = []
        var accuracySquares: [Double] = []
        for local in route.localTrack {
            guard let geo = geoById[local.sampleId] else { continue }
            let accuracy = max(geo.horizontalAccuracy, 3)
            pairs.append(WeightedPair(
                source: SIMD2(local.x, -local.z),
                target: frame.enu(geo.coordinate),
                weight: 1 / (accuracy * accuracy)
            ))
            accuracySquares.append(accuracy * accuracy)
        }
        guard !pairs.isEmpty else { return nil }
        gpsPairCount = pairs.count
        let positionSigma = sqrt(accuracySquares.reduce(0, +) / Double(accuracySquares.count))

        var yawEstimates: [AngleFusion.Estimate] = []
        if let free = RigidFit.robustFit(pairs) {
            yawEstimates.append(.init(
                angle: free.transform.yaw,
                sigma: RigidFit.yawSigma(of: free, positionSigma: positionSigma)
            ))
        }
        if let compassYaw = route.compassYawRadians {
            let spread = route.compassYawConsistency.map { CircularMean.sigma(forConsistency: $0) } ?? .pi / 6
            yawEstimates.append(.init(angle: compassYaw, sigma: max(CompassMath.biasFloorSigma, spread)))
        }
        let yaw = AngleFusion.fuse(yawEstimates)

        if let yaw, let fit = RigidFit.robustFit(pairs, fixedYaw: yaw.angle) {
            localToENU = fit.transform
            yawSigma = yaw.sigma
            let effectiveCount = max(1.0, Double(fit.count) / 4)
            let translationSigma = max(1.5, positionSigma / sqrt(effectiveCount))
            let leverArm = simd_length(PlanarGeo.plan(fromAR: localStart) - fit.sourceCentroid)
            startSigmaMeters = sqrt(translationSigma * translationSigma + pow(leverArm * yaw.sigma, 2))
        } else {
            // Heading unknown (a very short route recorded without a compass): the
            // best that can be said is that the start sits at its own fix.
            let startPair = pairs[0]
            localToENU = PlanarTransform(yaw: 0, translation: startPair.target - startPair.source)
            yawSigma = .pi
            startSigmaMeters = max(firstGeo.horizontalAccuracy, 5)
        }
    }
}

extension CircularMean {
    static func sigma(forConsistency r: Double) -> Double {
        guard r > 1e-6 else { return .pi }
        return min(.pi, sqrt(-2 * log(min(r, 1))))
    }
}

// MARK: - Live AR Session → Earth

/// Estimates where the live AR session sits on the earth before ARKit has matched the
/// recorded world map. The compass gives the heading immediately; as the user walks,
/// the GPS track paired with ARKit's camera path pins the heading and position down,
/// and the estimate keeps tightening rather than being recomputed from one fix.
struct ARGeoFusion {
    struct GPSSample {
        let arPlan: SIMD2<Double>
        let enu: SIMD2<Double>
        let accuracy: Double
        let timestamp: Date
    }

    struct Estimate {
        /// Maps live-session plan coordinates to east/north metres.
        let arToENU: PlanarTransform
        let yawSigma: Double
        let translationSigma: Double
        /// Live-session plan point the translation is anchored at; error grows with
        /// distance from it by `yawSigma`.
        let anchorPlan: SIMD2<Double>
        let gpsCount: Int
        let usedGPSHeading: Bool

        func sigma(at arPlan: SIMD2<Double>) -> Double {
            let lever = simd_length(arPlan - anchorPlan)
            return sqrt(translationSigma * translationSigma + pow(lever * yawSigma, 2))
        }
    }

    static let maxAcceptedAccuracy = 25.0
    private let maxGPSSamples = 120
    private let compassWindowSeconds: TimeInterval = 6

    private(set) var gpsSamples: [GPSSample] = []
    private var compassSamples: [(yaw: Double, time: TimeInterval)] = []

    mutating func addGPS(arPlan: SIMD2<Double>, enu: SIMD2<Double>, accuracy: Double, timestamp: Date) {
        guard accuracy >= 0, accuracy <= Self.maxAcceptedAccuracy else { return }
        if let last = gpsSamples.last, timestamp <= last.timestamp { return }
        gpsSamples.append(GPSSample(arPlan: arPlan, enu: enu, accuracy: accuracy, timestamp: timestamp))
        if gpsSamples.count > maxGPSSamples {
            gpsSamples.removeFirst(gpsSamples.count - maxGPSSamples)
        }
    }

    mutating func addCompass(yaw: Double, time: TimeInterval) {
        if let last = compassSamples.last, time - last.time < 1.0 / 15 { return }
        compassSamples.append((yaw, time))
        let cutoff = time - compassWindowSeconds
        if let firstKept = compassSamples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            compassSamples.removeFirst(firstKept)
        }
    }

    mutating func reset() {
        gpsSamples.removeAll()
        compassSamples.removeAll()
    }

    func estimate() -> Estimate? {
        guard !gpsSamples.isEmpty else { return nil }

        let pairs = gpsSamples.map { sample -> WeightedPair in
            let accuracy = max(sample.accuracy, 3)
            return WeightedPair(source: sample.arPlan, target: sample.enu, weight: 1 / (accuracy * accuracy))
        }
        let positionSigma = sqrt(gpsSamples.reduce(0) { $0 + pow(max($1.accuracy, 3), 2) } / Double(gpsSamples.count))

        var yawEstimates: [AngleFusion.Estimate] = []
        var compassMean = CircularMean()
        compassSamples.forEach { compassMean.add($0.yaw) }
        if compassMean.count >= 10, let mean = compassMean.mean {
            yawEstimates.append(.init(angle: mean, sigma: max(CompassMath.biasFloorSigma, compassMean.spreadSigma)))
        }
        var usedGPSHeading = false
        if let free = RigidFit.robustFit(pairs) {
            let sigma = RigidFit.yawSigma(of: free, positionSigma: positionSigma)
            if sigma < .pi {
                yawEstimates.append(.init(angle: free.transform.yaw, sigma: sigma))
                usedGPSHeading = true
            }
        }
        guard let yaw = AngleFusion.fuse(yawEstimates),
              let fit = RigidFit.robustFit(pairs, fixedYaw: yaw.angle) else { return nil }

        let effectiveCount = max(1.0, Double(fit.count) / 4)
        return Estimate(
            arToENU: fit.transform,
            yawSigma: yaw.sigma,
            translationSigma: max(2, positionSigma / sqrt(effectiveCount)),
            anchorPlan: fit.sourceCentroid,
            gpsCount: fit.count,
            usedGPSHeading: usedGPSHeading
        )
    }

    /// Placement of the recorded route inside the live AR session: recording space →
    /// earth → live session.
    static func routeToAR(localToENU: PlanarTransform, arToENU: PlanarTransform) -> PlanarTransform {
        localToENU.then(arToENU.inverse)
    }
}
