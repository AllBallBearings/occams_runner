import SwiftUI
import MapKit

// MARK: - Neon polyline helpers (two layers: wide glow + narrow core)

final class GlowPolyline: MKPolyline {}
final class CorePolyline: MKPolyline {}

// MARK: - 3D Map Preview

struct Route3DMapPreview: UIViewRepresentable {
    let route: RecordedRoute

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isScrollEnabled   = true
        mapView.isZoomEnabled     = true
        mapView.isRotateEnabled   = false
        mapView.isPitchEnabled    = false
        mapView.showsBuildings    = true
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.delegate = context.coordinator

        let coords = route.geoTrack.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coords.isEmpty else { return mapView }

        mapView.addOverlay(GlowPolyline(coordinates: coords, count: coords.count),
                           level: .aboveRoads)
        mapView.addOverlay(CorePolyline(coordinates: coords, count: coords.count),
                           level: .aboveRoads)

        // Defer camera fit until after SwiftUI has sized the view
        DispatchQueue.main.async {
            fitRoute(on: mapView, coords: coords)
        }
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func fitRoute(on mapView: MKMapView, coords: [CLLocationCoordinate2D]) {
        // Build the MKMapRect that tightly wraps all route coordinates
        let points = coords.map(MKMapPoint.init)
        var rect = MKMapRect.null
        for p in points {
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }

        // Let MapKit pick the exact altitude needed to fill the frame with 40 pt padding
        let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)

        // Re-apply 3D pitch at the altitude MapKit just chose
        let fittedAltitude = mapView.camera.altitude
        let center         = mapView.camera.centerCoordinate
        mapView.setCamera(
            MKMapCamera(lookingAtCenter: center,
                        fromDistance: fittedAltitude,
                        pitch: 55,
                        heading: 0),
            animated: false
        )
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView,
                     rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? GlowPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.cyan.withAlphaComponent(0.28)
                r.lineWidth   = 16
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }
            if let line = overlay as? CorePolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.cyan
                r.lineWidth   = 3.5
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Route Detail View

struct RouteDetailView: View {
    @EnvironmentObject var dataStore: DataStore
    let route: RecordedRoute

    @State private var showingQuestCreator = false
    @State private var coinIntervalFeet: Double = 10

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Date recorded
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.white.opacity(0.45))
                        Text(route.dateRecorded, style: .date)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.45))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // ── 3D map preview ──────────────────────────────────
                    Route3DMapPreview(route: route)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(
                                    LinearGradient(
                                        colors: [.orange, Color(red: 1, green: 0.3, blue: 0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .shadow(color: .orange.opacity(0.45), radius: 14)
                        .padding(.horizontal, 16)

                    // ── Stats grid ──────────────────────────────────────
                    statsGrid
                        .padding(.horizontal, 16)

                    Divider()
                        .background(Color.white.opacity(0.12))
                        .padding(.horizontal, 16)

                    // ── Action buttons ──────────────────────────────────
                    actionButtons
                        .padding(.horizontal, 16)

                    // ── Existing quests ─────────────────────────────────
                    existingQuestsSection

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .sheet(isPresented: $showingQuestCreator) {
            NavigationView {
                QuestEditorView(route: route, isPresented: $showingQuestCreator)
            }
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        let items: [(String, String, String)] = [
            ("Distance",
             String(format: "%.2f mi", route.totalDistanceMiles),
             "figure.run"),
            ("Duration",
             formatDuration(route.durationSeconds),
             "clock"),
            (route.netElevationChangeMeters >= 0 ? "Elev. Gain" : "Elev. Loss",
             String(format: "%.0f ft", abs(route.netElevationChangeMeters) * 3.281),
             route.netElevationChangeMeters >= 0 ? "arrow.up.right" : "arrow.down.right"),
            ("GPS Points",
             "\(route.geoTrack.count)",
             "mappin.circle"),
        ]

        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                statCard(title: item.0, value: item.1, icon: item.2)
            }
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.45))
                Text(value)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            NavigationLink(destination: Route3DView(route: route)) {
                neonButton(label: "View in 3D", icon: "cube.fill",
                           color: Color(red: 0.3, green: 0.5, blue: 1))
            }

            Button(action: { showingQuestCreator = true }) {
                neonButton(label: "Create Quest", icon: "star.circle.fill",
                           color: .orange)
            }
        }
    }

    private func neonButton(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body).fontWeight(.semibold)
            Text(label)
                .font(.headline)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(color.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color, lineWidth: 1.5)
        )
        .shadow(color: color.opacity(0.4), radius: 8)
    }

    // MARK: - Existing Quests

    private var existingQuestsSection: some View {
        let quests = dataStore.quests(for: route.id)
        return Group {
            if !quests.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quests")
                        .font(.title3).fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)

                    ForEach(quests) { quest in
                        NavigationLink(destination: QuestDetailView(quest: quest)) {
                            questRow(quest)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func questRow(_ quest: Quest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.circle.fill")
                .foregroundColor(.orange)
                .font(.title2)

            VStack(alignment: .leading, spacing: 3) {
                Text(quest.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(quest.totalItems) coins · \(quest.totalPoints) pts")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            if quest.collectedItems > 0 {
                Text("\(quest.collectedItems)/\(quest.totalItems)")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(.orange)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(14)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
