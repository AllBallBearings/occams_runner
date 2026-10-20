import Foundation
import simd

/// Keeps a placed route under the runner while a quest is being run: the AR version of a
/// navigation app snapping its line to the road you are actually on.
///
/// Once a run starts the route is frozen in AR world space. Any placement error at the
/// start (GPS/compass heading, a slightly-off manual nudge) and any tracking drift
/// during the run then grows with distance, so far parts of a long route end up metres
/// off to the side. The runner, however, *is* following the route, and ARKit tracks
/// their recent path to centimetres. So each tick this matcher:
///
/// 1. Tracks how far along the route the runner is (`progressMeters`), searching only a
///    window around the last value in the quest's direction of travel. That keeps
///    reversed quests, loops and out-and-back routes from matching the wrong leg.
/// 2. Pairs each point of the runner's recent path with its closest point on that part
///    of the route and solves a small least-squares correction (yaw + shift, pivoting at
///    the runner so nearby coins barely move) that lays the route under the path.
/// 3. Applies only a fraction of it, rate-limited, with a deadband, robust weights and
///    a matching gate, so the route glides rather than jumps and doesn't chase a runner
///    who briefly steps around an obstacle.
///
/// Height is corrected the same way (hills, GPS altitude error), relative to how far
/// below the phone the route sat when the run started.
///
/// Positions are AR world space: Y up, X/Z ground plane.
struct RouteRunMatcher {

    struct Config {
        /// Route points farther than this from the runner are not evidence.
        var gate: Float
        /// How much of the runner's recent path (walked metres) is matched.
        var trajectoryWindow: Float
        /// Progress search window ahead of / behind the runner, metres along the route.
        var ahead: Float
        var behind: Float
        /// Minimum spacing between stored path points.
        var sampleSpacing: Float
        /// Each path point is matched within this many route-metres of where it was recorded.
        var matchSpan: Float
        /// Path length required before any correction is attempted.
        var minSpan: Float
        /// Rate limits (per second) and the overall yaw limit.
        var shiftRate: Float
        var yawRate: Float
        var maxYaw: Float
        /// Corrections below this RMS residual are noise from the runner weaving.
        var deadband: Float
        var verticalRate: Float
        var maxVertical: Float
        var verticalDeadband: Float
        /// Total shift allowed at the runner. Unbounded for GPS placement (drift grows
        /// with distance); bounded once ARKit has matched the recorded world map.
        var maxShift: Float

        static func forMode(_ mode: RecordingMode, precise: Bool) -> Config {
            var config: Config
            switch mode {
            case .tight:
                config = Config(gate: 4, trajectoryWindow: 12, ahead: 12, behind: 4,
                                sampleSpacing: 0.3, matchSpan: 4, minSpan: 4,
                                shiftRate: 0.25, yawRate: 3 * .pi / 180, maxYaw: 45 * .pi / 180,
                                deadband: 0.2, verticalRate: 0.15, maxVertical: 3,
                                verticalDeadband: 0.25, maxShift: .infinity)
            case .vast:
                config = Config(gate: 12, trajectoryWindow: 40, ahead: 40, behind: 10,
                                sampleSpacing: 1.0, matchSpan: 10, minSpan: 12,
                                shiftRate: 0.6, yawRate: 2 * .pi / 180, maxYaw: 45 * .pi / 180,
                                deadband: 0.35, verticalRate: 0.15, maxVertical: 3,
                                verticalDeadband: 0.25, maxShift: .infinity)
            }
            if precise {
                // The world map already pins the route; only allow trimming its edges.
                config.maxShift = 3
                config.maxYaw = 8 * .pi / 180
                config.shiftRate *= 0.5
                config.yawRate *= 0.5
                config.maxVertical = 0.5
            }
            return config
        }
    }

    /// World-space rigid correction applied on top of the frozen route:
    /// p' = Ry(yaw) · p + translation.
    struct Correction: Equatable {
        var yaw: Float = 0
        var translation: SIMD3<Float> = .zero

        var matrix: simd_float4x4 {
            var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(translation, 1)
            return m
        }

        func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
            RouteRunMatcher.rotateY(p, by: yaw) + translation
        }

