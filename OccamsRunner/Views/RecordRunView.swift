import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#endif

struct RecordRunView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var dataStore: DataStore

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var showingSaveSheet = false
    @State private var routeName = ""
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var selectedMode: RecordingMode = .vast
    @State private var saveErrorMessage: String?
    @State private var didCopyDebugLog = false

    var body: some View {
        NavigationView {
            ZStack {
                Map(coordinateRegion: $region,
                    showsUserLocation: true,
                    annotationItems: locationService.isRecording ? locationService.recordedPoints : []) { point in
                    MapAnnotation(coordinate: point.coordinate) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }
                .ignoresSafeArea(edges: .top)
                .onAppear {
                    locationService.startUpdating()
                    if let location = locationService.currentLocation {
                        region.center = location.coordinate
                    }
                }
                .onChange(of: locationService.currentLocation) { location in
                    if let location = location {
                        withAnimation {
                            region.center = location.coordinate
                        }
                    }
                }

                VStack {
                    if locationService.isRecording {
                        statsOverlay
                    }

                    Spacer()

                    modePicker
                        .padding(.bottom, 12)

                    recordButton
                        .padding(.bottom, 30)
                }
            }
            .navigationTitle("Record Run")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSaveSheet) {
                saveRouteSheet
            }
        }
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                statItem(
                    title: "Distance",
                    value: String(format: "%.2f mi", currentDistanceMiles)
                )
                statItem(
                    title: "Time",
                    value: formatTime(elapsedTime)
                )
                statItem(
                    title: "Altitude",
                    value: String(format: "%.0f ft", locationService.currentAltitude * 3.281)
                )
                statItem(
                    title: "Points",
                    value: "\(locationService.recordedPoints.count)"
                )
            }

            HStack(spacing: 10) {
                qualityPill(
                    "Match \(Int(locationService.preciseCaptureQuality.matchedSampleRatio * 100))%",
                    ok: locationService.preciseCaptureQuality.matchedSampleRatio >= 0.75
                )
                qualityPill(
                    "Features \(Int(locationService.preciseCaptureQuality.averageFeaturePoints))",
                    ok: locationService.preciseCaptureQuality.averageFeaturePoints >= 100
                )
                qualityPill(
                    "Track \(Int(locationService.preciseCaptureQuality.averageTrackingScore * 100))%",
                    ok: locationService.preciseCaptureQuality.averageTrackingScore >= 0.65
                )
                qualityPill(
                    "Map",
                    ok: locationService.preciseCaptureQuality.hasEncryptedWorldMap
                )
            }

            Text(locationService.preciseCaptureStatus)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
        }
    }

    private func qualityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ok ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundColor(ok ? .green : .orange)
            .clipShape(Capsule())
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: $selectedMode) {
            Label("Tight", systemImage: "house.fill")
                .tag(RecordingMode.tight)
            Label("Vast", systemImage: "figure.run")
                .tag(RecordingMode.vast)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 40)
        .disabled(locationService.isRecording)
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: toggleRecording) {
            HStack {
                Image(systemName: locationService.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                Text(locationService.isRecording ? "Stop Run" : "Start Run")
                    .fontWeight(.bold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(locationService.isRecording ? Color.red : Color.green)
            .cornerRadius(30)
            .shadow(radius: 4)
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
                        Image(systemName: locationService.preciseCaptureQuality.hasEncryptedWorldMap ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(locationService.preciseCaptureQuality.hasEncryptedWorldMap ? .green : .orange)
                    }

                    Text(locationService.preciseCaptureStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)

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
                        saveRoute()
                    }
                    .disabled(
                        routeName.trimmingCharacters(in: .whitespaces).isEmpty
                        || !locationService.canSavePreciseRoute
                    )
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
