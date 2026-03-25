import SwiftUI
import MapKit

// MARK: - Route Map Snapshot

private struct RouteSnapshotView: View {
    let route: RecordedRoute
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.12)
                    Image(systemName: "map.fill")
                        .foregroundColor(.white.opacity(0.25))
                        .font(.title)
                }
            }
        }
        .task(id: route.id) {
            image = await makeSnapshot()
        }
    }

    private func makeSnapshot() async -> UIImage? {
        let coords = route.geoTrack.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coords.isEmpty else { return nil }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: ((lats.min()! + lats.max()!) / 2),
            longitude: ((lons.min()! + lons.max()!) / 2)
        )
        let spanLat = max((lats.max()! - lats.min()!) * 1.5, 0.001)
        let spanLon = max((lons.max()! - lons.min()!) * 1.5, 0.001)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
        options.size = CGSize(width: 280, height: 240)
        let mapConfig = MKStandardMapConfiguration(elevationStyle: .flat)
        mapConfig.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = mapConfig
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, error in
                guard let snapshot, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
                let img = renderer.image { _ in
                    snapshot.image.draw(at: .zero)
                    let path = UIBezierPath()
                    for (i, coord) in coords.enumerated() {
                        let pt = snapshot.point(for: coord)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    path.lineWidth = 2.5
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    UIColor.cyan.setStroke()
                    path.stroke()
                }
                continuation.resume(returning: img)
            }
        }
    }
}

// MARK: - Routes List View

struct RoutesListView: View {
    @EnvironmentObject var dataStore: DataStore
    @State private var searchText = ""
    @State private var viewMode: RouteViewMode = .ar

    enum RouteViewMode { case ar, map }

    private var filteredRoutes: [RecordedRoute] {
        let sorted = dataStore.routes.sorted { $0.dateRecorded > $1.dateRecorded }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    // Large display title
                    Text("Available Routes Library")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    // Search bar + mode toggle
                    HStack(spacing: 10) {
                        searchBar
                        modeToggle
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    if filteredRoutes.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(filteredRoutes) { route in
                                    NavigationLink(destination: RouteDetailView(route: route)) {
                                        routeCard(route)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.45))
                .font(.body)
            TextField("Search routes...", text: $searchText)
                .foregroundColor(.white)
                .tint(.cyan)
                .font(.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton("AR Mode", mode: .ar)
            modeButton("Map Mode", mode: .map)
        }
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }

    private func modeButton(_ title: String, mode: RouteViewMode) -> some View {
        let active = viewMode == mode
        return Button { viewMode = mode } label: {
            Text(title)
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(active ? .black : .white.opacity(0.65))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(active ? Color.cyan : Color.clear)
                .clipShape(Capsule())
        }
    }

    // MARK: - Route Card

    private func routeCard(_ route: RecordedRoute) -> some View {
        let quest = dataStore.quests(for: route.id).first
        let coinCount = quest?.items.count ?? 0
        let (level, levelLabel) = questLevel(coinCount: coinCount)

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Map thumbnail
                RouteSnapshotView(route: route)
                    .frame(width: 140, height: 115)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Route info
                VStack(alignment: .leading, spacing: 7) {
                    Text(route.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if quest != nil {
                        questInfoRows(level: level, levelLabel: levelLabel, coinCount: coinCount)
                    } else {
                        Text("No quest — tap to create one")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                        Text(String(format: "%.2f mi", route.totalDistanceMiles))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, quest != nil ? 10 : 14)

            // Start Quest button — only when a quest exists
            if quest != nil {
                Text("Start Quest")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.65), lineWidth: 1.5)
        )
        .shadow(color: Color.cyan.opacity(0.3), radius: 10)
    }

    @ViewBuilder
    private func questInfoRows(level: Int, levelLabel: String, coinCount: Int) -> some View {
        // Quest level
        Group {
            Text("Quest Level: \(level): ").foregroundColor(.yellow)
            + Text(levelLabel).foregroundColor(.yellow)
        }
        .font(.caption).fontWeight(.medium)

        // High score — placeholder until run history is tracked
        Group {
            Text("High Score: ").foregroundColor(.orange)
            + Text("0 pts").foregroundColor(.white)
        }
        .font(.caption).fontWeight(.medium)

        // Total coins
        Group {
            Text("Total Coins: \(coinCount) ").foregroundColor(.white)
            + Text("🪙")
        }
        .font(.caption).fontWeight(.medium)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.15))
            Text("No Routes Yet")
                .font(.title2).fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.55))
            Text("Go to the Record tab to capture your first run!")
                .font(.body)
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Quest Level

    private func questLevel(coinCount: Int) -> (level: Int, label: String) {
        switch coinCount {
        case 0:        return (0, "No Quest")
        case 1...10:   return (1, "Coins Only")
        case 11...20:  return (2, "Collect Master")
        case 21...30:  return (3, "Monsters Enabled")
        case 31...40:  return (4, "Challenge Mode")
        default:       return (5, "Boss Battle!")
        }
    }
}
