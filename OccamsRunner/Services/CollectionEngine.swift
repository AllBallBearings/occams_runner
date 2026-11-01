import SceneKit
import simd

// MARK: - Collection Mode

/// How a quest decides that the runner touched a coin. Stored per quest.
///
/// This is the single collection-mode setting. The planned "Milestone" zone
/// (a forgiving 2 ft cylinder around the phone) would be a third case here rather
/// than a separate pre-run toggle, so a quest only ever has one rule in force.
enum CollectionMode: String, Codable, CaseIterable, Identifiable {
    /// The phone itself must reach the coin (0.15 m sphere around the camera).
    case phoneTouch = "phone"
    /// The runner's body sweeps through the coin as they run past it.
    case bodyTouch = "body"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .phoneTouch: return "Phone Touch"
        case .bodyTouch:  return "Body Touch"
        }
    }

    var summary: String {
        switch self {
        case .phoneTouch: return "Reach each coin with your phone."
        case .bodyTouch:  return "Run through coins to grab them."
        }
    }
}

/// Pure collection logic — no ARKit runtime, no timers, no side effects.
/// Takes camera position and coin positions in, returns collection decisions out.
struct CollectionEngine {
    /// Half-foot diameter means 0.15m radius from center.
    static let collectionRadius: Float = 0.15

    struct CollectionResult {
        let collectedItemIds: [UUID]
        let debugLog: String
    }

    /// Evaluate which items should be collected based on simple 3D proximity.
    ///
    /// Items are collected when `distance3D(camera, coin) < collectionRadius`.
    /// No GPS fallback, no directional logic, no recording-mode distinction.
    ///
    /// - Parameters:
    ///   - cameraPosition: Device camera world position
    ///   - items: All quest items (collected ones are skipped)
    ///   - coinWorldPositions: World positions of coin scene nodes, keyed by item ID
    ///   - pendingIds: Items currently in-flight (already collected but not yet confirmed by dataStore)
    ///   - tickSerial: Monotonic tick counter for debug log
    /// - Returns: IDs of items to collect and a debug log string
    static func evaluateCollections(
        cameraPosition: SCNVector3,
        items: [QuestItem],
        coinWorldPositions: [UUID: SCNVector3],
        pendingIds: Set<UUID>,
        tickSerial: UInt64
    ) -> CollectionResult {
        evaluate(items: items, coinWorldPositions: coinWorldPositions,
                 pendingIds: pendingIds, tickSerial: tickSerial) { coinPos in
            let dist = distance3D(cameraPosition, coinPos)
            return (dist < collectionRadius, "d=\(String(format: "%.3f", dist))m")
        }
    }

    /// Evaluate body-touch collection: an item is collected when the body volume,
    /// swept from the previous tick to this one, passes through the coin.
    static func evaluateBodyCollections(
        sweep: BodyTouch.Sweep,
        items: [QuestItem],
        coinWorldPositions: [UUID: SCNVector3],
        pendingIds: Set<UUID>,
        tickSerial: UInt64
    ) -> CollectionResult {
        evaluate(items: items, coinWorldPositions: coinWorldPositions,
                 pendingIds: pendingIds, tickSerial: tickSerial) { coinPos in
            let hit = BodyTouch.hitTest(sweep: sweep, coin: SIMD3<Float>(coinPos))
            return (hit.touches, "body h=\(String(format: "%.3f", hit.horizontalDistance))m")
        }
    }

    /// Shared skip/log bookkeeping; `test` decides whether one coin is touched.
    private static func evaluate(
        items: [QuestItem],
        coinWorldPositions: [UUID: SCNVector3],
        pendingIds: Set<UUID>,
        tickSerial: UInt64,
        test: (SCNVector3) -> (inRange: Bool, label: String)
    ) -> CollectionResult {
        var collectedIds: [UUID] = []
        var logParts: [String] = []

        for item in items {
            let prefix = item.id.uuidString.prefix(4)

            if item.collected {
                logParts.append("\(prefix):skip(done)")
                continue
            }
            if pendingIds.contains(item.id) {
                logParts.append("\(prefix):skip(pending)")
                continue
            }
            guard let coinPos = coinWorldPositions[item.id] else {
                logParts.append("\(prefix):skip(noNode)")
                continue
            }

            let (inRange, label) = test(coinPos)
            logParts.append("\(prefix):\(label) \(inRange ? "✓" : "far")")

            if inRange {
                collectedIds.append(item.id)
            }
        }

        let collectTag = collectedIds.isEmpty ? "" : "COLLECT×\(collectedIds.count) | "
        let debugLog = "t\(tickSerial) \(collectTag)\(logParts.joined(separator: " | "))"

        return CollectionResult(collectedItemIds: collectedIds, debugLog: debugLog)
    }

    /// Euclidean distance between two SceneKit positions.
    static func distance3D(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}

// MARK: - Body Touch Geometry

/// The runner's body as an upright cylinder trailing the phone along the direction
/// of travel. Each tick the cylinder is swept from its previous position to its new
/// one, so a coin between two ticks is still hit at sprint speed.
///
/// World units are ARKit metres, Y up. Coins sit at the recorded phone height
/// minus 0.3 m (the route group's base offset), i.e. around the runner's waist.
enum BodyTouch {
    /// Torso centre behind the phone along the horizontal heading. The phone is held
    /// at roughly forearm length in front of the sternum while running (0.3–0.4 m).
    /// With `horizontalRadius` equal to this lag, the front of the cylinder is the
    /// phone itself, so a coin straight ahead is collected as the phone reaches it.
    static let lagBehindCamera: Float = 0.35

