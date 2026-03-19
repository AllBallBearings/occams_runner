import SwiftUI
import ARKit
import SceneKit
import CoreLocation

// MARK: - AR Runner View

struct ARRunnerView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var locationService: LocationService
    @Environment(\.dismiss) private var dismiss

    let quest: Quest

    @State private var showingCompletionAlert = false
    @State private var showingPauseDialog = false
    @State private var nearestItemDistance: Double?
    @State private var runMode: ARRunMode = .aligning
    @State private var debugTickLog: String = ""

    @State private var alignmentState: ARAlignmentState = .moveToStart
    @State private var alignmentConfidence: Double = 0
    @State private var distanceToStart: Double?
    @State private var alignmentReady = false

    private var route: RecordedRoute? {
        dataStore.route(for: quest.routeId)
    }

    private var liveQuest: Quest {
        dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
    }

    var body: some View {
        ZStack {
            if let route {
                if route.encryptedWorldMapData == nil {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("AR Precision Data Missing")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("This route was not recorded with AR precision data and cannot be replayed in AR.\nRe-record the route to enable precise AR placement.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 32)
                        Button("Dismiss") { dismiss() }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                } else {
                    ARRunnerContainerView(
                        route: route,
                        quest: quest,
                        dataStore: dataStore,
                        locationService: locationService,
                        runMode: runMode,
                        onAlignmentUpdate: { state, confidence, distance, ready in
                            alignmentState = state
                            alignmentConfidence = confidence
                            distanceToStart = distance
                            alignmentReady = ready
                        },
                        onNearestItemDistance: { nearest in
                            nearestItemDistance = nearest
                        },
                        onItemCollected: { itemId in
                            handleCollection(itemId: itemId)
                        },
                        onDebugTick: { log in
                            debugTickLog = log
                        }
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }
            } else {
                Color.black.ignoresSafeArea()
                Text("Route not found for this quest.")
                    .foregroundColor(.white)
            }

            if route?.encryptedWorldMapData != nil {
                if runMode == .aligning || runMode == .realigning {
                    VStack {
                        alignmentTopBanner
                        Spacer()
                        alignmentBottomControls
                    }
                } else {
                    VStack {
                        runningHUD
                        Spacer()
                        debugOverlay
                        bottomBar
                    }
                }
            }
        }
        .onAppear {
            locationService.startUpdating()
            if liveQuest.isComplete {
                showingCompletionAlert = true
            }
        }
        .onReceive(dataStore.$quests) { _ in
            if liveQuest.isComplete {
                showingCompletionAlert = true
            }
        }
        .alert("Quest Complete!", isPresented: $showingCompletionAlert) {
            Button("Finish") {
                // Quest is done — clear any paused session marker.
                dataStore.clearPausedSession(for: quest.id)
                dismiss()
            }
        } message: {
            Text("You collected all \(liveQuest.totalItems) coins!")
        }
        .confirmationDialog(
            "Pause or Exit Run?",
            isPresented: $showingPauseDialog,
            titleVisibility: .visible
        ) {
            Button("Pause Run") {
                pauseAndDismiss()
            }
            Button("Exit Run", role: .destructive) {
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pausing saves your progress. You can resume from the Quest screen.")
        }
    }

    // MARK: - Alignment HUD

    private var alignmentTopBanner: some View {
        HStack(alignment: .top) {
            VStack(spacing: 5) {
                Text(alignmentState.rawValue)
                    .font(.headline)
                    .foregroundColor(.white)

                if let distanceToStart {
                    Text(String(format: "Distance to start: %.0f ft", distanceToStart * 3.281))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }

                Text(String(format: "Alignment confidence: %.0f%%", alignmentConfidence * 100))
                    .font(.caption2)
                    .foregroundColor(alignmentReady ? .green : .orange)

                if let accuracy = locationService.currentLocation?.horizontalAccuracy {
                    Text(String(format: "GPS: ±%.0f m", accuracy))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: { handleDismissTap() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }

    private var alignmentBottomControls: some View {
        VStack(spacing: 12) {
            Button(action: { runMode = .running }) {
                Text(runMode == .realigning ? "Resume Run →" : "Start Run →")
                    .font(.headline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(alignmentReady ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .disabled(!alignmentReady)

            if !alignmentReady {
                Group {
                    switch alignmentState {
                    case .moveToStart:
                        Text("Walk to within 40 ft of where you started recording.")
                    case .scanning:
                        Text("Move your phone around slowly to scan the environment.")
                    case .lowConfidence:
                        Text("Low confidence — try scanning from a different angle or retrace a few steps.")
                    case .locked:
                        EmptyView()
                    }
                }
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 48)
    }

    // MARK: - Running HUD

    private var runningHUD: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.circle.fill")
                    .foregroundColor(.yellow)
                Text("\(liveQuest.collectedItems)/\(liveQuest.totalItems)")
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer()

            Text(String(format: "Align %.0f%%", alignmentConfidence * 100))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(alignmentConfidence >= 0.75 ? .green : .orange)
                .lineLimit(1)
                .fixedSize()

            Button(action: { runMode = .realigning }) {
                Label("Realign", systemImage: "location.north.line")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }

            Button(action: { handleDismissTap() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack {
            if let distance = nearestItemDistance {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle")
                        .foregroundColor(.orange)
                    Text(String(format: "Next coin: %.0f ft", distance * 3.281))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Debug

    private var debugOverlay: some View {
        Group {
            if !debugTickLog.isEmpty {
                Text(debugTickLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Dismiss / Pause

    /// Called by both X buttons. Shows the pause dialog when a run is active;
    /// dismisses immediately if the user is still in the initial alignment phase.
    private func handleDismissTap() {
        if runMode == .running || runMode == .realigning {
            showingPauseDialog = true
        } else {
            dismiss()
        }
    }

    /// Saves a paused-run marker to the data store so QuestDetailView can show
    /// the "Resume AR Run" button, then dismisses the AR screen.
    private func pauseAndDismiss() {
        dataStore.savePausedSession(for: quest.id)
        dismiss()
    }

    // MARK: - Collection

    private func handleCollection(itemId: UUID) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}
