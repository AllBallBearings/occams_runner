import Foundation
import CoreLocation

/// Generates quest items along a recorded route at specified intervals.
struct QuestGenerator {

    /// Place coins along a route at a given interval in feet.
    /// - Parameters:
    ///   - route: The recorded route to place items along.
    ///   - intervalFeet: Distance between items in feet (default 10 feet).
    ///   - itemType: The type of quest item to place.
    /// - Returns: Array of QuestItems placed along the route.
    static func generateItems(
        along route: RecordedRoute,
        intervalFeet: Double = 10.0,
        itemType: QuestItemType = .coin
    ) -> [QuestItem] {
        guard route.points.count >= 2 else { return [] }

        let intervalMeters = intervalFeet * 0.3048
        var items: [QuestItem] = []
        var distanceSinceLastItem: Double = 0

        for i in 1..<route.points.count {
            let prev = route.points[i - 1]
            let curr = route.points[i]

            let segmentDistance = curr.location.distance(from: prev.location)
            distanceSinceLastItem += segmentDistance

            while distanceSinceLastItem >= intervalMeters {
                // Interpolate position along this segment
                let overshoot = distanceSinceLastItem - intervalMeters
                let fraction = max(0, min(1, 1.0 - (overshoot / segmentDistance)))

                let lat = prev.latitude + (curr.latitude - prev.latitude) * fraction
                let lon = prev.longitude + (curr.longitude - prev.longitude) * fraction
                let alt = prev.altitude + (curr.altitude - prev.altitude) * fraction

                let item = QuestItem(
                    type: itemType,
                    latitude: lat,
                    longitude: lon,
                    altitude: alt
                )
                items.append(item)

                distanceSinceLastItem -= intervalMeters
            }
        }

        return items
    }
}
