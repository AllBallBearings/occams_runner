import SwiftUI
import MapKit

/// Allows the user to configure and create a quest along a recorded route.
/// Places coins at route-progress intervals and previews resolved map locations.
struct QuestEditorView: View {
    @EnvironmentObject var dataStore: DataStore
    let route: RecordedRoute
    @Binding var isPresented: Bool

    @State private var questName = ""
    @State private var coinIntervalFeet: Double = 10
    @State private var generatedItems: [QuestItem] = []

    private struct PreviewMarker: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        Form {
            Section("Quest Details") {
                TextField("Quest Name", text: $questName)
            }

            Section("Coin Placement") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coin interval: \(Int(coinIntervalFeet)) feet")
                        .font(.headline)
                    Slider(value: $coinIntervalFeet, in: 5...100, step: 5)
                        .accentColor(.orange)
                    Text("Closer spacing = more coins = more motivation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .onChange(of: coinIntervalFeet) { _ in
                    regenerateItems()
                }
            }

            Section("Preview") {
                if generatedItems.isEmpty {
                    Text("Adjust the interval to generate coins")
                        .foregroundColor(.secondary)
                } else {
                    Text("\(generatedItems.count) coins will be placed along the route")
                        .font(.headline)
                    Text("Total points: \(generatedItems.count * 10)")
                        .foregroundColor(.secondary)

                    Map(coordinateRegion: .constant(routeRegion),
                        annotationItems: previewMarkers) { marker in
                        MapAnnotation(coordinate: marker.coordinate) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 6, height: 6)
                                .overlay(
                                    Circle()
                                        .stroke(Color.orange, lineWidth: 1)
                                )
                        }
                    }
                    .frame(height: 200)
                    .cornerRadius(10)
                }
            }
        }
        .navigationTitle("Create Quest")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isPresented = false
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    createQuest()
                }
                .disabled(questName.trimmingCharacters(in: .whitespaces).isEmpty || generatedItems.isEmpty)
            }
        }
        .onAppear {
            questName = "\(route.name) Quest"
            regenerateItems()
        }
    }

    private var routeRegion: MKCoordinateRegion {
        guard !route.geoTrack.isEmpty else { return MKCoordinateRegion() }
        let lats = route.geoTrack.map(\.latitude)
        let lons = route.geoTrack.map(\.longitude)
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

    private var previewMarkers: [PreviewMarker] {
        generatedItems.compactMap { item in
            guard let sample = route.geoSample(atProgress: item.routeProgress) else { return nil }
            return PreviewMarker(id: item.id, coordinate: sample.coordinate)
        }
    }

    private func regenerateItems() {
        generatedItems = QuestGenerator.generateItems(
            along: route,
            intervalFeet: coinIntervalFeet
        )
    }

    private func createQuest() {
        let quest = Quest(
            name: questName,
            routeId: route.id,
            items: generatedItems
        )
        dataStore.saveQuest(quest)
        isPresented = false
    }
}
