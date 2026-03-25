import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import MapKit

// MARK: - Heading Manager

private final class HeadingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var degrees: Double = 0
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let d = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        DispatchQueue.main.async { self.degrees = d }
    }
}

// MARK: - Compass View

private struct CompassView: View {
    let heading: Double

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.72))
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)

            // Rotating card
            ZStack {
                // Tick marks at 45° intervals
                ForEach(0..<8) { i in
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: 4)
                        .offset(y: -19)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                // Cardinal labels
                Text("N").font(.system(size: 8, weight: .bold)).foregroundColor(.red)
                    .offset(y: -13)
                Text("S").font(.system(size: 7)).foregroundColor(.white.opacity(0.6))
                    .offset(y: 13)
                Text("E").font(.system(size: 7)).foregroundColor(.white.opacity(0.6))
                    .offset(x: 13)
                Text("W").font(.system(size: 7)).foregroundColor(.white.opacity(0.6))
                    .offset(x: -13)
                // Needle
                VStack(spacing: 0) {
                    Capsule().fill(Color.red).frame(width: 3, height: 10)
                    Circle().fill(Color.white).frame(width: 4, height: 4)
                    Capsule().fill(Color.white.opacity(0.65)).frame(width: 3, height: 10)
                }
            }
            .rotationEffect(.degrees(-heading))

            // Center dot
            Circle().fill(Color.white).frame(width: 3, height: 3)
        }
        .frame(width: 54, height: 54)
    }
}

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

    @State private var manualAlignment = ManualAlignmentState()

    // Run tracking
    @StateObject private var headingManager = HeadingManager()
    @State private var runDistanceKm: Double = 0
    @State private var lastRunLocation: CLLocation?

    private let panSensitivity: Float   = 0.004
    private let depthSensitivity: Float = 4.0
    private let maxLateral: Float = 3.0
    private let maxVertical: Float = 2.0
    private let maxDepth:   Float = 5.0

    private var route: RecordedRoute? { dataStore.route(for: quest.routeId) }
    private var liveQuest: Quest {
        dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if let route {
                if route.encryptedWorldMapData == nil {
                    noARDataView
                } else {
                    ARRunnerContainerView(
                        route: route,
                        quest: quest,
                        dataStore: dataStore,
                        locationService: locationService,
                        runMode: runMode,
                        manualAlignment: manualAlignment,
                        onAlignmentUpdate: { state, confidence, distance, ready in
                            alignmentState     = state
                            alignmentConfidence = confidence
                            distanceToStart    = distance
                            alignmentReady     = ready
                        },
                        onNearestItemDistance: { nearest in nearestItemDistance = nearest },
                        onItemCollected:       { itemId in handleCollection(itemId: itemId) },
                        onDebugTick:           { log in debugTickLog = log }
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                    if runMode == .aligning || runMode == .realigning {
                        alignmentGestureLayer
                    }

                    // ── Full HUD ────────────────────────────────────────
                    VStack(spacing: 0) {
                        topHUDCard
                            .padding(.top, 8)
                            .padding(.horizontal, 16)

                        Spacer()

                        debugOverlay

                        if runMode == .running {
                            runningBottomHUD(route: route)
                        } else {
                            alignmentBottomLayout
                        }
                    }
                }
            } else {
                Color.black.ignoresSafeArea()
                Text("Route not found for this quest.")
                    .foregroundColor(.white)
            }

            if showingCompletionAlert { questCompleteOverlay }
        }
        .onAppear {
            locationService.startUpdating()
            if liveQuest.isComplete { showingCompletionAlert = true }
        }
        .onChange(of: locationService.currentLocation) { loc in
            guard runMode == .running, let loc else { return }
            if let last = lastRunLocation {
                let delta = loc.distance(from: last)
                if delta < 100 { runDistanceKm += delta / 1000.0 }
            }
            lastRunLocation = loc
        }
        .onChange(of: runMode) { mode in
            if mode == .running {
                runDistanceKm = 0
                lastRunLocation = locationService.currentLocation
            }
        }
        .onReceive(dataStore.$quests) { _ in
            if liveQuest.isComplete { showingCompletionAlert = true }
        }
        .confirmationDialog("Pause or Exit Run?",
                            isPresented: $showingPauseDialog,
                            titleVisibility: .visible) {
            Button("Pause Run")         { pauseAndDismiss() }
            Button("Exit Run", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pausing saves your progress. You can resume from the Quest screen.")
        }
    }

    // MARK: - Alignment Gesture Layer

    private var alignmentGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        let dx = Float(v.translation.width)  * panSensitivity
                        let dy = Float(-v.translation.height) * panSensitivity
                        manualAlignment.worldX = (manualAlignment.baseX + dx)
                            .clamped(to: -maxLateral...maxLateral)
                        manualAlignment.worldY = (manualAlignment.baseY + dy)
                            .clamped(to: -maxVertical...maxVertical)
                    }
                    .onEnded { _ in manualAlignment.commitGesture() }
            )
            .simultaneousGesture(
                RotationGesture(minimumAngleDelta: .degrees(2))
                    .onChanged { angle in
                        manualAlignment.rotationY = manualAlignment.baseRotation + Float(angle.radians)
                    }
                    .onEnded { _ in manualAlignment.commitGesture() }
            )
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0.02)
                    .onChanged { scale in
                        let delta = -Float(scale - 1.0) * depthSensitivity
                        manualAlignment.worldZ = (manualAlignment.baseZ + delta)
                            .clamped(to: -maxDepth...maxDepth)
                    }
                    .onEnded { _ in manualAlignment.commitGesture() }
            )
    }

    // MARK: - Top HUD Card

    private var topHUDCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if runMode == .running {
                // ── Compact running header ──────────────────────────
                HStack(spacing: 10) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("AR Quest in Progress")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.0f%%", alignmentConfidence * 100))
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundColor(alignmentConfidence >= 0.75 ? .green : .orange)
                    Button(action: { runMode = .realigning }) {
                        Label("Realign", systemImage: "location.north.line")
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }
                    Button(action: { handleDismissTap() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundColor(.white.opacity(0.7))
                    }
                }
            } else {
                // ── Alignment detail ────────────────────────────────
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(alignmentState.rawValue)
                            .font(.headline).foregroundColor(.white)
                        if let distanceToStart {
                            Label(
                                String(format: "%.0f ft to start", distanceToStart * 3.281),
                                systemImage: "mappin.and.ellipse"
                            )
                            .font(.caption).foregroundColor(.white.opacity(0.85))
                        }
                        Text(String(format: "Confidence: %.0f%%", alignmentConfidence * 100))
                            .font(.caption2)
                            .foregroundColor(alignmentReady ? .green : .orange)
                        if let accuracy = locationService.currentLocation?.horizontalAccuracy {
                            Text(String(format: "GPS: ±%.0f m", accuracy))
                                .font(.caption2).foregroundColor(.orange)
                        }
                        if manualAlignment.hasAdjustment {
                            Text(String(format: "X %.2f  Y %.2f  Z %.2f  R %.1f°",
                                        manualAlignment.worldX,
                                        manualAlignment.worldY,
                                        manualAlignment.worldZ,
                                        manualAlignment.rotationY * 180 / .pi))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.85))
                        }
                    }
                    Spacer()
                    Button(action: { handleDismissTap() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundColor(.white.opacity(0.8))
                    }
                }

                Divider().background(Color.white.opacity(0.2))

                // Subtitle always at bottom of card
                HStack {
                    Spacer()
                    Text("AR Quest in Progress")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.cyan.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .cyan.opacity(0.25), radius: 8)
    }

    // MARK: - Running Bottom HUD

    private func runningBottomHUD(route: RecordedRoute) -> some View {
        VStack(spacing: 0) {
            // Floating badges (right-aligned, mid-screen)
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    coinBadge
                    distanceBadge
                }
                .padding(.trailing, 16)
            }
            .padding(.bottom, 14)

            // Bottom row
            HStack(alignment: .bottom, spacing: 8) {
                // Left: compass + mini-map
                VStack(alignment: .leading, spacing: 8) {
                    CompassView(heading: headingManager.degrees)
                    miniMap(route: route)
                }
                .padding(.leading, 16)

                Spacer()

                // Right: pace panel + pause
                VStack(alignment: .trailing, spacing: 8) {
                    statsPanel
                    Button(action: { handleDismissTap() }) {
                        Text("Pause")
                            .font(.callout).fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Coin Badge

    private var coinBadge: some View {
        HStack(spacing: 7) {
            Text("🪙")
                .font(.system(size: 20))
            Text("\(liveQuest.collectedItems)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("/ \(liveQuest.totalItems)")
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .orange.opacity(0.25), radius: 6)
    }

    // MARK: - Distance Badge

    private var distanceBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "figure.run")
                .font(.body).foregroundColor(.cyan)
            Text(distanceString)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.45), lineWidth: 1.5)
        )
        .shadow(color: .cyan.opacity(0.2), radius: 6)
    }

    // MARK: - Stats Panel (Pace + Nearest Coin)

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .foregroundColor(.white.opacity(0.65))
                Text("Pace:").foregroundColor(.white.opacity(0.55))
                Text(currentPaceString)
                    .foregroundColor(.white).fontWeight(.semibold)
            }
            .font(.subheadline)

            HStack(spacing: 8) {
                Image(systemName: "location.circle")
                    .foregroundColor(.orange)
                Text("Next coin:").foregroundColor(.white.opacity(0.55))
                Text(nearestCoinString)
                    .foregroundColor(.white).fontWeight(.semibold)
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Mini-Map

    private func miniMap(route: RecordedRoute) -> some View {
        let coords = route.geoTrack.map { $0.coordinate }
        let region = routeRegion(from: coords)

        return ZStack(alignment: .topLeading) {
            Map(coordinateRegion: .constant(region),
                showsUserLocation: true,
                annotationItems: route.geoTrack) { sample in
                MapAnnotation(coordinate: sample.coordinate) {
                    Circle().fill(Color.cyan.opacity(0.8)).frame(width: 3, height: 3)
                }
            }
            .environment(\.colorScheme, .dark)
            .disabled(true)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.cyan.opacity(0.45), lineWidth: 1.5)
            )

            Text("Route")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(5)
        }
        .shadow(color: .black.opacity(0.45), radius: 6)
    }

    // MARK: - Alignment Bottom

    private var alignmentBottomLayout: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("Drag to shift", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("Pinch for depth", systemImage: "arrow.up.left.and.arrow.down.right")
                Label("Twist to rotate", systemImage: "arrow.2.circlepath")
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.7))

            if manualAlignment.hasAdjustment {
                Button(action: { manualAlignment.reset() }) {
                    Label("Reset Position", systemImage: "arrow.counterclockwise")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.white)
                }
            }

            Button(action: { runMode = .running }) {
                Text(runMode == .realigning ? "Resume Run →" : "Start Run →")
                    .font(.headline).fontWeight(.bold)
                    .padding(.horizontal, 40).padding(.vertical, 16)
                    .background(alignmentReady ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(color: alignmentReady ? .green.opacity(0.5) : .clear, radius: 10)
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
                        Text("Low confidence — try scanning from a different angle.")
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

    // MARK: - Debug Overlay

    private var debugOverlay: some View {
        Group {
            if !debugTickLog.isEmpty {
                Text(debugTickLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - No AR Data

    private var noARDataView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48)).foregroundColor(.orange)
                Text("AR Precision Data Missing")
                    .font(.headline).foregroundColor(.white)
                Text("This route was not recorded with AR precision data.\nRe-record the route to enable precise AR placement.")
                    .font(.caption).multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 32)
                Button("Dismiss") { dismiss() }
                    .padding(.horizontal, 32).padding(.vertical, 12)
                    .background(Color.orange).foregroundColor(.white)
                    .clipShape(Capsule())
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

    // MARK: - Quest Complete Overlay

    private var questCompleteOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.yellow.opacity(0.35), Color.clear],
                            center: .center, startRadius: 20, endRadius: 80
                        ))
                        .frame(width: 160, height: 160)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(LinearGradient(
                            colors: [Color(red: 1, green: 0.84, blue: 0), .orange],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .padding(.top, 36).padding(.bottom, 12)

                Text("Quest Complete!")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(liveQuest.name)
                    .font(.subheadline).foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 4)

                HStack(spacing: 8) {
                    Text("🪙")
                    Text("\(liveQuest.totalItems) of \(liveQuest.totalItems) coins collected")
                        .fontWeight(.semibold)
                }
                .font(.callout).foregroundColor(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
                .padding(.top, 20)

                Button {
                    dataStore.clearPausedSession(for: quest.id)
                    dismiss()
                } label: {
                    Text("Finish")
                        .font(.headline).fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.yellow)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                        .padding(.horizontal, 32)
                }
                .padding(.top, 28).padding(.bottom, 36)
            }
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial))
            .padding(.horizontal, 28)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showingCompletionAlert)
    }

    // MARK: - Collection

    private func handleCollection(itemId: UUID) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        if liveQuest.isComplete { showingCompletionAlert = true }
    }

    // MARK: - Helpers

    private var distanceString: String {
        runDistanceKm < 1.0
            ? String(format: "%.0f m", runDistanceKm * 1000)
            : String(format: "%.2f km", runDistanceKm)
    }

    private var currentPaceString: String {
        guard let speed = locationService.currentLocation?.speed, speed > 0.5 else {
            return "--:--  /km"
        }
        let secPerKm = 1000.0 / speed
        let mins = Int(secPerKm) / 60
        let secs = Int(secPerKm) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    private var nearestCoinString: String {
        guard let d = nearestItemDistance else { return "—" }
        return String(format: "%.0f ft", d * 3.281)
    }

    private func routeRegion(from coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coords.isEmpty else { return MKCoordinateRegion() }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude:  (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((lats.max()! - lats.min()!) * 1.3, 0.0002),
                longitudeDelta: max((lons.max()! - lons.min()!) * 1.3, 0.0002)
            )
        )
    }
}

// MARK: - Float Clamping Helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
