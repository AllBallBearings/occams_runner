import SwiftUI
import MapKit

struct QuestDetailView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var locationService: LocationService
    let quest: Quest

    @State private var showingARView = false

    private var pausedSession: RunSession? {
        dataStore.activePausedSession(for: quest.id)
    }

    private struct ResolvedMarker: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let collected: Bool
    }

    private var currentQuest: Quest {
        dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
    }

    private var associatedRoute: RecordedRoute? {
        dataStore.route(for: quest.routeId)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                questMap
                    .frame(height: 300)
                    .cornerRadius(12)
                    .padding(.horizontal)

                progressSection
                statsSection
                actionButtons
            }
            .padding(.vertical)
        }
        .navigationTitle(currentQuest.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingARView) {
            ARRunnerView(quest: currentQuest)
        }
    }

    // MARK: - Map

    private var questMap: some View {
        Map(coordinateRegion: .constant(questRegion),
            annotationItems: resolvedMarkers) { marker in
            MapAnnotation(coordinate: marker.coordinate) {
                Circle()
                    .fill(marker.collected ? Color.green.opacity(0.5) : Color.yellow)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(marker.collected ? Color.green : Color.orange, lineWidth: 1)
                    )
            }
        }
    }

    private var resolvedMarkers: [ResolvedMarker] {
        guard let route = associatedRoute else { return [] }
        return currentQuest.items.compactMap { item in
            guard let sample = route.geoSample(atProgress: item.routeProgress) else { return nil }
            return ResolvedMarker(
                id: item.id,
                coordinate: sample.coordinate,
                collected: item.collected
            )
        }
    }

    private var questRegion: MKCoordinateRegion {
        let markers = resolvedMarkers
        guard !markers.isEmpty else { return MKCoordinateRegion() }
        let lats = markers.map { $0.coordinate.latitude }
        let lons = markers.map { $0.coordinate.longitude }
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (lats.max()! - lats.min()!) * 1.3 + 0.002,
            longitudeDelta: (lons.max()! - lons.min()!) * 1.3 + 0.002
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Progress")
                    .font(.headline)
                Spacer()
                Text("\(currentQuest.collectedItems) / \(currentQuest.totalItems)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
            }

            ProgressView(value: Double(currentQuest.collectedItems), total: Double(max(currentQuest.totalItems, 1)))
                .scaleEffect(y: 2)
                .tint(.orange)

            HStack {
                Text("\(currentQuest.collectedPoints) / \(currentQuest.totalPoints) points")
                    .foregroundColor(.secondary)
                Spacer()
                if currentQuest.isComplete {
                    Label("Complete!", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .fontWeight(.bold)
                }
            }
            .font(.caption)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 16) {
            statCard(title: "Total Coins", value: "\(currentQuest.totalItems)", icon: "circle.circle.fill")
            statCard(title: "Collected", value: "\(currentQuest.collectedItems)", icon: "checkmark.circle.fill")
            statCard(title: "Remaining", value: "\(currentQuest.totalItems - currentQuest.collectedItems)", icon: "xmark.circle")
        }
        .padding(.horizontal)
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.orange)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if pausedSession != nil {
                // Resume button — shown prominently when a run was paused.
                Button(action: resumeRun) {
                    Label("Resume AR Run", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                }

                Button(action: { showingARView = true }) {
                    Label("Start New AR Run", systemImage: "arkit")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
            } else {
                Button(action: { showingARView = true }) {
                    Label("Start AR Run", systemImage: "arkit")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .cornerRadius(12)
                }
            }

            if let route = associatedRoute {
                NavigationLink(destination: Route3DView(route: route)) {
                    Label("View Route in 3D", systemImage: "cube")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }

            if currentQuest.collectedItems > 0 {
                Button(action: resetProgress) {
                    Label("Reset Progress", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
    }

    /// Clears the paused-session marker and opens the AR view. The quest items
    /// that were already collected remain collected — the user just needs to
    /// re-align the route in AR before continuing.
    private func resumeRun() {
        dataStore.clearPausedSession(for: quest.id)
        showingARView = true
    }

    private func resetProgress() {
        dataStore.clearPausedSession(for: quest.id)
        dataStore.resetQuestProgress(questId: quest.id)
    }
}
