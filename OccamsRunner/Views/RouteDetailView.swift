import SwiftUI
import MapKit

struct RouteDetailView: View {
    @EnvironmentObject var dataStore: DataStore
    let route: RecordedRoute

    @State private var showingQuestCreator = false
    @State private var coinIntervalFeet: Double = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Route map preview
                routeMapPreview
                    .frame(height: 250)
                    .cornerRadius(12)
                    .padding(.horizontal)

                // Stats
                statsSection

                // 3D View button
                NavigationLink(destination: Route3DView(route: route)) {
                    Label("View in 3D", systemImage: "cube")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Create Quest button
                Button(action: { showingQuestCreator = true }) {
                    Label("Create Quest", systemImage: "star.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Existing quests for this route
                existingQuests
            }
            .padding(.vertical)
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQuestCreator) {
            questCreatorSheet
        }
    }

    // MARK: - Map Preview

    private var routeMapPreview: some View {
        Map(coordinateRegion: .constant(routeRegion),
            annotationItems: route.points) { point in
            MapAnnotation(coordinate: point.coordinate) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }
        }
        .disabled(true)
    }

    private var routeRegion: MKCoordinateRegion {
        guard !route.points.isEmpty else {
            return MKCoordinateRegion()
        }
        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.3 + 0.002,
            longitudeDelta: (maxLon - minLon) * 1.3 + 0.002
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                statCard(title: "Distance", value: String(format: "%.2f mi", route.totalDistanceMiles), icon: "figure.run")
                statCard(title: "Duration", value: formatDuration(route.durationSeconds), icon: "clock")
            }
            HStack(spacing: 24) {
                statCard(
                    title: route.netElevationChangeMeters >= 0 ? "Elevation Gain" : "Elevation Loss",
                    value: String(format: "%.0f ft", abs(route.netElevationChangeMeters) * 3.281),
                    icon: route.netElevationChangeMeters >= 0 ? "arrow.up.right" : "arrow.down.right"
                )
                statCard(title: "GPS Points", value: "\(route.points.count)", icon: "mappin.circle")
            }
        }
        .padding(.horizontal)
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 30)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.headline)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Existing Quests

    private var existingQuests: some View {
        let routeQuests = dataStore.quests(for: route.id)

        return Group {
            if !routeQuests.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quests")
                        .font(.title3)
                        .fontWeight(.bold)
                        .padding(.horizontal)

                    ForEach(routeQuests) { quest in
                        NavigationLink(destination: QuestDetailView(quest: quest)) {
                            questRow(quest)
                        }
                    }
                }
            }
        }
    }

    private func questRow(_ quest: Quest) -> some View {
        HStack {
            Image(systemName: "star.circle.fill")
                .foregroundColor(.orange)
                .font(.title2)

            VStack(alignment: .leading) {
                Text(quest.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("\(quest.totalItems) coins - \(quest.totalPoints) pts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if quest.collectedItems > 0 {
                Text("\(quest.collectedItems)/\(quest.totalItems)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    // MARK: - Quest Creator

    private var questCreatorSheet: some View {
        NavigationView {
            QuestEditorView(route: route, isPresented: $showingQuestCreator)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
