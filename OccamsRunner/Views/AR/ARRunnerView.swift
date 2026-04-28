import ARKit
import CoreLocation
import MapKit
import SceneKit
import SwiftUI

// MARK: - Compass View

private struct CompassView: View {
  let heading: Double
  var startBearing: Double? = nil  // absolute true-north bearing to start point
  var size: CGFloat = 54
  var isProminent: Bool = false

  private var tickRadius: CGFloat { size * 0.36 }
  private var cardinalRadius: CGFloat { size * 0.25 }
  private var needleLength: CGFloat { size * 0.19 }
  private var markerRadius: CGFloat { size * 0.31 }

  var body: some View {
    ZStack {
      if isProminent {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white.opacity(0.18),
                Color.black.opacity(0.82),
              ],
              center: .topLeading,
              startRadius: 2,
              endRadius: size * 0.64
            )
          )
        Circle()
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.18),
                Color.clear,
                Color.black.opacity(0.38),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      } else {
        Circle().fill(Color.black.opacity(0.72))
      }
      Circle().stroke(
        Color.white.opacity(isProminent ? 0.38 : 0.25), lineWidth: isProminent ? 1.5 : 1)

      // Rotating card
      ZStack {
        // Tick marks at 45° intervals
        ForEach(0..<8) { i in
          Rectangle()
            .fill(Color.white.opacity(isProminent ? 0.5 : 0.35))
            .frame(width: isProminent ? 2 : 1, height: size * 0.075)
            .offset(y: -tickRadius)
            .rotationEffect(.degrees(Double(i) * 45))
        }
        // Cardinal labels
        Text("N").font(.system(size: size * 0.15, weight: .bold)).foregroundColor(.red)
          .offset(y: -cardinalRadius)
        Text("S").font(.system(size: size * 0.13)).foregroundColor(.white.opacity(0.6))
          .offset(y: cardinalRadius)
        Text("E").font(.system(size: size * 0.13)).foregroundColor(.white.opacity(0.6))
          .offset(x: cardinalRadius)
        Text("W").font(.system(size: size * 0.13)).foregroundColor(.white.opacity(0.6))
          .offset(x: -cardinalRadius)
        // Needle
        VStack(spacing: 0) {
          Capsule().fill(Color.red).frame(width: size * 0.055, height: needleLength)
          Circle().fill(Color.white).frame(width: size * 0.075, height: size * 0.075)
          Capsule().fill(Color.white.opacity(0.65)).frame(width: size * 0.055, height: needleLength)
        }
        // Orange dot marking the direction to the start point
        if let startBearing {
          Circle()
            .fill(Color.orange)
            .frame(width: size * 0.12, height: size * 0.12)
            .shadow(color: .orange.opacity(0.75), radius: isProminent ? 8 : 3)
            .offset(y: -markerRadius)
            .rotationEffect(.degrees(startBearing))
        }
      }
      .rotationEffect(.degrees(-heading))

      // Center dot
      Circle().fill(Color.white).frame(width: size * 0.055, height: size * 0.055)
    }
    .frame(width: size, height: size)
    .rotation3DEffect(.degrees(isProminent ? 58 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.65)
    .shadow(
      color: .black.opacity(isProminent ? 0.46 : 0), radius: isProminent ? 18 : 0, x: 0,
      y: isProminent ? 16 : 0
    )
    .overlay(alignment: .topLeading) {
      if isProminent {
        Circle()
          .fill(Color.white.opacity(0.22))
          .frame(width: size * 0.18, height: size * 0.18)
          .blur(radius: 8)
          .offset(x: size * 0.18, y: size * 0.13)
          .allowsHitTesting(false)
      }
    }
  }
}

// MARK: - Start Beacon Overlay

private struct StartBeaconView: View {
  let relativeBearing: Double  // 0=straight ahead, 90=right, 180=behind, 270=left
  let distanceText: String
  @State private var pulse = false

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let radius = min(size.width, size.height) * 0.38
      let angleRad = (relativeBearing - 90) * .pi / 180
      let cx = size.width / 2
      let cy = size.height / 2
      let bx = cx + radius * CGFloat(cos(angleRad))
      let by = cy + radius * CGFloat(sin(angleRad))
      let d = size.width * 0.10

