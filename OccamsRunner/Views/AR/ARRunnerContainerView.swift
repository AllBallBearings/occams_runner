import SwiftUI
import ARKit
import SceneKit

// MARK: - AR Container (UIViewRepresentable)

struct ARRunnerContainerView: UIViewRepresentable {
    let route: RecordedRoute
    let quest: Quest
    let dataStore: DataStore
    let locationService: LocationService
    let runMode: ARRunMode
    /// Shared state object that carries user-applied manual alignment corrections.
    let manualAlignment: ManualAlignmentState
    /// Current device compass heading (degrees from north, clockwise).
    /// Updated each SwiftUI render pass so the coordinator always has a fresh value.
    let compassHeading: Double
    /// CLHeading.headingAccuracy in degrees. -1 = invalid / not yet calibrated.
    let compassHeadingAccuracy: Double
    let onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    let onNearestItemDistance: (Double?) -> Void
    let onItemCollected: (UUID) -> Void
    let onDebugTick: (String) -> Void
    /// 0–1 intensity for the "camera pointing at start ring" screen glow.
    let onRingGlowIntensity: (Double) -> Void
    /// Signed horizontal bearing (deg) from camera forward to the GPS ring,
    /// or nil when no meaningful direction is available.  Drives HUD compass.
    let onRingBearing: (Double?) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        // This view does not need direct touch handling; keeping it non-interactive
        // ensures top HUD controls (Realign/X) are always tappable.
        arView.isUserInteractionEnabled = false
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []

        if let encrypted = route.encryptedWorldMapData,
           let decrypted = locationService.decryptWorldMapData(encrypted),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: decrypted) {
            config.initialWorldMap = worldMap
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        context.coordinator.arView = arView
        // Wire the manual alignment state before the initial scene is built.
        context.coordinator.manualAlignment = manualAlignment
        context.coordinator.configureInitialScene()

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.applyRunMode(runMode)

        // Fix 3: Refresh callbacks on every render pass so the coordinator always
        // holds closures that close over the current @State / @EnvironmentObject
        // values. makeCoordinator() is called only once, so without this the
        // callbacks capture a frozen struct that goes stale after the first
        // SwiftUI re-render (e.g. after the first coin collection).
        context.coordinator.onItemCollected       = onItemCollected
        context.coordinator.onAlignmentUpdate     = onAlignmentUpdate
        context.coordinator.onNearestItemDistance = onNearestItemDistance
        context.coordinator.onDebugTick          = onDebugTick
        context.coordinator.onRingGlowIntensity   = onRingGlowIntensity
        context.coordinator.onRingBearing         = onRingBearing
        context.coordinator.compassHeading         = compassHeading
        context.coordinator.compassHeadingAccuracy = compassHeadingAccuracy

        // Keep the manual alignment reference in sync (same instance in practice,
        // but explicit assignment ensures correctness across any future refactors).
        context.coordinator.manualAlignment = manualAlignment

        // Always pull the live quest from dataStore rather than using the
        // struct-captured snapshot — the snapshot goes stale the moment any
        // item is marked collected, which would cause buildCoinNodes to
        // re-create already-collected coin nodes and break subsequent collections.
        let liveQuest = dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
        context.coordinator.updateQuest(liveQuest, dataStore: dataStore)
    }

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(
            route: route,
            quest: quest,
            dataStore: dataStore,
            locationService: locationService,
            onAlignmentUpdate: onAlignmentUpdate,
            onNearestItemDistance: onNearestItemDistance,
            onItemCollected: onItemCollected,
            onDebugTick: onDebugTick
        )
    }
}
