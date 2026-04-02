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

struct RecordRunView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var dataStore: DataStore

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
                                .fill(Color.orange.opacity(0.75))
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
        }
    }

    // MARK: - Location Beacon

    private var locationBeacon: some View {
        ZStack {
            // Outer pulsing ring
            Circle()
                .stroke(Color.orange.opacity(beaconPulse ? 0.25 : 0.55), lineWidth: 1.5)
                .frame(width: beaconPulse ? 52 : 44, height: beaconPulse ? 52 : 44)
                .shadow(color: .orange.opacity(0.6), radius: 8)

            // Inner ring
            Circle()
                .stroke(Color.orange.opacity(0.8), lineWidth: 1.5)
                .frame(width: 34, height: 34)

            // Core dot with glow
            Circle()
                .fill(Color.orange)
                .frame(width: 14, height: 14)
                .shadow(color: .orange, radius: 8)
                .shadow(color: .orange.opacity(0.5), radius: 14)
        }
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: beaconPulse)
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        VStack(spacing: 12) {
            // Four stat columns
            HStack(spacing: 0) {
                statColumn(title: "Distance",
                           value: String(format: "%.2f", currentDistanceMiles),
                           unit: "mi")
                Spacer()
                statColumn(title: "Time",
                           value: formatTime(elapsedTime),
                           unit: nil)
                Spacer()
                statColumn(title: "Altitude",
                           value: String(format: "%.0f", locationService.currentAltitude * 3.281),
                           unit: "ft")
                Spacer()
                statColumn(title: "Points",
                           value: "\(locationService.recordedPoints.count)",
                           unit: nil)
            }
            .padding(.horizontal, 4)

            // Quality pills
            HStack(spacing: 8) {
                neonQualityPill(
                    "Match \(Int(locationService.preciseCaptureQuality.matchedSampleRatio * 100))%",
                    ok: locationService.preciseCaptureQuality.matchedSampleRatio >= 0.65)
                neonQualityPill(
                    "Features \(Int(locationService.preciseCaptureQuality.averageFeaturePoints))",
                    ok: locationService.preciseCaptureQuality.averageFeaturePoints >= 75)
                neonQualityPill(
                    "Track \(Int(locationService.preciseCaptureQuality.averageTrackingScore * 100))%",
                    ok: locationService.preciseCaptureQuality.averageTrackingScore >= 0.65)
            }

            // Status line
            Text(locationService.preciseCaptureStatus)
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.95))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statColumn(title: String, value: String, unit: String?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private func neonQualityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption2).fontWeight(.medium)
            .foregroundColor(ok ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                Capsule()
                    .stroke(ok ? Color.green : Color.orange, lineWidth: 1.2)
            )
            .shadow(color: (ok ? Color.green : Color.orange).opacity(0.7), radius: 5)
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: $selectedMode) {
            Label("Tight", systemImage: "house.fill").tag(RecordingMode.tight)
            Label("Vast",  systemImage: "figure.run").tag(RecordingMode.vast)
        }
        .pickerStyle(.segmented)
        .colorMultiply(.white)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        let isRecording = locationService.isRecording
        let label  = isRecording ? "Stop Run"  : "Start Run"
        let icon   = isRecording ? "stop.fill"  : "record.circle.fill"
        let color  = isRecording ? Color.red    : Color.green
        let glow   = isRecording ? Color.red    : Color.green

        return Button(action: toggleRecording) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                Text(label)
                    .font(.system(size: 20, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(color)
            .clipShape(Capsule())
            .shadow(color: glow.opacity(0.6), radius: 16, x: 0, y: 4)
            .shadow(color: glow.opacity(0.35), radius: 28, x: 0, y: 8)
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