      ZStack {
        // Pulsing outer glow
        Circle()
          .fill(Color.orange.opacity(pulse ? 0.07 : 0.22))
          .frame(width: d * 1.8, height: d * 1.8)
        // Ring
        Circle()
          .stroke(Color.orange.opacity(0.80), lineWidth: 2)
          .frame(width: d, height: d)
        // Core
        Circle()
          .fill(
            RadialGradient(
              colors: [.white.opacity(0.95), .orange],
              center: .center, startRadius: 0, endRadius: d * 0.25)
          )
          .frame(width: d * 0.5, height: d * 0.5)
        // Labels
        VStack(spacing: 1) {
          Text("START")
            .font(.system(size: 7, weight: .black))
            .foregroundColor(.orange)
          Text(distanceText)
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.white.opacity(0.85))
        }
        .offset(y: d * 0.78)
      }
      .position(x: bx, y: by)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
    .allowsHitTesting(false)
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
  /// True when the coordinator is currently using GPS-primary item placement
  /// (either because the route is flagged or ARKit tracking degraded mid-run).
  /// Drives the badge in the alignment / running HUD.
  @State private var placementUsesGPS = false

  @State private var manualAlignment = ManualAlignmentState()

  // Run tracking
  @State private var runDistanceKm: Double = 0
  @State private var lastRunLocation: CLLocation?

  private let panSensitivity: Float = 0.004
  private let depthSensitivity: Float = 4.0
  private let maxLateral: Float = 3.0
  private let maxVertical: Float = 2.0
  private let maxDepth: Float = 5.0

  private var route: RecordedRoute? { dataStore.route(for: quest.routeId) }
  private var liveQuest: Quest {
    dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
  }

  // Absolute true-north bearing from current GPS to the route start point (0–360°).
  private var bearingToStart: Double? {
    guard let current = locationService.currentLocation,
      let startLoc = route?.startLocation
    else { return nil }
    let from = current.coordinate
    let to = startLoc.coordinate
    let lat1 = from.latitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
  }

  // Bearing relative to the direction the camera is facing (0=ahead, 90=right …).
  private var relativeBearingToStart: Double? {
    guard let b = bearingToStart else { return nil }
    let h = locationService.currentHeadingDegrees ?? 0
    return (b - h + 360).truncatingRemainder(dividingBy: 360)
  }

  private var startDistanceText: String {
    guard let d = distanceToStart else { return "" }
    let feet = d * 3.281
    return feet >= 1320
      ? String(format: "%.1f mi", feet / 5280)
      : String(format: "%.0f ft", feet)
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
              alignmentState = state
              alignmentConfidence = confidence
              distanceToStart = distance
              alignmentReady = ready
            },
            onNearestItemDistance: { nearest in nearestItemDistance = nearest },
            onItemCollected: { itemId in handleCollection(itemId: itemId) },
            onDebugTick: { log in debugTickLog = log },
            onPlacementModeChanged: { isGPSPrimary in
              placementUsesGPS = isGPSPrimary
            }
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

          // ── Start beacon: orange orb floating at bearing to start ──
          // Only shown during initial alignment. Mid-quest realignment is
          // anchored at the runner's current position (nearest recorded
          // sample), so pointing them back to the start is misleading.
          if runMode == .aligning,
            let relBearing = relativeBearingToStart
          {
            StartBeaconView(
              relativeBearing: relBearing,
              distanceText: startDistanceText
            )
            .ignoresSafeArea()
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
    .confirmationDialog(
      "Pause or Exit Run?",
      isPresented: $showingPauseDialog,
      titleVisibility: .visible
    ) {
      Button("Pause Run") { pauseAndDismiss() }
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
            let dx = Float(v.translation.width) * panSensitivity
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

          placementModeBadge

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

            // Distance-to-start is only meaningful during initial alignment.
            // Mid-quest realignment anchors at the runner's current position
            // (nearest recorded sample) so this label would be misleading.
            if runMode == .aligning, let distanceToStart {
              let feet = distanceToStart * 3.281
              let distanceLabel =
                feet >= 1320
                ? String(format: "%.1f mi to start", feet / 5280)
                : String(format: "%.0f ft to start", feet)
              Label(distanceLabel, systemImage: "mappin.and.ellipse")
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

            HStack(spacing: 6) {
              placementModeBadge
              if manualAlignment.hasAdjustment {
                Text("MANUAL OFFSET ACTIVE")
                  .font(.system(size: 8, weight: .black))
                  .foregroundColor(.cyan)
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(Color.cyan.opacity(0.1))
                  .clipShape(Capsule())
              }
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
          CompassView(heading: locationService.currentHeadingDegrees ?? 0)
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
      Map(
        coordinateRegion: .constant(region),
        showsUserLocation: true,
        annotationItems: route.geoTrack
      ) { sample in
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
    ZStack(alignment: .bottomLeading) {
      // Centered action controls
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

        CompassView(
          // During mid-quest realignment, drop the orange "to start" indicator
          // — the user is realigning around their current position, not
          // walking back to the start.
          heading: locationService.currentHeadingDegrees ?? 0,
          startBearing: runMode == .realigning ? nil : bearingToStart,
          size: 104,
          isProminent: true
        )
        .padding(.top, 2)
        .padding(.bottom, -2)

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
              ? LinearGradient(
                colors: [Color.green, Color(red: 0, green: 0.7, blue: 0.3)], startPoint: .top,
                endPoint: .bottom)
              : LinearGradient(
                colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .top,
                endPoint: .bottom)
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
      .frame(maxWidth: .infinity)
      .padding(.bottom, 50)
    }
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
    case .moveToStart: return "WALK TO START POINT"
    case .scanning: return "SCAN SURROUNDINGS SLOWLY"
    case .lowConfidence: return "LOW CONFIDENCE - KEEP SCANNING"
    case .locked: return ""
    }
  }

  /// Tiny pill that shows whether item placement is using GPS-only math
  /// (route flagged or ARKit tracking degraded) vs the visual AR path.
  /// Yellow "GPS" = robust-but-coarse mode, dim "AR" = high-precision mode.
  private var placementModeBadge: some View {
    let label = placementUsesGPS ? "GPS" : "AR"
    let icon = placementUsesGPS ? "location.fill" : "camera.viewfinder"
    let color: Color = placementUsesGPS
      ? Color(red: 1.0, green: 0.78, blue: 0.0)
      : Color.white.opacity(0.55)
    return HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .black))
      Text(label)
        .font(.system(size: 8, weight: .black))
        .kerning(0.6)
    }
    .foregroundColor(color)
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(color.opacity(0.12))
    .clipShape(Capsule())
    .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.5))
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
        Text(
          "This route was not recorded with AR precision data.\nRe-record the route to enable precise AR placement."
        )
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
        latitude: (lats.min()! + lats.max()!) / 2,
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
            colors: [
              Color(red: 1, green: 0.6, blue: 0),
              Color(red: 1, green: 0.3, blue: 0),
            ],
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

extension Float {
  fileprivate func clamped(to range: ClosedRange<Float>) -> Float {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
