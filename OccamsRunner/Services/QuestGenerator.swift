import Foundation

/// Generates quest items and boxes along a recorded route.
struct QuestGenerator {

    /// Place coins along a route at a given interval in feet.
    /// Canonical placement is route progress, not direct geo coordinates.
    static func generateItems(
        along route: RecordedRoute,
        intervalFeet: Double = 5.0,
        itemType: QuestItemType = .coin
    ) -> [QuestItem] {
        guard route.geoTrack.count >= 2 else { return [] }

        let intervalMeters = intervalFeet * 0.3048
        var items: [QuestItem] = []
        var distanceSinceLastItem: Double = 0

        for i in 1..<route.geoTrack.count {
            let prev = route.geoTrack[i - 1]
            let curr = route.geoTrack[i]

            let segmentDistance = curr.location.distance(from: prev.location)
            distanceSinceLastItem += segmentDistance

            guard segmentDistance > 0.001 else { continue }

            while distanceSinceLastItem >= intervalMeters {
                let overshoot = distanceSinceLastItem - intervalMeters
                let fraction = max(0, min(1, 1.0 - (overshoot / segmentDistance)))
                let progress = prev.progress + (curr.progress - prev.progress) * fraction

                let item = QuestItem(
                    type: itemType,
                    routeProgress: progress,
                    verticalOffset: 0
                )
                items.append(item)

                distanceSinceLastItem -= intervalMeters
            }
        }

        return items
    }

    /// Place a punchable box at every 10th coin position, offset from the route
    /// centerline by ~4 ft in a random horizontal direction.
    static func generateBoxes(from items: [QuestItem]) -> [QuestBox] {
        var boxes: [QuestBox] = []
        var rng = SystemRandomNumberGenerator()

        for i in stride(from: 9, to: items.count, by: 10) {
            let angle = Double.random(in: 0..<360, using: &rng)
            boxes.append(QuestBox(
                routeProgress: items[i].routeProgress,
                clockAngleDegrees: angle,
                radialOffsetMeters: 1.22  // ~4 feet
            ))
        }

        return boxes
    }
}
