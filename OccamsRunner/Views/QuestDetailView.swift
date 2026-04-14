import SwiftUI
import MapKit

// MARK: - Quest Map

private final class CoinAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let collected: Bool
    init(coordinate: CLLocationCoordinate2D, collected: Bool) {
        self.coordinate = coordinate
        self.collected = collected
    }
}

private struct QuestMapPreview: UIViewRepresentable {
    let route: RecordedRoute
    let markers: [(coordinate: CLLocationCoordinate2D, collected: Bool)]

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

        for m in markers {
            mapView.addAnnotation(CoinAnnotation(coordinate: m.coordinate, collected: m.collected))
        }

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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let coin = annotation as? CoinAnnotation else { return nil }
            let size: CGFloat = 7
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "coin")
            let circle = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            circle.backgroundColor = coin.collected
                ? UIColor.systemGreen.withAlphaComponent(0.8)
                : UIColor(red: 1, green: 0.84, blue: 0, alpha: 1)
            circle.layer.cornerRadius = size / 2
            circle.layer.borderColor = coin.collected
                ? UIColor.systemGreen.cgColor
                : UIColor.orange.cgColor
            circle.layer.borderWidth = 1
            view.addSubview(circle)
            view.frame = circle.frame
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Quest Detail View

struct QuestDetailView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var locationService: LocationService
    let quest: Quest

    @State private var showingARView = false

    // Design constants
    private let surface    = Color(red: 0.76, green: 0.78, blue: 0.88)
    private let deepSurf   = Color(red: 0.68, green: 0.70, blue: 0.82)
    private let darkText   = Color(red: 0.12, green: 0.13, blue: 0.20)
    private let teal       = Color(red: 0.18, green: 0.72, blue: 0.70)
    private let indigo     = Color(red: 0.45, green: 0.35, blue: 0.80)
    private let shadowDark = Color(red: 0.01, green: 0.01, blue: 0.04)
    private let shadowLift = Color(red: 0.14, green: 0.16, blue: 0.28)

    private var pausedSession: RunSession? {
        dataStore.activePausedSession(for: quest.id)
    }

    private var currentQuest: Quest {
        dataStore.quests.first(where: { $0.id == quest.id }) ?? quest
    }

    private var associatedRoute: RecordedRoute? {
        dataStore.route(for: quest.routeId)
    }

    private var coinMarkers: [(coordinate: CLLocationCoordinate2D, collected: Bool)] {
        guard let route = associatedRoute else { return [] }
        return currentQuest.items.compactMap { item in
            guard let sample = route.geoSample(atProgress: item.routeProgress) else { return nil }
            return (sample.coordinate, item.collected)
        }
    }

    var body: some View {
        ZStack {
            appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Map preview
                    if let route = associatedRoute {
                        QuestMapPreview(route: route, markers: coinMarkers)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(deepSurf, lineWidth: 1)
                            )
                            .shadow(color: shadowDark, radius: 16, x: 6, y: 6)
                            .shadow(color: shadowLift.opacity(0.40), radius: 12, x: -4, y: -4)
                            .padding(.horizontal, 16)
                    }

                    progressSection
                    statsSection
                    actionButtons

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle(currentQuest.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.04, green: 0.07, blue: 0.18), for: .navigationBar)
        .fullScreenCover(isPresented: $showingARView) {
            ARRunnerView(quest: currentQuest)
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

    // MARK: - Progress

    private var progressSection: some View {
        let progress = currentQuest.totalItems > 0
            ? Double(currentQuest.collectedItems) / Double(currentQuest.totalItems) : 0.0

        return VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROGRESS")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(darkText.opacity(0.40))
                        .kerning(0.8)
                    Text("\(currentQuest.collectedItems) of \(currentQuest.totalItems) coins")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(darkText)
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(teal)
            }

            // Progress track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(deepSurf)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [teal, indigo],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress)
                        .shadow(color: teal.opacity(0.25), radius: 4)
                }
            }
            .frame(height: 8)

            if currentQuest.isComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(teal)
                    Text("Quest Complete!")
                        .font(.subheadline).fontWeight(.bold)
                        .foregroundColor(teal)
                }
            } else {
                Text("\(currentQuest.collectedPoints) / \(currentQuest.totalPoints) pts")
                    .font(.caption)
                    .foregroundColor(darkText.opacity(0.45))
            }
        }
        .padding(18)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: shadowDark, radius: 12, x: 6, y: 6)
        .shadow(color: shadowLift.opacity(0.40), radius: 10, x: -4, y: -4)
        .padding(.horizontal, 16)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statCard(title: "Total", value: "\(currentQuest.totalItems)", icon: "circle.circle.fill", color: indigo)
            statCard(title: "Collected", value: "\(currentQuest.collectedItems)", icon: "checkmark.circle.fill", color: teal)
            statCard(title: "Remaining", value: "\(currentQuest.totalItems - currentQuest.collectedItems)",
                     icon: "xmark.circle", color: Color(red: 0.75, green: 0.40, blue: 0.15))
        }
        .padding(.horizontal, 16)
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(deepSurf).frame(width: 44, height: 44)
                    .shadow(color: shadowDark, radius: 4, x: 2, y: 2)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
            }
            Text(value)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(darkText)
            Text(title)
                .font(.caption)
                .foregroundColor(darkText.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: shadowDark, radius: 10, x: 5, y: 5)
        .shadow(color: shadowLift.opacity(0.40), radius: 8, x: -3, y: -3)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if pausedSession != nil {
                Button(action: resumeRun) {
                    accentButton(label: "Resume AR Run", icon: "play.fill",
                                 colors: [teal, Color(red: 0.10, green: 0.52, blue: 0.58)])
                }
                Button(action: { showingARView = true }) {
                    accentButton(label: "Start New AR Run", icon: "arkit",
                                 colors: [Color(red: 0.95, green: 0.55, blue: 0.25),
                                          Color(red: 0.85, green: 0.40, blue: 0.10)])
                }
            } else {
                Button(action: { showingARView = true }) {
                    accentButton(label: "Start AR Run", icon: "arkit",
                                 colors: [teal, Color(red: 0.10, green: 0.52, blue: 0.58)])
                }
            }

            if let route = associatedRoute {
                NavigationLink(destination: Route3DView(route: route)) {
                    neuButton(label: "View Route in 3D", icon: "cube.fill", iconColor: indigo)
                }
            }

            if currentQuest.collectedItems > 0 {
                Button(action: resetProgress) {
                    neuButton(label: "Reset Progress", icon: "arrow.counterclockwise",
                              iconColor: Color(red: 0.75, green: 0.25, blue: 0.25))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func accentButton(label: String, icon: String, colors: [Color]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.body).fontWeight(.semibold)
            Text(label).font(.headline)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: colors[0].opacity(0.30), radius: 10, x: 0, y: 5)
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

    private func resumeRun() {
        dataStore.clearPausedSession(for: quest.id)
        showingARView = true
    }

    private func resetProgress() {
        dataStore.clearPausedSession(for: quest.id)
        dataStore.resetQuestProgress(questId: quest.id)
    }
}