    /// Horizontal reach of the body: torso half-width (~0.22 m for 0.45 m shoulders)
    /// plus the coin's own radius (`StarCoinAsset.diameter` 0.26 m → 0.13 m).
    /// Kept tight so a coin passed half a metre to the side is seen but not taken.
    static let horizontalRadius: Float = 0.35

    /// Top of the body above the phone: the phone is held around chest-to-chin height,
    /// so the top of the head is ~0.15–0.3 m higher. Taking the lower end keeps coins
    /// floating overhead out of reach.
    static let topAboveCamera: Float = 0.15

    /// Bottom of the body below the phone: the feet. The AR scene puts the ground
    /// ~1.5 m below the phone (see the start beacon in ARCoordinator).
    static let bottomBelowCamera: Float = 1.5

    /// Extra vertical slack on both ends, about one coin radius, so a coin poking
    /// out at the head or feet still counts.
    static let verticalTolerance: Float = 0.10

    /// How far back in time the travel heading is measured. ~3 collection ticks:
    /// long enough to smooth ARKit jitter and arm bounce, short enough to follow turns.
    static let headingWindow: TimeInterval = 0.75

    /// Minimum horizontal travel inside `headingWindow` before it counts as a heading
    /// (0.33 m/s, slower than a stroll). Below this the last heading is kept.
    static let minHeadingTravel: Float = 0.25

    /// Longest body movement between two ticks that is treated as real motion.
    /// 3 m per 0.25 s tick is 12 m/s, faster than a sprint; anything longer is an
    /// AR tracking jump, and sweeping across it would collect coins never touched.
    static let maxSweepPerTick: Float = 3.0

    /// The body's path over one tick. Each end is the torso axis at the
    /// camera's height; the cylinder spans down to the feet and up to the head.
    struct Sweep: Equatable {
        let from: SIMD3<Float>
        let to: SIMD3<Float>

        static func stationary(_ p: SIMD3<Float>) -> Sweep { Sweep(from: p, to: p) }
    }

    struct Hit {
        let touches: Bool
        /// Closest horizontal distance from the swept torso axis to the coin.
        let horizontalDistance: Float
    }

    /// Torso axis for a camera position and a unit horizontal heading (x, z).
    static func bodyCenter(camera: SIMD3<Float>, heading: SIMD2<Float>?) -> SIMD3<Float> {
        guard let heading else { return camera }
        return SIMD3(camera.x - heading.x * lagBehindCamera,
                     camera.y,
                     camera.z - heading.y * lagBehindCamera)
    }

    /// Segment-vs-cylinder test: closest point of the swept axis to the coin in the
    /// horizontal plane, then a height check at that point of the sweep.
    static func hitTest(sweep: Sweep, coin: SIMD3<Float>) -> Hit {
        let a = SIMD2(sweep.from.x, sweep.from.z)
        let b = SIMD2(sweep.to.x, sweep.to.z)
        let c = SIMD2(coin.x, coin.z)
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        let t: Float = lengthSquared > 1e-8
            ? simd_clamp(simd_dot(c - a, ab) / lengthSquared, 0, 1)
            : 0
        let horizontal = simd_distance(c, a + ab * t)

        let cameraY = sweep.from.y + (sweep.to.y - sweep.from.y) * t
        let bottom = cameraY - bottomBelowCamera - verticalTolerance
        let top = cameraY + topAboveCamera + verticalTolerance
        let touches = horizontal < horizontalRadius && coin.y >= bottom && coin.y <= top
        return Hit(touches: touches, horizontalDistance: horizontal)
    }
}

/// Turns the stream of camera positions into body sweeps, one per collection tick.
struct BodyTouchTracker {
    private var history: [(time: TimeInterval, position: SIMD3<Float>)] = []
    /// Last established direction of travel (unit, x/z). Kept while the runner pauses.
    private(set) var heading: SIMD2<Float>?
    private var lastBody: SIMD3<Float>?

    /// Forget motion history, e.g. when a run is paused or realigned, so the next
    /// tick does not sweep across the gap.
    mutating func reset() {
        history.removeAll()
        heading = nil
        lastBody = nil
    }

    /// Record this tick's camera and return the body sweep since the previous tick.
    ///
    /// Heading comes from recent travel; before the runner has moved, the phone's
    /// horizontal facing stands in (the body is behind the screen the runner is
    /// looking at). Without either, the body is centred on the phone.
    mutating func advance(camera: SIMD3<Float>,
                          cameraForward: SIMD3<Float>?,
                          time: TimeInterval) -> BodyTouch.Sweep {
        history.append((time, camera))
        history.removeAll { time - $0.time > BodyTouch.headingWindow }

        if let oldest = history.first {
            let travel = SIMD2(camera.x - oldest.position.x, camera.z - oldest.position.z)
            if simd_length(travel) >= BodyTouch.minHeadingTravel {
                heading = simd_normalize(travel)
            }
        }

        var effectiveHeading = heading
        if effectiveHeading == nil, let forward = cameraForward {
            let flat = SIMD2(forward.x, forward.z)
            if simd_length(flat) > 0.1 { effectiveHeading = simd_normalize(flat) }
        }

        let body = BodyTouch.bodyCenter(camera: camera, heading: effectiveHeading)
        defer { lastBody = body }
        guard let previous = lastBody,
              simd_distance(previous, body) <= BodyTouch.maxSweepPerTick else {
            return .stationary(body)
        }
        return BodyTouch.Sweep(from: previous, to: body)
    }
}
