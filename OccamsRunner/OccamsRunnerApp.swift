import SwiftUI

@main
struct OccamsRunnerApp: App {
    @StateObject private var dataStore: DataStore
    @StateObject private var locationService = LocationService()

    init() {
        // When running UI tests, use an isolated temp directory so tests don't
        // touch or corrupt the user's real data.
        let env = ProcessInfo.processInfo.environment
        if env["UI_TESTING"] == "1" {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "OccamsRunnerUITests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let store = DataStore(directory: tempDir)
            if env["LOAD_FIXTURE_ROUTES"] == "1" {
                OccamsRunnerApp.loadUITestFixtures(into: store)
            }
            _dataStore = StateObject(wrappedValue: store)
        } else {
            _dataStore = StateObject(wrappedValue: DataStore())
        }
    }

    @State private var showSplash = ProcessInfo.processInfo.environment["UI_TESTING"] != "1"

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(dataStore)
                    .environmentObject(locationService)
                    .onAppear {
                        if ProcessInfo.processInfo.environment["UI_TESTING"] != "1" {
                            locationService.requestPermission()
                        }
                    }

                if showSplash {
                    SplashScreenView(isShowing: $showSplash)
                        .zIndex(1)
                }
            }
        }
    }

    /// Injects two pre-built routes (one with a quest) for UI testing.
    private static func loadUITestFixtures(into store: DataStore) {
        let metersPerDegreeLon = cos(37.33182 * .pi / 180) * 111_320.0
        func makePoint(_ index: Int, altitude: Double = 50.0) -> RoutePoint {
            RoutePoint(latitude: 37.33182,
                       longitude: -122.03118 + Double(index) * 30.0 / metersPerDegreeLon,
                       altitude: altitude,
                       timestamp: Date(timeIntervalSince1970: Double(index) * 30))
        }

        let points1 = (0...20).map { makePoint($0) }
        let route1 = RecordedRoute(name: "Morning Loop", points: points1)
        store.saveRoute(route1)

        let items = QuestGenerator.generateItems(along: route1, intervalFeet: 20)
        let quest = Quest(name: "Morning Loop Quest", routeId: route1.id, items: items)
        store.saveQuest(quest)

        let points2 = (0...10).map { makePoint($0, altitude: Double($0) * 2 + 40) }
        let route2 = RecordedRoute(name: "Hill Climb", points: points2)
        store.saveRoute(route2)
    }
}
