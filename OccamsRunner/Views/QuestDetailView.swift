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

        // Defer camera fit until after SwiftUI has sized the view
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
        for p in points {
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }

        let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)

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

        func mapView(_ mapView: MKMapView,
                     viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let coin = annotation as? CoinAnnotation else { return nil }
            let size: CGFloat = 7
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "coin")
            let circle = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            circle.backgroundColor = coin.collected
                ? UIColor.green.withAlphaComponent(0.8)
                : UIColor(red: 1, green: 0.84, blue: 0, alpha: 1)
            circle.layer.cornerRadius = size / 2
            circle.layer.borderColor  = coin.collected
                ? UIColor.green.cgColor
                : UIColor.orange.cgColor
            circle.layer.borderWidth  = 1
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
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {

                    // ── 3D Map Preview ───────────────────────────────────
                    if let route = associatedRoute {
                        QuestMapPreview(route: route, markers: coinMarkers)
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
                    }

                    // ── Progress ─────────────────────────────────────────
                    progressSection

                    // ── Stats ────────────────────────────────────────────
                    statsSection

                    // ── Actions ──────────────────────────────────────────
                    actionButtons

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle(currentQuest.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .fullScreenCover(isPresented: $showingARView) {
            ARRunnerView(quest: currentQuest)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Progress")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text("\(currentQuest.collectedItems) / \(currentQuest.totalItems)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
            }

            ProgressView(value: Double(currentQuest.collectedItems),
                         total: Double(max(currentQuest.totalItems, 1)))
                .scaleEffect(y: 2)
                .tint(.orange)

            HStack {
                Text("\(currentQuest.collectedPoints) / \(currentQuest.totalPoints) pts")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if currentQuest.isComplete {
                    Label("Complete!", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statCard(title: "Total", value: "\(currentQuest.totalItems)",
                     icon: "circle.circle.fill")
            statCard(title: "Collected", value: "\(currentQuest.collectedItems)",
                     icon: "checkmark.circle.fill")
            statCard(title: "Remaining",
                     value: "\(currentQuest.totalItems - currentQuest.collectedItems)",
                     icon: "xmark.circle")
        }
        .padding(.horizontal, 16)
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.orange)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if pausedSession != nil {
                Button(action: resumeRun) {
                    neonButton(label: "Resume AR Run", icon: "play.fill", color: .green)
                }
                Button(action: { showingARView = true }) {
                    neonButton(label: "Start New AR Run", icon: "arkit", color: .orange)
                }
            } else {
                Button(action: { showingARView = true }) {
                    neonButton(label: "Start AR Run", icon: "arkit", color: .orange)
                }
            }

            if let route = associatedRoute {
                NavigationLink(destination: Route3DView(route: route)) {
                    neonButton(label: "View Route in 3D", icon: "cube.fill",
                               color: Color(red: 0.3, green: 0.5, blue: 1))
                }
            }

            if currentQuest.collectedItems > 0 {
                Button(action: resetProgress) {
                    neonButton(label: "Reset Progress", icon: "arrow.counterclockwise",
                               color: .red)
                }
            }
        }
        .padding(.horizontal, 16)
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

    private func resumeRun() {
        dataStore.clearPausedSession(for: quest.id)
        showingARView = true
    }

    private func resetProgress() {
        dataStore.clearPausedSession(for: quest.id)
        dataStore.resetQuestProgress(questId: quest.id)
    }
}
