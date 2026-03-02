import SwiftUI
import MapKit

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

    var body: some View {
        NavigationView {
            ZStack {
                // Map
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
                .onChange(of: locationService.currentLocation) { location in
                    if let location = location {
                        withAnimation {
                            region.center = location.coordinate
                        }
                    }
                }

                // Overlay stats
                VStack {
                    if locationService.isRecording {
                        statsOverlay
                    }

                    Spacer()

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
                        Text("GPS Points")
                        Spacer()
                        Text("\(locationService.recordedPoints.count)")
                            .foregroundColor(.secondary)
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
                    .disabled(routeName.trimmingCharacters(in: .whitespaces).isEmpty)
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
            // Stop
            _ = locationService.stopRecording()
            timer?.invalidate()
            timer = nil

            if locationService.recordedPoints.count >= 2 {
                routeName = "Run \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                showingSaveSheet = true
            }
        } else {
            // Start
            elapsedTime = 0
            locationService.startRecording()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsedTime += 1
            }
        }
    }

    private func saveRoute() {
        let route = RecordedRoute(name: routeName, points: locationService.recordedPoints)
        dataStore.saveRoute(route)
        locationService.recordedPoints = []
        showingSaveSheet = false
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
