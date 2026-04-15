import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            RoutesListView()
                .tabItem {
                    Label("Routes", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                }

            QuestsListView()
                .tabItem {
                    Label("Quests", systemImage: "trophy")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .accentColor(.orange)
    }
}
