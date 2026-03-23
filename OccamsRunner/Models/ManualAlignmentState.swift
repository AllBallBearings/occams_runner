import Foundation
import simd

// MARK: - Manual Alignment State

/// Mutable state shared between SwiftUI gesture handlers and ARCoordinator.
/// Holds the user-applied corrections to the route overlay position during alignment.
/// This is a class (reference type) so both the SwiftUI view and the coordinator
/// always read/write the same instance without going through SwiftUI's state machinery.
final class ManualAlignmentState {

    // MARK: - Current Applied Offsets
    // These are camera-relative offsets; ARCoordinator converts them to
    // world-space coordinates each frame using the camera's current orientation
    // so gestures always feel natural on screen.

    /// Lateral offset in meters along the camera's right axis (positive = right on screen).
    var worldX: Float = 0

    /// Vertical offset in meters (positive = up; Y is up in both camera and world space).
    var worldY: Float = 0

    /// Depth offset in meters along the camera's forward axis.
    /// Negative = toward camera (spread gesture pulls closer), positive = away from camera.
    var worldZ: Float = 0

    /// Rotation around world Y axis in radians (positive = counter-clockwise from above).
    var rotationY: Float = 0

    // MARK: - Gesture Accumulation Bases
    // DragGesture.value.translation is always relative to the drag-start position.
    // Store the committed offset at the end of each gesture so the next gesture
    // can add onto the previously accumulated total.

    var baseX: Float = 0
    var baseY: Float = 0
    var baseZ: Float = 0
    var baseRotation: Float = 0

    // MARK: - Helpers

    var hasAdjustment: Bool {
        worldX != 0 || worldY != 0 || worldZ != 0 || rotationY != 0
    }

    /// Call at the end of each drag / rotation / pinch gesture to commit the live values
    /// as the new base for the next gesture.
    func commitGesture() {
        baseX = worldX
        baseY = worldY
        baseZ = worldZ
        baseRotation = rotationY
    }

    /// Reset all offsets to zero (returns route to auto-aligned position).
    func reset() {
        worldX = 0
        worldY = 0
        worldZ = 0
        rotationY = 0
        baseX = 0
        baseY = 0
        baseZ = 0
        baseRotation = 0
    }
}
