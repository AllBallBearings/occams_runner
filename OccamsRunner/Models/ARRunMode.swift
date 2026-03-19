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
