import XCTest
import simd
@testable import OccamsRunner

/// Simulated runs: the runner follows the true route (weaving a little) while the
/// displayed route starts with a known placement error. The matcher should pull the
/// displayed route back under the runner without losing track of progress.
final class RouteRunMatcherTests: XCTestCase {

    private let phoneHeight: Float = 0.3

    // MARK: - Routes (AR world space, metres)

    private func densify(_ corners: [SIMD3<Float>], step: Float) -> [SIMD3<Float>] {
        var out = [corners[0]]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(1, Int(simd_distance(a, b) / step))
            for k in 1...n { out.append(a + (b - a) * Float(k) / Float(n)) }
        }
        return out
    }

    private var straight: [SIMD3<Float>] { densify([SIMD3(0, 0, 0), SIMD3(0, 0, -300)], step: 1) }
    private var curvy: [SIMD3<Float>] {
        densify([SIMD3(0, 0, 0), SIMD3(0, 0, -80), SIMD3(60, 0, -120), SIMD3(120, 0, -100),
                 SIMD3(150, 0, -30), SIMD3(100, 0, 20)], step: 1)
    }
    /// Out 120 m and back on a parallel path only 4 m away.
    private var outAndBack: [SIMD3<Float>] {
        densify([SIMD3(0, 0, 0), SIMD3(0, 0, -120), SIMD3(4, 0, -120), SIMD3(4, 0, 0)], step: 1)
    }
    private var tight: [SIMD3<Float>] {
        densify([SIMD3(0, 0, 0), SIMD3(0, 0, -10), SIMD3(5, 0, -12), SIMD3(8, 0, -20), SIMD3(3, 0, -28)],
                step: 0.3)
    }

    // MARK: - Simulation

    private struct Result {
        /// Median / max horizontal error under the runner over the second half of the run.
        let medianError: Float
        let maxError: Float
        let medianVerticalError: Float
        let maxProgressError: Float
    }

    private func simulate(
        _ route: [SIMD3<Float>],
        mode: RecordingMode = .vast,
        yawErrorDegrees: Float = 0,
        shift: SIMD3<Float> = .zero,
        reversed: Bool = false,
        speed: Float = 3,
        wander: Float = 0.3,
        detour: (from: Float, to: Float, offset: Float)? = nil
    ) -> Result {
        var arc: [Float] = [0]
        for i in 1..<route.count {
            arc.append(arc[i - 1] + simd_length(SIMD2(route[i].x - route[i - 1].x, route[i].z - route[i - 1].z)))
        }
        let total = arc.last!
        func at(_ s: Float) -> SIMD3<Float> {
            let s = min(max(s, 0), total)
            let i = min(arc.firstIndex(where: { $0 >= s }) ?? route.count - 1, route.count - 1)
            guard i > 0 else { return route[0] }
            let u = (s - arc[i - 1]) / max(arc[i] - arc[i - 1], 1e-6)
            return route[i - 1] + (route[i] - route[i - 1]) * u
        }

        // Placement error: rotate about the quest start, then shift.
        let start = reversed ? route.last! : route.first!
        let yaw = yawErrorDegrees * .pi / 180
        func misplaced(_ p: SIMD3<Float>) -> SIMD3<Float> {
            RouteRunMatcher.rotateY(p - start, by: yaw) + start + shift
        }
        let drop = SIMD3<Float>(0, -phoneHeight, 0)
        guard var matcher = RouteRunMatcher(
            basePoints: route.map { misplaced($0) + drop },
            fractions: arc.map { Double($0 / total) },
            config: .forMode(mode, precise: false),
            isReversed: reversed,
            defaultCameraHeight: phoneHeight
        ) else {
            XCTFail("matcher init failed")
            return Result(medianError: .infinity, maxError: .infinity,
                          medianVerticalError: .infinity, maxProgressError: .infinity)
        }

        let dt: Float = 0.3
        var s: Float = reversed ? total : 0
        var t: Float = 0
        matcher.start(camera: at(s))
        var errors: [Float] = []
        var verticalErrors: [Float] = []
        var maxProgressError: Float = 0

        while reversed ? s > 0 : s < total {
            s += (reversed ? -1 : 1) * speed * dt
            t += dt
            let p = at(s)
            var tangent = at(s + 0.5) - p
            tangent.y = 0
            tangent = simd_length(tangent) > 1e-6 ? simd_normalize(tangent) : SIMD3(0, 0, -1)
            let normal = SIMD3<Float>(-tangent.z, 0, tangent.x)
            var offset = wander * sin(t * 0.7)
            if let detour, s >= detour.from, s <= detour.to { offset += detour.offset }

            matcher.update(camera: p + normal * offset, dt: dt)

            // Where the corrected display draws the route point that truly lies under the runner.
            let shown = matcher.correction.apply(misplaced(p) + drop) - drop
            errors.append(simd_length(SIMD2(shown.x - p.x, shown.z - p.z)))
            verticalErrors.append(abs(shown.y - p.y))
            maxProgressError = max(maxProgressError, abs(matcher.progressMeters - s))
        }

        let secondHalf = Array(errors[(errors.count / 2)...]).sorted()
        let verticalHalf = Array(verticalErrors[(verticalErrors.count / 2)...]).sorted()
        return Result(
            medianError: secondHalf[secondHalf.count / 2],
            maxError: secondHalf.last ?? 0,
            medianVerticalError: verticalHalf[verticalHalf.count / 2],
            maxProgressError: maxProgressError
        )
    }

    // MARK: - Tests

    func test_perfectPlacement_staysPut() {
        let r = simulate(straight)
        XCTAssertLessThan(r.maxError, 0.3)
    }

    func test_lateralOffset_isPulledUnderRunner() {
        let r = simulate(straight, shift: SIMD3(3, 0, 0))
        XCTAssertLessThan(r.medianError, 1.0)
    }

    func test_headingAndShiftError_onCurvyRoute_converges() {
        let r = simulate(curvy, yawErrorDegrees: 6, shift: SIMD3(3, 0, 2))
        XCTAssertLessThan(r.medianError, 1.5)
        XCTAssertLessThan(r.maxProgressError, 5)
    }

    func test_reversedQuest_converges() {
        let r = simulate(curvy, yawErrorDegrees: 6, shift: SIMD3(3, 0, 2), reversed: true)
        XCTAssertLessThan(r.medianError, 1.5)
        XCTAssertLessThan(r.maxProgressError, 5)
    }

    func test_outAndBack_neverJumpsToTheOtherLeg() {
        for reversed in [false, true] {
            let r = simulate(outAndBack, yawErrorDegrees: 3, reversed: reversed)
            XCTAssertLessThan(r.maxProgressError, 5, "reversed: \(reversed)")
            XCTAssertLessThan(r.medianError, 1.0, "reversed: \(reversed)")
        }
    }

    func test_leavingTheRoute_recoversAfterReturning() {
        let r = simulate(curvy, yawErrorDegrees: 3, detour: (100, 140, 25))
        XCTAssertLessThan(r.medianError, 1.5)
    }

    func test_tightRoute_converges() {
        let r = simulate(tight, mode: .tight, yawErrorDegrees: 10, speed: 1.2, wander: 0.1)
        XCTAssertLessThan(r.medianError, 1.0)
    }

    func test_heightError_isCorrected() {
        let r = simulate(curvy, shift: SIMD3(0, 2, 0))
        XCTAssertLessThan(r.medianVerticalError, 0.5)
    }

    func test_preciseMode_limitsTotalCorrection() {
        let config = RouteRunMatcher.Config.forMode(.vast, precise: true)
        XCTAssertEqual(config.maxShift, 3)
        XCTAssertLessThan(config.maxYaw, 10 * .pi / 180)
    }

    func test_progressAtFraction_interpolatesArcLength() {
        let points = [SIMD3<Float>(0, 0, 0), SIMD3(0, 0, -10), SIMD3(0, 0, -30)]
        let matcher = RouteRunMatcher(basePoints: points, fractions: [0, 1.0 / 3.0, 1],
                                      config: .forMode(.vast, precise: false),
                                      isReversed: false, defaultCameraHeight: 0.3)
        XCTAssertEqual(matcher?.arcLength(atFraction: 2.0 / 3.0) ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(matcher?.totalLength ?? 0, 30, accuracy: 0.01)
    }
}
