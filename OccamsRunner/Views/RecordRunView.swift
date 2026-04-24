import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#endif

// Small wrapper so Map can show both track dots and the user location beacon
// as typed annotation items.
private enum MapPin: Identifiable {
    case trackPoint(RoutePoint)
    case userLocation(CLLocationCoordinate2D)

    var id: String {
        switch self {
        case .trackPoint(let p): return p.id.uuidString
        case .userLocation:      return "user-location"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .trackPoint(let p): return p.coordinate
        case .userLocation(let c): return c
        }
    }
}

private enum RecordingCountdownPhase {
    case idle, countdown, active
}

struct RecordRunView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
    )
    @State private var showingSaveSheet = false
    @State private var routeName = ""
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var selectedMode: RecordingMode = .vast
    @State private var saveErrorMessage: String?
    @State private var didCopyDebugLog = false
    @State private var beaconPulse = false

    @State private var countdownPhase: RecordingCountdownPhase = .idle
    @State private var countdownValue: Int = 5
    @State private var countdownTimer: Timer?

    // MARK: - Computed map pins

    private var mapPins: [MapPin] {
        var pins: [MapPin] = locationService.isRecording
            ? locationService.recordedPoints.map { .trackPoint($0) }
            : []
        if let loc = locationService.currentLocation {
            pins.append(.userLocation(loc.coordinate))
        }
        return pins
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // ── Full-bleed dark map ──────────────────────────────────
                Map(coordinateRegion: $region,
                    showsUserLocation: false,
                    annotationItems: mapPins) { pin in
                    MapAnnotation(coordinate: pin.coordinate) {
                        switch pin {
                        case .trackPoint:
                            Circle()
                                .fill(Color.orange.opacity(0.60))
                                .frame(width: 6, height: 6)
                        case .userLocation:
                            locationBeacon
                        }
                    }
                }
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
                .onAppear {
                    locationService.startUpdating()
                    if let loc = locationService.currentLocation {
                        region.center = loc.coordinate
                    }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        beaconPulse = true
                    }
                }
                .onChange(of: locationService.currentLocation) { loc in
                    if let loc {
                        withAnimation(.easeOut(duration: 0.4)) {
                            region.center = loc.coordinate
                        }
                    }
                }

                // ── Stats overlay (top) ──────────────────────────────────
                statsOverlay
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // ── Bottom controls ──────────────────────────────────────
                VStack(spacing: 0) {
                    Spacer()
                    if !locationService.isRecording {
                        modePicker
                            .padding(.horizontal, 40)
                            .padding(.bottom, 14)
                    }
                    actionButton
                        .padding(.horizontal, 28)
                        .padding(.bottom, 36)
                }
            }
            .navigationTitle("Record Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showingSaveSheet) {
                saveRouteSheet
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background: locationService.handleAppBackgrounded()
                case .active:     locationService.handleAppForegrounded()
                default: break
                }
            }
        }
        .overlay {
            if countdownPhase == .countdown {
                holdSteadyOverlay
            }
        }
    }

    // MARK: - Location Beacon

    private var locationBeacon: some View {
        ZStack {
            // Outer pulsing ring
            Circle()
                .stroke(Color.orange.opacity(beaconPulse ? 0.10 : 0.25), lineWidth: 1)
                .frame(width: beaconPulse ? 56 : 48, height: beaconPulse ? 56 : 48)
                .shadow(color: .orange.opacity(0.25), radius: 10)

            // Inner ring
            Circle()
                .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                .frame(width: 36, height: 36)
                .shadow(color: .white.opacity(0.2), radius: 4)

            // Core dot with glow
            Circle()
                .fill(LinearGradient(
                    colors: [.orange, Color(red: 1, green: 0.6, blue: 0.2)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 16, height: 16)
                .shadow(color: .orange.opacity(0.50), radius: 8)
        }
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: beaconPulse)
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        return VStack(spacing: 14) {
            // Four stat columns
            HStack(spacing: 0) {
                statColumn(title: "DISTANCE",
                           value: String(format: "%.2f", currentDistanceMiles),
                           unit: "mi")
                Spacer()
                statColumn(title: "TIME",
                           value: formatTime(elapsedTime),
                           unit: nil)
                Spacer()
                statColumn(title: "ALTITUDE",
                           value: String(format: "%.0f", locationService.currentAltitude * 3.281),
                           unit: "ft")
                Spacer()
                statColumn(title: "POINTS",
                           value: "\(locationService.recordedPoints.count)",
                           unit: nil)
            }
            .padding(.horizontal, 8)

            // Quality pills
            HStack(spacing: 10) {
                glassQualityPill(
                    "Match \(Int(locationService.preciseCaptureQuality.matchedSampleRatio * 100))%",
                    ok: locationService.preciseCaptureQuality.matchedSampleRatio >= 0.65)
                glassQualityPill(
                    "Features \(Int(locationService.preciseCaptureQuality.averageFeaturePoints))",
                    ok: locationService.preciseCaptureQuality.averageFeaturePoints >= 75)
                glassQualityPill(
                    "Track \(Int(locationService.preciseCaptureQuality.averageTrackingScore * 100))%",
                    ok: locationService.preciseCaptureQuality.averageTrackingScore >= 0.65)
            }

            // Status line
            Text(locationService.preciseCaptureStatus.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(darkText.opacity(0.45))
                .kerning(1.2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 16, x: 6, y: 6)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 12, x: -4, y: -4)
    }

    private func statColumn(title: String, value: String, unit: String?) -> some View {
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        return VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(darkText.opacity(0.45))
                .kerning(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(darkText)
                if let unit {
                    Text(unit)
                        .font(.caption2).fontWeight(.bold)
                        .foregroundColor(darkText.opacity(0.35))
                }
            }
        }
    }

    private func glassQualityPill(_ label: String, ok: Bool) -> some View {
        let okColor   = Color(red: 0.20, green: 0.55, blue: 0.30)
        let warnColor = Color(red: 0.75, green: 0.40, blue: 0.15)
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(ok ? okColor : warnColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(red: 0.68, green: 0.70, blue: 0.82))
            .clipShape(Capsule())
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: $selectedMode) {
            Label("Tight", systemImage: "house.fill").tag(RecordingMode.tight)
            Label("Vast",  systemImage: "figure.run").tag(RecordingMode.vast)
        }
        .pickerStyle(.segmented)
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action Button

    private var actionButton: some View {
        let isRecording = locationService.isRecording
        let label  = isRecording ? "STOP RUN"  : "START RUN"
        let icon   = isRecording ? "stop.fill"  : "play.fill"
        let color1 = isRecording ? Color(red: 0.9, green: 0.1, blue: 0.2) : Color(red: 0.1, green: 0.8, blue: 0.4)
        let color2 = isRecording ? Color(red: 0.7, green: 0.0, blue: 0.1) : Color(red: 0.0, green: 0.6, blue: 0.3)
        let glow   = isRecording ? Color.red : Color.green

        return Button(action: toggleRecording) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                Text(label)
                    .font(.system(size: 18, weight: .bold))
                    .kerning(1.5)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                LinearGradient(colors: [color1, color2], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(Capsule())
            .shadow(color: glow.opacity(0.25), radius: 15, x: 0, y: 8)
        }
    }

    // MARK: - Save Sheet

    private var saveRouteSheet: some View {
        NavigationView {
            Form {
                Section("Route Details") {
                    TextField("Route Name", text: $routeName)

                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(String(format: "%.2f miles", currentDistanceMiles))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Duration")
                        Spacer()
                        Text(formatTime(elapsedTime))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Geo Samples")
                        Spacer()
                        Text("\(locationService.recordedPoints.count)")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Precise AR Quality") {
                    HStack {
                        Text("Matched Samples")
                        Spacer()
                        Text("\(Int(locationService.preciseCaptureQuality.matchedSampleRatio * 100))%")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Feature Density")
                        Spacer()
                        Text("\(Int(locationService.preciseCaptureQuality.averageFeaturePoints))")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Tracking Score")
                        Spacer()
                        Text("\(Int(locationService.preciseCaptureQuality.averageTrackingScore * 100))%")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Encrypted World Map")
                        Spacer()
                        Image(systemName: locationService.preciseCaptureQuality.hasEncryptedWorldMap
                              ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(locationService.preciseCaptureQuality.hasEncryptedWorldMap
                                             ? .green : .orange)
                    }

                    Text(locationService.preciseCaptureStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    let blockers = locationService.saveBlockerDescription
                    if !blockers.isEmpty {
                        Text("Save blocked:\n\(blockers)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Debug Log") {
                    if let path = locationService.currentCaptureLogPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Button(didCopyDebugLog ? "Copied" : "Copy Debug Log") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = locationService.captureDebugLogText
                        #endif
                        didCopyDebugLog = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            didCopyDebugLog = false
                        }
                    }
                    .disabled(locationService.captureDebugLogText.isEmpty)

                    if !locationService.captureDebugLogLines.isEmpty {
                        ScrollView {
                            Text(locationService.captureDebugLogLines.suffix(20).joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, maxHeight: 220)
                    }
                }
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        showingSaveSheet = false
                        locationService.recordedPoints = []
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let nameOk = !routeName.trimmingCharacters(in: .whitespaces).isEmpty
                        let qualityOk = locationService.canSavePreciseRoute
                        if nameOk && qualityOk {
                            saveRoute()
                        } else {
                            var reasons: [String] = []
                            if !nameOk { reasons.append("route name is empty") }
                            let blockers = locationService.saveBlockerDescription
                            if !blockers.isEmpty { reasons.append(blockers) }
                            locationService.logSaveAttemptBlocked(reasons: reasons)
                            saveErrorMessage = "Cannot save — see blockers above."
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hold Steady Overlay

    private var holdSteadyOverlay: some View {
        ZStack {
            Color.black.opacity(0.80).ignoresSafeArea()

            VStack(spacing: 28) {
                Text("HOLD STEADY")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(.orange)
                    .kerning(3)

                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.25), lineWidth: 6)
                        .frame(width: 130, height: 130)
                    Circle()
                        .stroke(Color.orange, lineWidth: 3)
                        .frame(width: 130, height: 130)
                    Text("\(countdownValue)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(spacing: 10) {
                    instructionRow(icon: "iphone", text: "Hold phone at chest height")
                    instructionRow(icon: "arrow.up", text: "Face forward — direction you'll start running")
                    instructionRow(icon: "figure.stand", text: "Stand still until the countdown ends")
                }

                let tracking = Int(locationService.preciseCaptureQuality.averageTrackingScore * 100)
                HStack(spacing: 8) {
                    Circle()
                        .fill(tracking >= 40 ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(tracking >= 40
                         ? "AR scanning — ready"
                         : "Scanning environment… \(tracking)%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(40)
        }
        .transition(.opacity)
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .frame(width: 28)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Helpers

    private var currentDistanceMiles: Double {
        guard locationService.recordedPoints.count > 1 else { return 0 }
        var dist: Double = 0
        let pts = locationService.recordedPoints
        for i in 1..<pts.count {
            dist += pts[i].location.distance(from: pts[i - 1].location)
        }
        return dist / 1609.344
    }

    private func toggleRecording() {
        if locationService.isRecording {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownPhase = .idle
            locationService.stopRecording()
            timer?.invalidate()
            timer = nil
            if locationService.recordedPoints.count >= 2 {
                routeName = "Run \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                saveErrorMessage = nil
                didCopyDebugLog = false
                showingSaveSheet = true
            }
        } else {
            elapsedTime = 0
            locationService.startRecording(mode: selectedMode)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsedTime += 1
            }
            startHoldSteadyCountdown()
        }
    }

    private func startHoldSteadyCountdown() {
        countdownValue = 5
        withAnimation { countdownPhase = .countdown }
        var elapsed = 0
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            elapsed += 1
            let tracking = locationService.preciseCaptureQuality.averageTrackingScore
            let hasGeo   = !locationService.recordedPoints.isEmpty
            // Dismiss early only after at least 3 seconds so the user has time to read
            if countdownValue <= 1 || (elapsed >= 3 && tracking >= 0.4 && hasGeo) {
                t.invalidate()
                countdownTimer = nil
                withAnimation { countdownPhase = .active }
            } else {
                countdownValue -= 1
            }
        }
    }

    private func saveRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let route = locationService.buildRecordedRoute(name: name) else {
            saveErrorMessage = "Route capture quality is below required threshold. Keep scanning and re-record."
            return
        }
        dataStore.saveRoute(route)
        locationService.recordedPoints = []
        saveErrorMessage = nil
        showingSaveSheet = false
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
