import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import MapKit

// MARK: - Heading Manager

private final class HeadingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Degrees from north, clockwise. -1 = no reading received yet.
    @Published var degrees: Double = -1
    /// CLHeading.headingAccuracy in degrees. -1 = invalid / not calibrated.
    @Published var accuracy: Double = -1
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
        DispatchQueue.main.async {
            self.degrees = d
            self.accuracy = newHeading.headingAccuracy
        }
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

// MARK: - Target Compass (HUD)

/// Floating 3D-looking HUD compass shown in the bottom third of the screen
/// during the alignment phase.  The whole disc is tilted forward with a
/// perspective transform so it reads as a compass plate hovering over the
/// ground.  The needle points at the orange GPS ring.
///
/// `bearingDegrees` follows the convention used by ARCoordinator:
///   0° = ring is straight ahead
///   + = ring is to the right
///   − = ring is to the left
///   ±180 = ring is behind the runner
/// When nil, the compass dims out (no target).
private struct TargetCompassView: View {
    let bearingDegrees: Double?

    // Tilt applied to the whole dial for the 3D effect.
    private let tiltDegrees: Double = 55
    private let dialSize: CGFloat = 160

    var body: some View {
        let hasTarget = bearingDegrees != nil
        let bearing = bearingDegrees ?? 0

        VStack(spacing: 0) {
            ZStack {
                // ── Ground shadow pool (sits "under" the disc) ────────────
                Ellipse()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: dialSize * 0.95, height: dialSize * 0.2)
                    .blur(radius: 10)
                    .offset(y: dialSize * 0.42)

                // ── Tilted dial stack ─────────────────────────────────────
                ZStack {
                    // Thick metallic bezel (outer ring).
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(white: 0.35),
                                    Color(white: 0.10),
                                    Color(white: 0.45),
                                    Color(white: 0.08),
                                    Color(white: 0.35)
                                ]),
                                center: .center
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)

