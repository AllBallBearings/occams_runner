import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import MapKit

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

    // MARK: - Manual Alignment State
    // Class (reference type) — both this view's gestures and the ARCoordinator
    // read/write the same instance without going through SwiftUI's diffing.
    @State private var manualAlignment = ManualAlignmentState()

    // Sensitivity: meters of route shift per screen-point of drag.
    private let panSensitivity: Float = 0.004
    // Clamp to ±3 m lateral, ±2 m vertical so the user can't
    // accidentally fling the route off into oblivion.
    private let maxLateral: Float = 3.0
    private let maxVertical: Float = 2.0

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
                        manualAlignment: manualAlignment,
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

                    // Gesture capture layer — sits between the AR view and the
                    // HUD controls so button taps still reach the controls on top.
                    if runMode == .aligning || runMode == .realigning {
                        alignmentGestureLayer
                    }
                }
            } else {
                Color.black.ignoresSafeArea()
                Text("Route not found for this quest.")
                    .foregroundColor(.white)
            }

            if route?.encryptedWorldMapData != nil {
                if runMode == .aligning || runMode == .realigning {
                    VStack(spacing: 0) {
                        alignmentTopBanner
                        Spacer()
                        if let route {
                            HStack(alignment: .bottom) {
                                Spacer()
                                alignmentMiniMap(route: route)
                                    .padding(.trailing, 16)
                                    .padding(.bottom, 8)
                            }
                        }
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

    // MARK: - Alignment Gesture Layer

    /// Transparent, full-screen gesture capture layer for the alignment phase.
    /// Uses `.simultaneousGesture` so underlying button taps still register.
    private var alignmentGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let dx = Float(value.translation.width)  * panSensitivity
                        let dy = Float(-value.translation.height) * panSensitivity
                        manualAlignment.worldX = (manualAlignment.baseX + dx)
                            .clamped(to: -maxLateral...maxLateral)
                        manualAlignment.worldY = (manualAlignment.baseY + dy)
                            .clamped(to: -maxVertical...maxVertical)
                    }
                    .onEnded { _ in
                        manualAlignment.commitGesture()
                    }
            )
            .simultaneousGesture(
                RotationGesture(minimumAngleDelta: .degrees(2))
                    .onChanged { angle in
                        manualAlignment.rotationY = manualAlignment.baseRotation + Float(angle.radians)
                    }
                    .onEnded { _ in
                        manualAlignment.commitGesture()
                    }
            )
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

                if manualAlignment.hasAdjustment {
                    Text(String(format: "Offset: X %.2f m  Y %.2f m  R %.1f°",
                                manualAlignment.worldX,
                                manualAlignment.worldY,
                                manualAlignment.rotationY * 180 / .pi))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.85))
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
        VStack(spacing: 10) {
            // Gesture hint
            HStack(spacing: 16) {
                Label("Drag to shift", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("Twist to rotate", systemImage: "arrow.2.circlepath")
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.7))

            // Reset manual offset (only shown when there is an offset)
            if manualAlignment.hasAdjustment {
                Button(action: {
                    manualAlignment.reset()
                }) {
                    Label("Reset Position", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .foregroundColor(.white)
                }
            }

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

    // MARK: - Alignment Mini-Map

    /// Small PiP-style map showing the route and current GPS position.
    /// Lets the user confirm they're at the right physical location while
    /// the AR view is displayed.
    private func alignmentMiniMap(route: RecordedRoute) -> some View {
        let coords = route.geoTrack.map { $0.coordinate }
        let region = routeRegion(from: coords)

        return ZStack(alignment: .topLeading) {
            Map(coordinateRegion: .constant(region),
                showsUserLocation: true,
                annotationItems: route.geoTrack) { sample in
                MapAnnotation(coordinate: sample.coordinate) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 4, height: 4)
                }
            }
            .disabled(true)
            .frame(width: 160, height: 160)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
            )

            Text("Route Map")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
                .padding(5)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
    }

    /// Compute a map region that fits all the route coordinates with padding.
    private func routeRegion(from coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coords.isEmpty else { return MKCoordinateRegion() }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!; let maxLat = lats.max()!
        let minLon = lons.min()!; let maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let spanLat = max(maxLat - minLat, 0.0005) * 1.5
        let spanLon = max(maxLon - minLon, 0.0005) * 1.5
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
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

    private func handleDismissTap() {
        if runMode == .running || runMode == .realigning {
            showingPauseDialog = true
        } else {
            dismiss()
        }
    }

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

// MARK: - Float Clamping Helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
