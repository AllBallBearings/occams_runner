import XCTest
@testable import OccamsRunner

/// Tests for LocationService recording lifecycle: background/foreground guards,
/// save-blocker logic, and the new background-GPS recording capability.
final class LocationServiceLifecycleTests: XCTestCase {

    private var sut: LocationService!

    override func setUp() {
        super.setUp()
        sut = LocationService()
    }

    // MARK: - handleAppBackgrounded / handleAppForegrounded guards

    func test_handleAppBackgrounded_whenNotRecording_doesNotCrash() {
        XCTAssertFalse(sut.isRecording, "Precondition: not recording")
        // Must not throw or mutate unexpected state
        sut.handleAppBackgrounded()
        XCTAssertFalse(sut.isRecording, "isRecording must remain false")
    }

    func test_handleAppForegrounded_whenNotRecording_doesNotCrash() {
        XCTAssertFalse(sut.isRecording, "Precondition: not recording")
        sut.handleAppForegrounded()
        XCTAssertFalse(sut.isRecording, "isRecording must remain false")
    }

    func test_handleAppBackgrounded_calledRepeatedly_doesNotCrash() {
        // Guard must be idempotent when not recording
        sut.handleAppBackgrounded()
        sut.handleAppBackgrounded()
        sut.handleAppBackgrounded()
    }

    func test_handleAppForegrounded_calledRepeatedly_doesNotCrash() {
        sut.handleAppForegrounded()
        sut.handleAppForegrounded()
    }

    // MARK: - saveBlockerDescription

    func test_saveBlockerDescription_defaultState_listsAllFourBlockers() {
        // Fresh LocationService has all-zero quality → every threshold is unmet
        let desc = sut.saveBlockerDescription
        XCTAssertTrue(desc.contains("Match"),       "Low match ratio should be listed")
        XCTAssertTrue(desc.contains("Features"),    "Low feature count should be listed")
        XCTAssertTrue(desc.contains("Tracking"),    "Low tracking score should be listed")
        XCTAssertTrue(desc.contains("world map"),   "Missing world map should be listed")
    }

    func test_saveBlockerDescription_allThresholdsMet_isEmpty() {
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.70,
            averageFeaturePoints: 80,
            averageTrackingScore: 0.70,
            hasEncryptedWorldMap: true
        )
        XCTAssertTrue(sut.saveBlockerDescription.isEmpty,
                      "No blockers expected when all thresholds are met")
    }

    func test_saveBlockerDescription_exactlyAtThresholds_isEmpty() {
        // Boundary values (≥65%, ≥75, ≥65%, hasMap=true) should NOT block
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.65,
            averageFeaturePoints: 75,
            averageTrackingScore: 0.65,
            hasEncryptedWorldMap: true
        )
        XCTAssertTrue(sut.saveBlockerDescription.isEmpty,
                      "Values exactly at threshold should not trigger blockers")
    }

    func test_saveBlockerDescription_oneBelowThreshold_listsOnlyThatBlocker() {
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.80,
            averageFeaturePoints: 90,
            averageTrackingScore: 0.50,   // below 0.65
            hasEncryptedWorldMap: true
        )
        let desc = sut.saveBlockerDescription
        XCTAssertTrue(desc.contains("Tracking"), "Low tracking should appear")
        XCTAssertFalse(desc.contains("Match"),   "Good match should NOT appear")
        XCTAssertFalse(desc.contains("Feature"), "Good features should NOT appear")
        XCTAssertFalse(desc.contains("world map"), "World map present — should NOT appear")
    }

    func test_saveBlockerDescription_missingWorldMapOnly_mentionsWorldMap() {
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.70,
            averageFeaturePoints: 80,
            averageTrackingScore: 0.70,
            hasEncryptedWorldMap: false   // only this is missing
        )
        let desc = sut.saveBlockerDescription
        XCTAssertTrue(desc.contains("world map"), "Missing world map should be listed")
        XCTAssertFalse(desc.contains("Match"),    "Good match should NOT appear")
        XCTAssertFalse(desc.contains("Feature"),  "Good features should NOT appear")
        XCTAssertFalse(desc.contains("Tracking"), "Good tracking should NOT appear")
    }

    // MARK: - canSavePreciseRoute

    func test_canSavePreciseRoute_whenAllThresholdsMet_isTrue() {
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.70,
            averageFeaturePoints: 80,
            averageTrackingScore: 0.70,
            hasEncryptedWorldMap: true
        )
        XCTAssertTrue(sut.canSavePreciseRoute)
    }

    func test_canSavePreciseRoute_whenAnyThresholdUnmet_isFalse() {
        sut.preciseCaptureQuality = RouteCaptureQuality(
            matchedSampleRatio: 0.70,
            averageFeaturePoints: 80,
            averageTrackingScore: 0.70,
            hasEncryptedWorldMap: false   // missing world map
        )
        XCTAssertFalse(sut.canSavePreciseRoute)
    }

    // MARK: - logRunEvent (public debug log bridge)

    func test_logRunEvent_doesNotCrash() {
        // Just verify the public logging bridge doesn't throw
        sut.logRunEvent("test event from unit test")
    }
}