                    // Recessed face — darker radial gradient for depth.
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.92),
                                    Color.black.opacity(0.92)
                                ]),
                                center: UnitPoint(x: 0.4, y: 0.35),
                                startRadius: 4,
                                endRadius: dialSize * 0.55
                            )
                        )
                        .padding(10)
                        .overlay(
                            Circle()
                                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                                .padding(10)
                        )

                    // Tick marks every 30°.
                    ForEach(0..<12) { i in
                        Rectangle()
                            .fill(i % 3 == 0
                                  ? Color.white.opacity(0.8)
                                  : Color.white.opacity(0.35))
                            .frame(
                                width: i % 3 == 0 ? 2.5 : 1.5,
                                height: i % 3 == 0 ? 12 : 7
                            )
                            .offset(y: -(dialSize / 2 - 18))
                            .rotationEffect(.degrees(Double(i) * 30))
                    }

                    // Fixed cardinal tick at 12 o'clock (runner's forward).
                    Triangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 12, height: 14)
                        .offset(y: -(dialSize / 2 - 4))
                        .shadow(color: .white.opacity(0.5), radius: 2)

                    // Rotating needle — points at the ring.
                    compassNeedle
                        .rotationEffect(.degrees(bearing))
                        .animation(.easeOut(duration: 0.18), value: bearing)

                    // Glass highlight overlay for a domed feel.
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.0),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .padding(10)
                        .allowsHitTesting(false)

                    // Center pivot cap (raised).
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color(white: 0.9),
                                        Color(white: 0.35)
                                    ]),
                                    center: UnitPoint(x: 0.35, y: 0.35),
                                    startRadius: 0, endRadius: 8
                                )
                            )
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(width: dialSize, height: dialSize)
                // 3D tilt: pitch the disc forward so it looks like a
                // compass plate hovering above the ground.
                .rotation3DEffect(
                    .degrees(tiltDegrees),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.7
                )
                .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 14)
            }

            // Label below the dial.
            Text("TO START")
                .font(.system(size: 10, weight: .black))
                .kerning(2)
                .foregroundColor(.orange.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1))
                )
                .padding(.top, 6)
        }
        .opacity(hasTarget ? 1.0 : 0.35)
        .animation(.easeInOut(duration: 0.25), value: hasTarget)
    }

    /// The rotating needle.  Rendered with orange target blade, thin tail,
    /// and an emissive shadow so it appears to float slightly above the dial.
    private var compassNeedle: some View {
        ZStack {
            // Target blade — points at +Y (up in local space; rotation 0 = up).
            Triangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.85, blue: 0.35),
                            Color(red: 1.0, green: 0.45, blue: 0.05),
                            Color(red: 0.85, green: 0.25, blue: 0.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 20, height: dialSize * 0.40)
                .offset(y: -dialSize * 0.20)
                .shadow(color: .orange.opacity(0.85), radius: 6)
                .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 3)

            // Tail — thin capsule with a soft gradient.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.8),
                            Color.white.opacity(0.25)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 5, height: dialSize * 0.25)
                .offset(y: dialSize * 0.125)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 2)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to:    CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
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
    /// 0–1 screen-glow intensity while the runner is pointing the phone at
    /// the start ring during the navigate-to-start phase.
    @State private var ringGlowIntensity: Double = 0
    /// Signed horizontal bearing (degrees) from camera forward to the GPS
    /// start ring.  0 = ahead, + = right, − = left.  Nil when not available.
    /// Drives the HUD compass needle.
    @State private var ringBearing: Double? = nil

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
                        compassHeading: headingManager.degrees,
                        compassHeadingAccuracy: headingManager.accuracy,
                        onAlignmentUpdate: { state, confidence, distance, ready in
                            alignmentState     = state
                            alignmentConfidence = confidence
                            distanceToStart    = distance
                            alignmentReady     = ready
                        },
                        onNearestItemDistance: { nearest in nearestItemDistance = nearest },
                        onItemCollected:       { itemId in handleCollection(itemId: itemId) },
                        onDebugTick:           { log in debugTickLog = log },
                        onRingGlowIntensity:   { intensity in ringGlowIntensity = intensity },
                        onRingBearing:         { bearing in ringBearing = bearing }
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                    // Enable manual-alignment gestures only after the runner has
                    // reached the start gate.  Phase 1 (moveToStart) is pure
                    // navigation — nothing to drag yet.
                    if (runMode == .aligning || runMode == .realigning)
                        && alignmentState != .moveToStart {
                        alignmentGestureLayer
                    }

                    // Screen-edge hazy glow that intensifies when the camera
                    // is pointing at the GPS ring — helps the runner spot it
                    // on the horizon.
                    if alignmentState == .moveToStart {
                        ringGlowOverlay
                            .allowsHitTesting(false)
                    }

                    // 3D-looking HUD compass anchored in the bottom third of
                    // the screen.  Needle rotates to point at the orange GPS
                    // ring.  Shown for the whole alignment phase so the runner
                    // always has a visible target direction.
                    if runMode == .aligning || runMode == .realigning {
                        GeometryReader { geo in
                            TargetCompassView(bearingDegrees: ringBearing)
                                .position(
                                    x: geo.size.width / 2,
                                    y: geo.size.height * 0.72
                                )
                        }
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                    }

                    // ── HUD ─────────────────────────────────────────────
                    VStack(spacing: 0) {
                        if alignmentState == .moveToStart {
                            moveToStartTopBar
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                        } else {
                            topHUDCard
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                        }

                        Spacer()

                        debugOverlay

                        if runMode == .running {
                            runningBottomHUD(route: route)
                        } else if alignmentState != .moveToStart {
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
        VStack(alignment: .leading, spacing: 10) {
            if runMode == .running {
                // ── Compact running header ──────────────────────────
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: .green.opacity(0.5), radius: 4)
                    
                    Text("QUEST ACTIVE")
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(.white)
                        .kerning(1.5)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                        Text(String(format: "%.0f%%", alignmentConfidence * 100))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(alignmentConfidence >= 0.75 ? .green : .orange)
                    
                    Button(action: { runMode = .realigning }) {
                        Image(systemName: "location.north.line")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    Button(action: { handleDismissTap() }) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            } else {
                // ── Alignment detail ────────────────────────────────
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alignmentState.rawValue.uppercased())
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.white)
                            .kerning(1.2)
                        
                        if let distanceToStart {
                            Label(
                                String(format: "%.0f ft to start", distanceToStart * 3.281),
                                systemImage: "mappin.and.ellipse"
                            )
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.7))
                        }
                        
                        HStack(spacing: 12) {
                            Text(String(format: "Confidence: %.0f%%", alignmentConfidence * 100))
                                .foregroundColor(alignmentReady ? .green : .orange)
                            
                            if let accuracy = locationService.currentLocation?.horizontalAccuracy {
                                Text(String(format: "GPS: ±%.0f m", accuracy))
                                    .foregroundColor(.orange.opacity(0.8))
                            }
                        }
                        .font(.system(size: 10, weight: .bold))

                        if manualAlignment.hasAdjustment {
                            Text("MANUAL OFFSET ACTIVE")
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                    Button(action: { handleDismissTap() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.5), .cyan.opacity(0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 15, x: 0, y: 8)
    }

    // MARK: - Running Bottom HUD

    private func runningBottomHUD(route: RecordedRoute) -> some View {
        VStack(spacing: 0) {
            // Floating badges (right-aligned, mid-screen)
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    coinBadge
                    distanceBadge
                }
                .padding(.trailing, 20)
            }
            .padding(.bottom, 20)

            // Bottom row
            HStack(alignment: .bottom, spacing: 12) {
                // Left: compass + mini-map
                VStack(alignment: .leading, spacing: 12) {
                    CompassView(heading: headingManager.degrees)
                        .shadow(color: .black.opacity(0.3), radius: 10)
                    miniMap(route: route)
                }
                .padding(.leading, 20)

                Spacer()

                // Right: stats panel
                VStack(alignment: .trailing, spacing: 12) {
                    statsPanel
                }
                .padding(.trailing, 20)
            }
            .padding(.bottom, 40)
        }
    }

    // MARK: - Coin Badge

    private var coinBadge: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.2)).frame(width: 32, height: 32)
                Text("🪙").font(.system(size: 18))
            }
            
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(liveQuest.collectedItems)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("/ \(liveQuest.totalItems)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                Text("COINS")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.orange)
                    .kerning(1.0)
            }
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .orange.opacity(0.15), radius: 10)
    }

    // MARK: - Distance Badge

    private var distanceBadge: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.2)).frame(width: 32, height: 32)
                Image(systemName: "figure.run")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.cyan)
            }
            
            VStack(alignment: .leading, spacing: 0) {
                Text(distanceString)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("DISTANCE")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.cyan)
                    .kerning(1.0)
            }
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .cyan.opacity(0.15), radius: 10)
    }

    // MARK: - Stats Panel (Pace + Nearest Coin)

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Text(currentPaceString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }

            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.orange)
                Text(nearestCoinString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("to next")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 12)
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
                    Circle().fill(Color.cyan.opacity(0.8)).frame(width: 2.5, height: 2.5)
                }
            }
            .environment(\.colorScheme, .dark)
            .disabled(true)
            .frame(width: 130, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
            )

            Text("LIVE MAP")
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(8)
        }
        .shadow(color: .black.opacity(0.4), radius: 12)
    }

    // MARK: - Alignment Bottom

    private var alignmentBottomLayout: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                alignmentHint(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "SHIFT")
                alignmentHint(icon: "arrow.up.left.and.arrow.down.right", label: "DEPTH")
                alignmentHint(icon: "arrow.2.circlepath", label: "ROTATE")
            }

            if manualAlignment.hasAdjustment {
                Button(action: { manualAlignment.reset() }) {
                    Label("RESET POSITION", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .black))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
            }

            Button(action: { runMode = .running }) {
                HStack {
                    Text(runMode == .realigning ? "RESUME QUEST" : "START QUEST")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 18, weight: .black))
                .kerning(1.5)
                .padding(.horizontal, 40).padding(.vertical, 20)
                .background(
                    alignmentReady 
                    ? LinearGradient(colors: [Color.green, Color(red: 0, green: 0.7, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                )
                .foregroundColor(.white.opacity(alignmentReady ? 1.0 : 0.5))
                .clipShape(Capsule())
                .shadow(color: alignmentReady ? .green.opacity(0.4) : .clear, radius: 15, x: 0, y: 8)
            }
            .disabled(!alignmentReady)

            if !alignmentReady {
                Text(alignmentStateInstruction)
                    .font(.system(size: 12, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 40)
            }
        }
        .padding(.bottom, 50)
    }

    private func alignmentHint(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
            Text(label)
                .font(.system(size: 8, weight: .black))
        }
        .foregroundColor(.white.opacity(0.5))
    }

    private var alignmentStateInstruction: String {
        switch alignmentState {
        case .moveToStart: return "WALK TO THE START POINT"
        case .scanning:    return "SCAN SURROUNDINGS SLOWLY"
        case .lowConfidence: return "LOW CONFIDENCE - KEEP SCANNING"
        case .locked:      return ""
        }
    }

    // MARK: - Move-to-Start Phase UI (Phase 1)

    /// Minimal top bar shown during the navigate-to-start phase: just distance
    /// + a dismiss button.  The in-AR 3D arrow + GPS ring do all the directional
    /// work, so the screen UI stays out of the way.
    private var moveToStartTopBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WALK TO START")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.white)
                    .kerning(2)

                if headingManager.degrees < 0 || headingManager.accuracy < 0 || headingManager.accuracy >= 30 {
                    HStack(spacing: 5) {
                        Image(systemName: "location.north.fill")
                            .foregroundColor(.yellow)
                        Text("Calibrating compass – wave device in a figure-8")
                            .foregroundColor(.yellow)
                    }
                    .font(.system(size: 11, weight: .semibold))
                } else if let dist = distanceToStart {
                    Text(String(format: "%.0f ft away", dist * 3.281))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                } else {
                    Text("Acquiring GPS…")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Spacer()

            Button(action: { handleDismissTap() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(10)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
    }

    /// Hazy orange edge glow that fades in as the runner aims the phone at
    /// the GPS start ring.  Driven by `ringGlowIntensity` (0…1) from the AR
    /// coordinator.  Thickens via a radial gradient so the centre stays
    /// unobstructed.
    private var ringGlowOverlay: some View {
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height)
            let alpha = max(0, min(1, ringGlowIntensity)) * 0.65

            ZStack {
                // Outer radial haze — darker at edges, clear in the middle.
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.orange.opacity(0),
                        Color.orange.opacity(alpha * 0.35),
                        Color.orange.opacity(alpha * 0.90)
                    ]),
                    center: .center,
                    startRadius: size * 0.15,
                    endRadius: size * 0.75
                )
                .blendMode(.screen)

                // Soft centre bloom — gives the "aimed" sensation when ring
                // is dead-centre of the viewport.
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.orange.opacity(alpha * 0.55),
                        Color.orange.opacity(0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.35
                )
                .blendMode(.plusLighter)
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.18), value: ringGlowIntensity)
        }
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
            // Dim the AR scene
            Color.black.opacity(0.72).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    QuestCompleteCard(
                        quest: liveQuest,
                        route: route,
                        onClaim: {
                            dataStore.clearPausedSession(for: quest.id)
                            dismiss()
                        }
                    )
                    Spacer(minLength: 40)
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
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

