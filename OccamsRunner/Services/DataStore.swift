import Foundation

/// Persists routes, quests, and run sessions to disk using JSON files.
class DataStore: ObservableObject {
    @Published var routes: [RecordedRoute] = []
    @Published var quests: [Quest] = []
    @Published var runSessions: [RunSession] = []

    private let fileManager = FileManager.default
    private let customDirectory: URL?

    private var documentsDirectory: URL {
        customDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var routesURL: URL { documentsDirectory.appendingPathComponent("routes.json") }
    private var questsURL: URL { documentsDirectory.appendingPathComponent("quests.json") }
    private var sessionsURL: URL { documentsDirectory.appendingPathComponent("sessions.json") }

    private let hardResetVersionKey = "didHardResetForDualTrackV2"

    init() {
        self.customDirectory = nil
        performOneTimeHardResetIfNeeded()
        loadAll()
    }

    /// Designated initializer for testing. Uses a custom directory instead of the app's documents folder.
    init(directory: URL) {
        self.customDirectory = directory
        loadAll()
    }

    // MARK: - World Map Sidecar

    /// Returns the path for a per-route encrypted world map binary file.
    /// Storing the map separately keeps routes.json small (ARWorldMaps are 2–10 MB each).
    private func worldMapURL(for routeId: UUID) -> URL {
        documentsDirectory.appendingPathComponent("worldmap_\(routeId.uuidString).bin")
    }

    // MARK: - Routes

    func saveRoute(_ route: RecordedRoute) {
        var routeToStore = route
        if let mapData = route.encryptedWorldMapData {
            do {
                try mapData.write(to: worldMapURL(for: route.id), options: .atomic)
            } catch {
                print("Failed to write world map sidecar for \(route.id): \(error)")
            }
            routeToStore.encryptedWorldMapData = nil
        }
        routes.append(routeToStore)
        persist(routes, to: routesURL)
    }

    func deleteRoute(_ route: RecordedRoute) {
        routes.removeAll { $0.id == route.id }
        // Also delete associated quests and world map sidecar
        quests.removeAll { $0.routeId == route.id }
        try? fileManager.removeItem(at: worldMapURL(for: route.id))
        persist(routes, to: routesURL)
        persist(quests, to: questsURL)
    }

    func route(for id: UUID) -> RecordedRoute? {
        guard var r = routes.first(where: { $0.id == id }) else { return nil }
        if let mapData = try? Data(contentsOf: worldMapURL(for: id)) {
            r.encryptedWorldMapData = mapData
        }
        return r
    }

    // MARK: - Quests

    func saveQuest(_ quest: Quest) {
        if let index = quests.firstIndex(where: { $0.id == quest.id }) {
            quests[index] = quest
        } else {
            quests.append(quest)
        }
        persist(quests, to: questsURL)
    }

    func deleteQuest(_ quest: Quest) {
        quests.removeAll { $0.id == quest.id }
        persist(quests, to: questsURL)
    }

    func quests(for routeId: UUID) -> [Quest] {
        quests.filter { $0.routeId == routeId }
    }

    func updateQuestItem(questId: UUID, itemId: UUID, collected: Bool) {
        guard let qi = quests.firstIndex(where: { $0.id == questId }),
              let ii = quests[qi].items.firstIndex(where: { $0.id == itemId }) else { return }
        quests[qi].items[ii].collected = collected
        persist(quests, to: questsURL)
    }

    func resetQuestProgress(questId: UUID) {
        guard let qi = quests.firstIndex(where: { $0.id == questId }) else { return }
        quests[qi].resetProgress()
        persist(quests, to: questsURL)
    }

    // MARK: - Run Sessions

    func saveSession(_ session: RunSession) {
        if let index = runSessions.firstIndex(where: { $0.id == session.id }) {
            runSessions[index] = session
        } else {
            runSessions.append(session)
        }
        persist(runSessions, to: sessionsURL)
    }

    /// Returns the most-recent paused-and-unfinished session for the given quest,
    /// or `nil` if the quest has no paused run in progress.
    func activePausedSession(for questId: UUID) -> RunSession? {
        runSessions
            .filter { $0.questId == questId && $0.isPaused && $0.endTime == nil }
            .sorted { $0.startTime > $1.startTime }
            .first
    }

    /// Creates (or refreshes) a paused-run marker for `questId` and persists it.
    /// Quest item progress is already saved per-item; this session flag lets
    /// QuestDetailView show the "Resume AR Run" button.
    func savePausedSession(for questId: UUID) {
        // If a paused session already exists, nothing to create — just re-persist.
        guard activePausedSession(for: questId) == nil else {
            persist(runSessions, to: sessionsURL)
            return
        }
        var session = RunSession(questId: questId)
        session.isPaused = true
        runSessions.append(session)
        persist(runSessions, to: sessionsURL)
    }

    /// Clears (ends) any open paused session for `questId` so "Resume AR Run"
    /// disappears from QuestDetailView after the user finishes or explicitly exits.
    func clearPausedSession(for questId: UUID) {
        let now = Date()
        for index in runSessions.indices
        where runSessions[index].questId == questId
           && runSessions[index].isPaused
           && runSessions[index].endTime == nil {
            runSessions[index].isPaused = false
            runSessions[index].endTime = now
        }
        persist(runSessions, to: sessionsURL)
    }

    // MARK: - Persistence

    private func performOneTimeHardResetIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hardResetVersionKey) else { return }

        let urls = [routesURL, questsURL, sessionsURL]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }

        defaults.set(true, forKey: hardResetVersionKey)
    }

    private func loadAll() {
        routes = load(from: routesURL) ?? []
        quests = load(from: questsURL) ?? []
        runSessions = load(from: sessionsURL) ?? []
    }

    private func persist<T: Encodable>(_ data: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: url, options: .atomic)
        } catch {
            print("Failed to save data to \(url.lastPathComponent): \(error)")
        }
    }

    private func load<T: Decodable>(from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            // Log the full error so schema mismatches are immediately visible in Xcode console.
            print("‼️ DataStore: failed to decode \(url.lastPathComponent): \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let ctx):
                    print("   Missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                case .typeMismatch(let type, let ctx):
                    print("   Type mismatch: expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                default:
                    break
                }
            }
            return nil
        }
    }
}
