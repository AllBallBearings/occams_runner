import Foundation

// MARK: - Run Mode

enum ARRunMode {
    case aligning     // Initial alignment before first run
    case running      // Active collection
    case realigning   // Mid-run pause for drift correction
}

enum ARAlignmentState: String {
    case moveToStart = "Move to route start"
    case scanning = "Scanning for relocalization"
    case locked = "Alignment locked"
    case lowConfidence = "Low-confidence alignment"
}

// MARK: - View Mode

/// How the route is shown before the run starts.
enum ARViewMode: String, CaseIterable, Identifiable {
    /// Guide the runner to the start beacon; the route appears once aligned there.
    case goToStart
    /// Show the whole route where it lies in the world, from wherever the user stands.
    case overview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goToStart: return "Go to Start"
        case .overview:  return "Preview Route"
        }
    }
}

// MARK: - Placement Quality

/// How the route is currently positioned in the AR world.
enum ARPlacementQuality: Equatable {
    /// Not enough compass/GPS data yet to place the route.
    case calibrating
    /// Placed from the GPS + compass registration; accurate to roughly this many metres.
    case approximate(uncertaintyMeters: Double)
    /// ARKit matched the recorded world map; placement is exact.
    case precise
}

/// Snapshot the coordinator publishes to the SwiftUI layer.
struct ARAlignmentStatus {
    var state: ARAlignmentState = .moveToStart
    var confidence: Double = 0
    /// Metres from the user to the route start; measured in AR space once the route is placed.
    var distanceToStart: Double?
    /// True when the run can start.
    var ready = false
    var placement: ARPlacementQuality = .calibrating
}
