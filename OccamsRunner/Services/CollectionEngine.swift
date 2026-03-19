import SceneKit

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

            let dist = distance3D(cameraPosition, coinPos)
            let inRange = dist < collectionRadius

            logParts.append(
                "\(prefix):d=\(String(format: "%.3f", dist))m \(inRange ? "✓" : "far")"
            )

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
