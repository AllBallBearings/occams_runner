import Foundation

// MARK: - Run Mode

enum ARRunMode {
    case aligning     // Initial alignment before first run
    case running      // Active collection
    case realigning   // Mid-run pause for drift correction
}

enum ARAlignmentState: String {
    case goToStart = "Go to route start"
    case scanStartArea = "Scan start area"
    case localized = "Localized"
    case lowConfidence = "Low-confidence alignment"
}
