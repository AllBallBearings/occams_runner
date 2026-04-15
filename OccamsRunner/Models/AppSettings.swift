import Foundation

/// App-wide user preferences, persisted to UserDefaults.
class AppSettings: ObservableObject {
    @Published var useMetricUnits: Bool {
        didSet { UserDefaults.standard.set(useMetricUnits, forKey: Keys.useMetricUnits) }
    }

    init() {
        self.useMetricUnits = UserDefaults.standard.bool(forKey: Keys.useMetricUnits)
    }

    private enum Keys {
        static let useMetricUnits = "useMetricUnits"
    }

    // MARK: - Formatting helpers

    func formatDistance(meters: Double) -> String {
        if useMetricUnits {
            return String(format: "%.2f km", meters / 1000.0)
        } else {
            return String(format: "%.2f mi", meters / 1609.344)
        }
    }

    func formatDistanceShort(meters: Double) -> String {
        if useMetricUnits {
            return String(format: "%.1f km", meters / 1000.0)
        } else {
            return String(format: "%.1f mi", meters / 1609.344)
        }
    }

    func distanceValue(meters: Double) -> Double {
        useMetricUnits ? meters / 1000.0 : meters / 1609.344
    }

    var distanceUnitLabel: String { useMetricUnits ? "km" : "mi" }

    func formatElevation(meters: Double) -> String {
        if useMetricUnits {
            return String(format: "%.0f m", meters)
        } else {
            return String(format: "%.0f ft", meters * 3.28084)
        }
    }
}
