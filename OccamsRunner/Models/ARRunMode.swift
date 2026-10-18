import Foundation

// MARK: - Run Mode

enum ARRunMode {
    case aligning     // Initial alignment before first run
    case running      // Active collection
    case realigning   // Mid-run pause for drift correction
}

/// Which single adjustment a drag currently controls on the alignment screen.
enum AlignmentAdjustMode: CaseIterable {
    case shift, depth, height, rotate

    var label: String {
        switch self {
        case .shift:  return "LEFT / RIGHT"
        case .depth:  return "CLOSER / FARTHER"
        case .height: return "UP / DOWN"
        case .rotate: return "ROTATE"
        }
    }

    var icon: String {
        switch self {
        case .shift:  return "arrow.left.and.right"
        case .depth:  return "arrow.up.and.down.and.arrow.left.and.right"
        case .height: return "arrow.up.and.down"
        case .rotate: return "arrow.triangle.2.circlepath"
        }
    }

    var instruction: String {
        switch self {
        case .shift:  return "Drag left or right to slide the route"
        case .depth:  return "Drag up to push the route away, down to pull it closer"
        case .height: return "Drag up to raise the route, down to lower it"
        case .rotate: return "Drag left or right to turn the route"
        }
    }
}

enum ARAlignmentState: String {
    case moveToStart = "Move to route start"
    case scanning = "Scanning for relocalization"
    case locked = "Alignment locked"
    case lowConfidence = "Low-confidence alignment"
}
