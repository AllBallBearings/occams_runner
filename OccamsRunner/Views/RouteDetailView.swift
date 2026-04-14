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

        DispatchQueue.main.async {
            fitRoute(on: mapView, coords: coords)
        }
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func fitRoute(on mapView: MKMapView, coords: [CLLocationCoordinate2D]) {
        let points = coords.map(MKMapPoint.init)
        var rect = MKMapRect.null
        for p in points { rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
        let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        let fittedAltitude = mapView.camera.altitude
        let center = mapView.camera.centerCoordinate
        mapView.setCamera(
            MKMapCamera(lookingAtCenter: center, fromDistance: fittedAltitude, pitch: 55, heading: 0),
            animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? GlowPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(red: 0.18, green: 0.72, blue: 0.70, alpha: 0.28)
                r.lineWidth = 16; r.lineCap = .round; r.lineJoin = .round
                return r
            }
            if let line = overlay as? CorePolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(red: 0.18, green: 0.72, blue: 0.70, alpha: 1)
                r.lineWidth = 3.5; r.lineCap = .round; r.lineJoin = .round
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

    // Design constants
    private let surface    = Color(red: 0.76, green: 0.78, blue: 0.88)
    private let deepSurf   = Color(red: 0.68, green: 0.70, blue: 0.82)
    private let darkText   = Color(red: 0.12, green: 0.13, blue: 0.20)
    private let teal       = Color(red: 0.18, green: 0.72, blue: 0.70)
    private let indigo     = Color(red: 0.45, green: 0.35, blue: 0.80)
    private let shadowDark = Color(red: 0.01, green: 0.01, blue: 0.04)
    private let shadowLift = Color(red: 0.14, green: 0.16, blue: 0.28)

    var body: some View {
        ZStack {
            appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Date header
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .foregroundColor(teal.opacity(0.80))
                            .font(.system(size: 14))
                        Text(route.dateRecorded, style: .date)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.65))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // 3D map preview
                    Route3DMapPreview(route: route)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(deepSurf, lineWidth: 1)
                        )
                        .shadow(color: shadowDark, radius: 16, x: 6, y: 6)
                        .shadow(color: shadowLift.opacity(0.40), radius: 12, x: -4, y: -4)
                        .padding(.horizontal, 16)

                    statsGrid
                        .padding(.horizontal, 16)

                    actionButtons
                        .padding(.horizontal, 16)

                    existingQuestsSection

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.04, green: 0.07, blue: 0.18), for: .navigationBar)
        .sheet(isPresented: $showingQuestCreator) {
            NavigationView {
                QuestEditorView(route: route, isPresented: $showingQuestCreator)
            }
        }
    }

    // MARK: - Background

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.07, blue: 0.18),
                Color(red: 0.86, green: 0.88, blue: 0.94)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        let items: [(String, String, String, Color)] = [
            ("Distance",
             String(format: "%.2f mi", route.totalDistanceMiles),
             "figure.run", teal),
            ("Duration",
             formatDuration(route.durationSeconds),
             "clock", indigo),
            (route.netElevationChangeMeters >= 0 ? "Elev. Gain" : "Elev. Loss",
             String(format: "%.0f ft", abs(route.netElevationChangeMeters) * 3.281),
             route.netElevationChangeMeters >= 0 ? "arrow.up.right" : "arrow.down.right",
             Color(red: 0.35, green: 0.75, blue: 0.50)),
            ("GPS Points",
             "\(route.geoTrack.count)",
             "mappin.circle",
             Color(red: 0.95, green: 0.55, blue: 0.25)),
        ]

        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                statCard(title: item.0, value: item.1, icon: item.2, color: item.3)
            }
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(deepSurf).frame(width: 38, height: 38)
                    .shadow(color: shadowDark, radius: 4, x: 2, y: 2)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(darkText.opacity(0.45))
                Text(value)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(darkText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: shadowDark, radius: 10, x: 5, y: 5)
        .shadow(color: shadowLift.opacity(0.40), radius: 8, x: -3, y: -3)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            NavigationLink(destination: Route3DView(route: route)) {
                neuButton(label: "View in 3D", icon: "cube.fill", iconColor: indigo)
            }

            Button(action: { showingQuestCreator = true }) {
                neuButton(label: "Create Quest", icon: "star.circle.fill", iconColor: teal)
            }
        }
    }

    private func neuButton(label: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(deepSurf).frame(width: 38, height: 38)
                    .shadow(color: shadowDark, radius: 4, x: 2, y: 2)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            Text(label)
                .font(.headline)
                .foregroundColor(darkText)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(darkText.opacity(0.30))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: shadowDark, radius: 10, x: 5, y: 5)
        .shadow(color: shadowLift.opacity(0.40), radius: 8, x: -3, y: -3)
    }

    // MARK: - Existing Quests

    private var existingQuestsSection: some View {
        let quests = dataStore.quests(for: route.id)
        return Group {
            if !quests.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
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
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(deepSurf).frame(width: 44, height: 44)
                    .shadow(color: shadowDark, radius: 4, x: 2, y: 2)
                Image(systemName: "star.circle.fill")
                    .foregroundColor(teal)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(quest.name)
                    .font(.headline)
                    .foregroundColor(darkText)
                Text("\(quest.totalItems) coins · \(quest.totalPoints) pts")
                    .font(.caption)
                    .foregroundColor(darkText.opacity(0.45))
            }

            Spacer()

            if quest.collectedItems > 0 {
                Text("\(quest.collectedItems)/\(quest.totalItems)")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(teal)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(deepSurf)
                    .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(darkText.opacity(0.30))
        }
        .padding(14)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: shadowDark, radius: 10, x: 5, y: 5)
        .shadow(color: shadowLift.opacity(0.40), radius: 8, x: -3, y: -3)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
