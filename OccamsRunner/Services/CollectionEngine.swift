import SceneKit
import simd

// MARK: - Collection Mode

/// How a quest decides that the runner collected a coin. Stored per quest.
///
/// Raw values predate the Touch/Run names and are kept so saved quests still load:
/// old Phone Touch quests become Touch, old Body Touch quests become Run.
enum CollectionMode: String, Codable, CaseIterable, Identifiable {
    /// The phone itself must reach the coin (1 ft sphere around the coin).
    case touch = "phone"
    /// Passing the coin breaks an invisible vertical plane it sits on.
    case run = "body"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .touch: return "Touch"
        case .run:   return "Run"
        }
    }

    var summary: String {
        switch self {
        case .touch: return "Place your phone on each coin."
        case .run:   return "Run past coins to grab them automatically."
        }
    }
}

/// Pure collection logic — no ARKit runtime, no timers, no side effects.
/// Takes camera position and coin positions in, returns collection decisions out.
struct CollectionEngine {
    /// Touch reach: 1 ft radius from the coin's center.
    static let collectionRadius: Float = 0.3048

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
                 pendingIds: pendingIds, tickSerial: tickSerial) { _, coinPos in
            let dist = distance3D(cameraPosition, coinPos)
            return (dist < collectionRadius, "d=\(String(format: "%.3f", dist))m")
        }
    }

    /// Evaluate run collection: an item is collected when this tick's movement,
    /// measured relative to the coin, breaks the coin's vertical plane.
    ///
    /// - Parameters:
    ///   - sweeps: Phone movement relative to each coin, from `RunGateTracker`
    ///   - gateNormals: Horizontal route direction at each coin (the plane's normal)
    static func evaluateRunCollections(
        sweeps: [UUID: RunGate.Sweep],
        gateNormals: [UUID: SIMD2<Float>],
        items: [QuestItem],
        coinWorldPositions: [UUID: SCNVector3],
        pendingIds: Set<UUID>,
        tickSerial: UInt64
    ) -> CollectionResult {
        evaluate(items: items, coinWorldPositions: coinWorldPositions,
                 pendingIds: pendingIds, tickSerial: tickSerial) { id, _ in
            guard let sweep = sweeps[id] else { return (false, "run noSweep") }
            let hit = RunGate.hitTest(sweep: sweep, normal: gateNormals[id])
            return (hit.touches, "run h=\(String(format: "%.3f", hit.horizontalDistance))m")
        }
    }

    /// Shared skip/log bookkeeping; `test` decides whether one coin is collected.
    private static func evaluate(
        items: [QuestItem],
        coinWorldPositions: [UUID: SCNVector3],
        pendingIds: Set<UUID>,
        tickSerial: UInt64,
        test: (UUID, SCNVector3) -> (inRange: Bool, label: String)
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

            let (inRange, label) = test(item.id, coinPos)
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

// MARK: - Run Gate Geometry

/// Each coin sits on an invisible vertical plane across the route, like a finish
/// line tape. Moving the phone from one side of the plane to the other, close enough
/// to the coin, collects it, in either direction and however far apart the ticks are.
///
/// Everything here is measured relative to the coin. The route is nudged under the
/// runner during a run (see RouteRunMatcher), and a coin sliding past the phone must
/// still count as a crossing rather than skip the runner over the plane.
///
/// World units are ARKit metres, Y up. Coins sit at the recorded phone height
/// minus 0.3 m (the route group's base offset), i.e. around the runner's waist.
enum RunGate {
    /// How far to either side of the coin the plane reaches (2 ft).
    static let halfWidth: Float = 0.6096

    /// Top of the plane relative to the phone: about the top of the head, so coins
    /// floating overhead stay out of reach.
    static let topAboveCamera: Float = 0.25

    /// Bottom of the plane relative to the phone: the feet. The AR scene puts the
    /// ground ~1.5 m below the phone (see the start beacon in ARCoordinator).
    static let bottomBelowCamera: Float = 1.6

    /// Longest movement between two ticks that is treated as real motion.
    /// 3 m per 0.25 s tick is 12 m/s, faster than a sprint; anything longer is an
    /// AR tracking jump, and crossing on it would collect coins never reached.
    static let maxSweepPerTick: Float = 3.0

    /// The phone's movement over one tick, as offsets from the coin (phone − coin).
    struct Sweep: Equatable {
        let from: SIMD3<Float>
        let to: SIMD3<Float>

        static func stationary(_ offset: SIMD3<Float>) -> Sweep { Sweep(from: offset, to: offset) }
    }

    struct Hit {
        let touches: Bool
        /// Horizontal distance from the coin: at the crossing, else at the end of the sweep.
        let horizontalDistance: Float
    }

    /// Plane-crossing test. `normal` is the unit horizontal route direction (x, z) at
    /// the coin; without one the plane faces the runner's own movement. The Touch
    /// sphere also counts, so a coin the runner starts just past isn't lost.
    static func hitTest(sweep: Sweep, normal: SIMD2<Float>?) -> Hit {
        let endDistance = simd_length(SIMD2(sweep.to.x, sweep.to.z))
        if simd_length(sweep.to) < CollectionEngine.collectionRadius {
            return Hit(touches: true, horizontalDistance: endDistance)
        }

        let travel = sweep.to - sweep.from
        let flatTravel = SIMD2(travel.x, travel.z)
        guard let facing = normal ?? (simd_length(flatTravel) > 1e-4 ? simd_normalize(flatTravel) : nil) else {
            return Hit(touches: false, horizontalDistance: endDistance)
        }

        let startSide = simd_dot(SIMD2(sweep.from.x, sweep.from.z), facing)
        let endSide = simd_dot(SIMD2(sweep.to.x, sweep.to.z), facing)
        guard (startSide < 0) != (endSide < 0) else {
            return Hit(touches: false, horizontalDistance: endDistance)
        }

        let crossing = sweep.from + travel * (startSide / (startSide - endSide))
        let horizontal = simd_length(SIMD2(crossing.x, crossing.z))
        let touches = horizontal < halfWidth
            && crossing.y >= -topAboveCamera
            && crossing.y <= bottomBelowCamera
        return Hit(touches: touches, horizontalDistance: horizontal)
    }
}

/// Turns the stream of camera and coin positions into per-coin sweeps, one per tick.
struct RunGateTracker {
    private var offsets: [UUID: SIMD3<Float>] = [:]

    /// Forget motion history, e.g. when a run is paused or realigned, so the next
    /// tick does not sweep across the gap.
    mutating func reset() {
        offsets.removeAll()
    }

    /// Record this tick's positions and return each coin's sweep since the previous
    /// tick. A coin seen for the first time, or a tracking jump, gives a stationary sweep.
    mutating func advance(camera: SIMD3<Float>, coins: [UUID: SIMD3<Float>]) -> [UUID: RunGate.Sweep] {
        var sweeps: [UUID: RunGate.Sweep] = [:]
        var newOffsets: [UUID: SIMD3<Float>] = [:]
        for (id, coin) in coins {
            let offset = camera - coin
            newOffsets[id] = offset
            if let previous = offsets[id], simd_distance(previous, offset) <= RunGate.maxSweepPerTick {
                sweeps[id] = RunGate.Sweep(from: previous, to: offset)
            } else {
                sweeps[id] = .stationary(offset)
            }
        }
        offsets = newOffsets
        return sweeps
    }
}