// MARK: - Quest Complete Card

private struct QuestCompleteCard: View {
    let quest: Quest
    let route: RecordedRoute?
    let onClaim: () -> Void

    @State private var starsIn = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 4) {
                Text("QUEST")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.orange)
                    .kerning(4)
                Text("COMPLETE")
                    .font(.system(size: 38, weight: .black))
                    .foregroundColor(.white)
            }
            .padding(.top, 10)

            // 5 animated stars
            HStack(spacing: 12) {
                ForEach(0..<5) { i in
                    Image(systemName: "star.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .shadow(color: .orange.opacity(0.5), radius: 8)
                        .scaleEffect(starsIn ? 1.0 : 0.2)
                        .opacity(starsIn ? 1 : 0)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.6)
                                .delay(Double(i) * 0.1),
                            value: starsIn
                        )
                }
            }

            // 3D route map
            if let route {
                Route3DMapPreview(route: route)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                LinearGradient(
                                    colors: [.orange.opacity(0.6), .orange.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .shadow(color: .orange.opacity(0.2), radius: 20)
            }

            // Stats row
            HStack(spacing: 20) {
                statTile(
                    icon: "dollarsign.circle.fill",
                    label: "COINS",
                    value: "\(quest.totalItems)",
                    color: .orange)
                
                statTile(
                    icon: "figure.run",
                    label: "DISTANCE",
                    value: String(format: "%.1fkm", (route?.totalDistanceMeters ?? 0) / 1000),
                    color: .cyan)
            }

            // Claim Rewards button
            Button(action: onClaim) {
                HStack {
                    Text("CLAIM REWARDS")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 18, weight: .black))
                .kerning(1.5)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.6, blue: 0),
                                 Color(red: 1, green: 0.3, blue: 0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
                .shadow(color: .orange.opacity(0.4), radius: 15, x: 0, y: 8)
            }
        }
        .padding(30)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 40)
        .padding(.horizontal, 20)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                starsIn = true
            }
        }
    }

    private func statTile(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .black))
                    .kerning(1.0)
            }
            .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Float Clamping Helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
