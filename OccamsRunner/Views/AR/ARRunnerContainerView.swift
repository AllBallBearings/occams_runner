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
    let headingDegrees: Double
    /// Shared state object that carries user-applied manual alignment corrections.
    let manualAlignment: ManualAlignmentState
    let onAlignmentUpdate: (ARAlignmentState, Double, Double?, Bool) -> Void
    let onNearestItemDistance: (Double?) -> Void
    let onItemCollected: (UUID) -> Void
    let onDebugTick: (String) -> Void
    let onStartPlacementDebugUpdate: (String) -> Void

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
        // Horizontal plane detection feeds the shadow-catcher plane nodes the
        // ARCoordinator builds in `renderer(_:didAdd:for:)`. Real shadows from
        // the directional shadow light land on these surfaces.
        config.planeDetection = [.horizontal]

        if let encrypted = route.encryptedWorldMapData,
           let decrypted = locationService.decryptWorldMapData(encrypted),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: decrypted) {
            config.initialWorldMap = worldMap
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        context.coordinator.arView = arView
        // Wire the manual alignment state before the initial scene is built.
        context.coordinator.manualAlignment = manualAlignment
        context.coordinator.headingDegrees = headingDegrees
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
        context.coordinator.onStartPlacementDebugUpdate = onStartPlacementDebugUpdate

        // Keep the manual alignment reference in sync (same instance in practice,
        // but explicit assignment ensures correctness across any future refactors).
        context.coordinator.manualAlignment = manualAlignment
        context.coordinator.headingDegrees = headingDegrees

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
            onDebugTick: onDebugTick,
            onStartPlacementDebugUpdate: onStartPlacementDebugUpdate
        )
    }
}