        func moved(toward target: Correction, fraction t: Float) -> Correction {
            Correction(
                yaw: yaw + (target.yaw - yaw) * t,
                translation: simd_mix(translation, target.translation, SIMD3(repeating: t))
            )
        }
    }

    /// Share of each solved correction applied per tick (~1 s time constant at 3 Hz).
    static let gain: Float = 0.25

    let config: Config
    let isReversed: Bool
    private let points: [SIMD3<Float>]
    private let arc: [Float]
    private let fractions: [Double]

    private(set) var correction = Correction()
    private(set) var progressMeters: Float
    /// Camera height above the route, captured at start so a manual up/down nudge sticks.
    private(set) var cameraHeightAboveRoute: Float
    private(set) var lastResidualRMS: Float = 0
    private var trajectory: [(position: SIMD3<Float>, progress: Float)] = []
    private var misses = 0

    var totalLength: Float { arc.last ?? 0 }
    private var direction: Float { isReversed ? -1 : 1 }

    /// - Parameters:
    ///   - basePoints: route samples in world space under the frozen route transform.
    ///   - fractions: each sample's route progress in [0, 1] (to place collected coins).
    ///   - defaultCameraHeight: expected camera height above the route if it can't be
    ///     measured at start.
    init?(basePoints: [SIMD3<Float>], fractions: [Double], config: Config,
          isReversed: Bool, defaultCameraHeight: Float) {
        guard basePoints.count >= 2, fractions.count == basePoints.count else { return nil }
        self.points = basePoints
        self.fractions = fractions
        self.config = config
        self.isReversed = isReversed
        var arc: [Float] = [0]
        arc.reserveCapacity(basePoints.count)
        for i in 1..<basePoints.count {
            arc.append(arc[i - 1] + Self.horizontalDistance(basePoints[i], basePoints[i - 1]))
        }
        self.arc = arc
        self.progressMeters = isReversed ? (arc.last ?? 0) : 0
        self.cameraHeightAboveRoute = defaultCameraHeight
    }

    // MARK: - Lifecycle

    /// Finds the runner on the route (nearest in-gate point to `hintProgress`, else the
    /// quest start) and records the camera's height above it.
    mutating func start(camera: SIMD3<Float>, hintProgress: Float? = nil) {
        if let hintProgress { progressMeters = hintProgress }
        if let located = locate(camera, near: progressMeters) {
            progressMeters = located
        }
        let lo = progressMeters - config.matchSpan, hi = progressMeters + config.matchSpan
        if let match = closest(to: camera, from: lo, to: hi), match.distance <= config.gate {
            cameraHeightAboveRoute = camera.y - match.point.y
        }
    }

    /// A collected coin is right next to the runner: a free progress fix.
    mutating func noteCollected(routeFraction: Double) {
        let s = arcLength(atFraction: routeFraction)
        let ahead = (s - progressMeters) * direction
        if ahead > 0 && ahead <= config.ahead {
            progressMeters = s
        }
    }

    func arcLength(atFraction fraction: Double) -> Float {
        guard let upper = fractions.firstIndex(where: { $0 >= fraction }) else { return totalLength }
        guard upper > 0 else { return 0 }
        let span = fractions[upper] - fractions[upper - 1]
        let t = span > 0 ? Float((fraction - fractions[upper - 1]) / span) : 0
        return arc[upper - 1] + (arc[upper] - arc[upper - 1]) * t
    }

    // MARK: - Update

    /// One matching step. Call a few times a second with the camera's world position
    /// while tracking is normal.
    mutating func update(camera: SIMD3<Float>, dt: Float) {
        let dt = min(max(dt, 0), 1)

        // 1. Progress along the route, searched only around the last value.
        let (lo, hi) = progressWindow(around: progressMeters)
        guard let here = closest(to: camera, from: lo, to: hi), here.distance <= config.gate else {
            misses += 1
            if misses >= 15 {
                // Lost for ~5 s (shortcut, detour): re-find the runner anywhere on the route.
                if let located = locate(camera, near: progressMeters) { progressMeters = located }
                misses = 0
                trajectory.removeAll()
            }
            return
        }
        misses = 0
        progressMeters = here.progress

        // 2. Recent path, trimmed to the matching window.
        if let last = trajectory.last?.position {
            if Self.horizontalDistance(camera, last) >= config.sampleSpacing {
                trajectory.append((camera, progressMeters))
            }
        } else {
            trajectory.append((camera, progressMeters))
        }
        var walked: Float = 0
        var span: Float = 0
        if trajectory.count > 1 {
            for k in stride(from: trajectory.count - 1, to: 0, by: -1) {
                walked += Self.horizontalDistance(trajectory[k].position, trajectory[k - 1].position)
                if walked > config.trajectoryWindow {
                    trajectory.removeFirst(k)
                    break
                }
                span = walked
            }
        }
        guard trajectory.count >= 6, span >= config.minSpan else { return }

        // 3. Point-to-line least squares for (dYaw, dx, dz) about the runner.
        var a = simd_double3x3()
        var b = SIMD3<Double>.zero
        var weightSum: Double = 0
        var squaredSum: Double = 0
        var verticalResiduals: [Float] = []
        verticalResiduals.reserveCapacity(trajectory.count)

        for sample in trajectory {
            guard let match = closest(to: sample.position,
                                      from: sample.progress - config.matchSpan,
                                      to: sample.progress + config.matchSpan),
                  match.distance <= config.gate else { continue }
            let n = match.normal
            let q = match.point
            let r = Double(n.x * (q.x - sample.position.x) + n.y * (q.z - sample.position.z))
            let w = abs(r) < 1 ? 1.0 : 1.0 / abs(r)   // Huber: far points count less
            let lever = q - camera
            let dYaw = Double(n.x * lever.z - n.y * lever.x)   // n · d(Ry q)/dyaw at 0
            let j = SIMD3<Double>(dYaw, Double(n.x), Double(n.y))
            a += w * simd_double3x3(rows: [j * j.x, j * j.y, j * j.z])
            b += w * j * (-r)
            weightSum += w
            squaredSum += w * r * r
            verticalResiduals.append(sample.position.y - q.y - cameraHeightAboveRoute)
        }
        guard weightSum >= 4 else { return }
        lastResidualRMS = Float((squaredSum / weightSum).squareRoot())

        var step = SIMD3<Float>.zero    // (yaw, x, z)
        if lastResidualRMS > config.deadband {
            // Regularisation keeps directions the path can't observe (e.g. along a
            // straight) at zero instead of letting them wander.
            let lambda = 0.1 * weightSum
            let damped = a + simd_double3x3(diagonal: SIMD3(lambda * 25, lambda, lambda))
            if abs(damped.determinant) > 1e-9 {
                let u = damped.inverse * b
                step = SIMD3(Float(u.x), Float(u.y), Float(u.z)) * Self.gain
                let yawLimit = config.yawRate * dt
                step.x = min(max(step.x, -yawLimit), yawLimit)
                let shift = SIMD2(step.y, step.z)
                let shiftLimit = config.shiftRate * dt
                if simd_length(shift) > shiftLimit {
                    let scaled = simd_normalize(shift) * shiftLimit
                    step.y = scaled.x
                    step.z = scaled.y
                }
            }
        }

        var dy: Float = 0
        if let median = Self.median(verticalResiduals), abs(median) > config.verticalDeadband {
            let limit = config.verticalRate * dt
            dy = min(max(median * Self.gain, -limit), limit)
        }

        // 4. Compose the step about the runner: p' = c + Ry(dYaw)(p - c) + d.
        let pivot = SIMD3<Float>(camera.x, 0, camera.z)
        let newYaw = correction.yaw + step.x
        let newTranslation = Self.rotateY(correction.translation - pivot, by: step.x)
            + pivot + SIMD3(step.y, dy, step.z)

        let shiftedPivot = Self.rotateY(pivot, by: newYaw) + newTranslation - pivot
        let shiftAtRunner = simd_length(SIMD2(shiftedPivot.x, shiftedPivot.z))
        if abs(newYaw) <= config.maxYaw && shiftAtRunner <= config.maxShift {
            correction.yaw = newYaw
            correction.translation.x = newTranslation.x
            correction.translation.z = newTranslation.z
        }
        if abs(newTranslation.y) <= config.maxVertical {
            correction.translation.y = newTranslation.y
        }
    }

    // MARK: - Geometry

    private struct Match {
        let distance: Float
        let point: SIMD3<Float>
        /// Unit normal of the matched segment in the ground plane, as (x, z).
        let normal: SIMD2<Float>
        let progress: Float
    }

    private func progressWindow(around s: Float) -> (Float, Float) {
        isReversed ? (s - config.ahead, s + config.behind) : (s - config.behind, s + config.ahead)
    }

    /// Closest point on the corrected route among segments overlapping [lo, hi] metres.
    private func closest(to x: SIMD3<Float>, from lo: Float, to hi: Float) -> Match? {
        let first = max(0, lowerIndex(forArc: lo) - 1)
        let last = min(points.count - 1, upperIndex(forArc: hi))
        guard last > first else { return nil }
        var best: Match?
        for i in first..<last {
            if let m = segmentMatch(x, i), best == nil || m.distance < best!.distance {
                best = m
            }
        }
        return best
    }

    /// Among route points within the gate, the one nearest (along the route) to `hint`.
    private func locate(_ x: SIMD3<Float>, near hint: Float) -> Float? {
        var best: (key: Float, progress: Float)?
        for i in 0..<(points.count - 1) {
            guard let m = segmentMatch(x, i), m.distance <= config.gate else { continue }
            let key = abs(m.progress - hint)
            if best == nil || key < best!.key { best = (key, m.progress) }
        }
        return best?.progress
    }

    private func segmentMatch(_ x: SIMD3<Float>, _ i: Int) -> Match? {
        let a = correction.apply(points[i])
        let b = correction.apply(points[i + 1])
        let ab = SIMD2(b.x - a.x, b.z - a.z)
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-6 else { return nil }
        let ax = SIMD2(x.x - a.x, x.z - a.z)
        let u = min(1, max(0, simd_dot(ax, ab) / lengthSquared))
        let q = a + (b - a) * u
        let distance = simd_length(SIMD2(x.x - q.x, x.z - q.z))
        let normal = SIMD2(-ab.y, ab.x) / lengthSquared.squareRoot()
        return Match(distance: distance, point: q, normal: normal,
                     progress: arc[i] + (arc[i + 1] - arc[i]) * u)
    }

    /// First index whose arc length is >= s.
    private func lowerIndex(forArc s: Float) -> Int {
        var lo = 0, hi = arc.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arc[mid] < s { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose arc length is > s.
    private func upperIndex(forArc s: Float) -> Int {
        var lo = 0, hi = arc.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arc[mid] <= s { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - Helpers

    /// Rotation about +Y, matching `simd_quatf(angle:axis: (0, 1, 0))`.
    static func rotateY(_ p: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z)
    }

    private static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
