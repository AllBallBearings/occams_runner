import SwiftUI
import MapKit

// MARK: - Route Map Snapshot

struct RouteSnapshotView: View {
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
        if #available(iOS 17.0, *) {
            let mapConfig = MKStandardMapConfiguration(elevationStyle: .flat)
            mapConfig.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = mapConfig
        }
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
                    UIColor(red: 0.18, green: 0.72, blue: 0.70, alpha: 0.9).setStroke()
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

    // Rename state
    @State private var renamingRoute: RecordedRoute? = nil
    @State private var renameText = ""

    enum RouteViewMode { case ar, map }

    private var filteredRoutes: [RecordedRoute] {
        let sorted = dataStore.routes.sorted { $0.dateRecorded > $1.dateRecorded }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground.ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 0) {
                    // Large display title
                    Text("Routes Library")
                        .font(.system(size: 34, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 20)

                    // Search bar + mode toggle
                    VStack(spacing: 16) {
                        searchBar
                        modeToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    if filteredRoutes.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(spacing: 18) {
                                ForEach(filteredRoutes) { route in
                                    NavigationLink(destination: RouteDetailView(route: route)) {
                                        routeCard(route)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            dataStore.deleteRoute(route)
                                        } label: {
                                            Label("Delete Route", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 30)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Rename Route", isPresented: Binding(
                get: { renamingRoute != nil },
                set: { if !$0 { renamingRoute = nil } }
            )) {
                TextField("Route name", text: $renameText)
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let route = renamingRoute, !trimmed.isEmpty {
                        dataStore.renameRoute(route, to: trimmed)
                    }
                    renamingRoute = nil
                }
                Button("Cancel", role: .cancel) { renamingRoute = nil }
            }
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.07, blue: 0.18),
                Color(red: 0.86, green: 0.88, blue: 0.94)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.50))
                .font(.system(size: 16, weight: .bold))
            TextField("Search routes...", text: $searchText)
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.20))
                .tint(Color(red: 0.35, green: 0.55, blue: 0.95))
                .font(.body)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(Capsule())
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 8, x: 4, y: 4)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 6, x: -3, y: -3)
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 4) {
            modeButton("AR MODE", mode: .ar)
            modeButton("MAP MODE", mode: .map)
        }
        .padding(4)
        .background(Color(red: 0.72, green: 0.74, blue: 0.86))
        .clipShape(Capsule())
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 6, x: 3, y: 3)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.35), radius: 4, x: -2, y: -2)
    }

    private func modeButton(_ title: String, mode: RouteViewMode) -> some View {
        let active = viewMode == mode
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                viewMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundColor(active ? darkText : darkText.opacity(0.40))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color(red: 0.76, green: 0.78, blue: 0.88) : Color.clear)
                .clipShape(Capsule())
        }
    }

    // MARK: - Route Card

    private func routeCard(_ route: RecordedRoute) -> some View {
        let quest = dataStore.quests(for: route.id).first
        let coinCount = quest?.items.count ?? 0

        return VStack(spacing: 0) {
            if viewMode == .map {
                mapModeCardContent(route: route, quest: quest, coinCount: coinCount)
            } else {
                arModeCardContent(route: route, quest: quest, coinCount: coinCount)
            }
        }
        .background(Color(red: 0.76, green: 0.78, blue: 0.88))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 12, x: 6, y: 6)
        .shadow(color: Color(red: 0.14, green: 0.16, blue: 0.28).opacity(0.40), radius: 10, x: -4, y: -4)
    }

    // AR Mode — thumbnail left, stats right
    @ViewBuilder
    private func arModeCardContent(route: RecordedRoute, quest: Quest?, coinCount: Int) -> some View {
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        let darkerSurface = Color(red: 0.68, green: 0.70, blue: 0.82)

        HStack(alignment: .top, spacing: 16) {
            RouteSnapshotView(route: route)
                .frame(width: 140, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(darkerSurface, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                nameRow(route: route)

                Text(route.dateRecorded.formatted(date: .abbreviated, time: .omitted).uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(darkText.opacity(0.40))

                if quest != nil {
                    HStack(spacing: 4) {
                        Text("🪙")
                            .font(.system(size: 10))
                        Text("\(coinCount) COINS")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundColor(Color(red: 0.75, green: 0.40, blue: 0.15))
                } else {
                    Text("NO QUEST ACTIVE")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(darkText.opacity(0.30))

                    Text(String(format: "%.2f MILES", route.totalDistanceMiles))
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(Color(red: 0.18, green: 0.72, blue: 0.70).opacity(0.85))
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(14)

        reviewRouteButton
    }

    // Map Mode — full-width live 3D map, condensed info below
    @ViewBuilder
    private func mapModeCardContent(route: RecordedRoute, quest: Quest?, coinCount: Int) -> some View {
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        let darkerSurface = Color(red: 0.68, green: 0.70, blue: 0.82)

        Route3DMapPreview(route: route)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(darkerSurface, lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.top, 14)

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                nameRow(route: route)
                HStack(spacing: 10) {
                    Text(route.dateRecorded.formatted(date: .abbreviated, time: .omitted).uppercased())
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(darkText.opacity(0.40))

                    if quest != nil {
                        Circle().fill(darkerSurface).frame(width: 3, height: 3)
                        Text("\(coinCount) COINS")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(Color(red: 0.75, green: 0.40, blue: 0.15))
                    } else {
                        Circle().fill(darkerSurface).frame(width: 3, height: 3)
                        Text(String(format: "%.2f MILES", route.totalDistanceMiles))
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(Color(red: 0.18, green: 0.72, blue: 0.70).opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)

        reviewRouteButton
    }

    private func nameRow(route: RecordedRoute) -> some View {
        let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
        return HStack(spacing: 8) {
            Text(route.name)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(darkText)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                renameText = route.name
                renamingRoute = route
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(darkText.opacity(0.35))
                    .padding(8)
                    .background(Color(red: 0.68, green: 0.70, blue: 0.82))
                    .clipShape(Circle())
            }
        }
    }

    private var reviewRouteButton: some View {
        HStack {
            Text("REVIEW ROUTE")
            Image(systemName: "chevron.right")
        }
        .font(.system(size: 14, weight: .black))
        .kerning(1.2)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.72, blue: 0.70),
                         Color(red: 0.10, green: 0.52, blue: 0.58)],
                startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .shadow(color: Color(red: 0.18, green: 0.72, blue: 0.70).opacity(0.25), radius: 10, x: 0, y: 5)
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
                .foregroundColor(.white.opacity(0.50))
            Text("Go to the Record tab to capture your first run!")
                .font(.body)
                .foregroundColor(.white.opacity(0.30))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

}
