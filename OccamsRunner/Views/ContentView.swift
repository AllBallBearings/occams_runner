import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        TabView {
            RecordRunView()
                .tabItem {
                    Label("Record", systemImage: "figure.run")
                }

            RoutesListView()
                .tabItem {
                    Label("Routes", systemImage: "map")
                }

            QuestsListView()
                .tabItem {
                    Label("Quests", systemImage: "star.circle")
                }
        }
        .accentColor(.orange)
    }
}
