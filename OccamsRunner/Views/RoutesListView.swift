import SwiftUI

struct RoutesListView: View {
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        NavigationView {
            Group {
                if dataStore.routes.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "map")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Routes Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Go to the Record tab to record your first run!")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(dataStore.routes.sorted(by: { $0.dateRecorded > $1.dateRecorded })) { route in
                            NavigationLink(destination: RouteDetailView(route: route)) {
                                routeRow(route)
                            }
                        }
                        .onDelete(perform: deleteRoutes)
                    }
                }
            }
            .navigationTitle("My Routes")
        }
    }

    private func routeRow(_ route: RecordedRoute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.name)
                .font(.headline)

            HStack(spacing: 16) {
                Label(
                    String(format: "%.2f mi", route.totalDistanceMiles),
                    systemImage: "figure.run"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Label(
                    formatDuration(route.durationSeconds),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Label(
                    String(format: "%.0f ft gain", route.elevationGainMeters * 3.281),
                    systemImage: "arrow.up.right"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text(route.dateRecorded, style: .date)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    private func deleteRoutes(at offsets: IndexSet) {
        let sorted = dataStore.routes.sorted(by: { $0.dateRecorded > $1.dateRecorded })
        for index in offsets {
            dataStore.deleteRoute(sorted[index])
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
