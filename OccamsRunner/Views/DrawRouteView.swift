import SwiftUI
import MapKit

// MARK: - Draw Route Model

/// The path being drawn, kept as strokes so undo removes exactly what one gesture added:
/// a tap adds one point (or, with snapping, the walking path to it); a drag adds a
/// freehand line.
@MainActor
final class DrawRouteModel: ObservableObject {
    enum Tool { case tap, freehand }

    @Published private(set) var strokes: [[CLLocationCoordinate2D]] = []
    @Published var tool: Tool = .tap
    @Published var snapToPaths = false
    @Published private(set) var isSnapping = false
    @Published var snapFailureMessage: String?
    /// Bumped on every path change so the map only redraws when needed.
    @Published private(set) var version = 0

    var path: [CLLocationCoordinate2D] { strokes.flatMap { $0 } }
    var pointCount: Int { strokes.reduce(0) { $0 + $1.count } }
    var distanceMeters: Double { DrawnRouteBuilder.pathLengthMeters(path) }
    var canSave: Bool { DrawnRouteBuilder.removingDuplicates(path).count >= 2 }

    func addTapPoint(_ coordinate: CLLocationCoordinate2D) {
        guard !isSnapping else { return }
        guard snapToPaths, let last = path.last else {
            append([coordinate])
            return
        }
        isSnapping = true
        Task {
            let snapped = await WalkingPathSnapper.path(from: last, to: coordinate)
            isSnapping = false
            if let snapped, !snapped.isEmpty {
                append(snapped)
            } else {
                snapFailureMessage = "No walking path found — added a straight line."
                append([coordinate])
            }
        }
    }

    func beginFreehand(_ coordinate: CLLocationCoordinate2D) {
        append([coordinate])
    }

    func extendFreehand(_ coordinate: CLLocationCoordinate2D) {
        guard !strokes.isEmpty else { return append([coordinate]) }
        strokes[strokes.count - 1].append(coordinate)
        version += 1
    }

    func undo() {
        guard !strokes.isEmpty, !isSnapping else { return }
        strokes.removeLast()
        version += 1
    }

    func clear() {
        guard !isSnapping else { return }
        strokes.removeAll()
        version += 1
    }

    private func append(_ stroke: [CLLocationCoordinate2D]) {
        strokes.append(stroke)
        version += 1
    }
}

// MARK: - Snapping

/// Follows roads and footpaths between two points using MapKit walking directions.
enum WalkingPathSnapper {
    /// Walking path from `start` to `end`, without its first point (already on the route).
    static func path(from start: CLLocationCoordinate2D,
                     to end: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else {
            return nil
        }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return Array(coordinates.dropFirst())
    }
}

// MARK: - Draw Route View

struct DrawRouteView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = DrawRouteModel()
    @State private var showingSaveSheet = false
    @State private var routeName = ""
    @State private var saveErrorMessage: String?

    private let darkText = Color(red: 0.12, green: 0.13, blue: 0.20)
    private let lavender = Color(red: 0.76, green: 0.78, blue: 0.88)
    private let lavenderInset = Color(red: 0.68, green: 0.70, blue: 0.82)

    var body: some View {
        ZStack(alignment: .top) {
            DrawRouteMapView(model: model, initialCenter: locationService.currentLocation?.coordinate)
                .ignoresSafeArea()

            statsCard
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(spacing: 14) {
                Spacer()
                if let message = model.snapFailureMessage {
                    Text(message)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                        .task(id: message) {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            model.snapFailureMessage = nil
                        }
                }
                controlsCard
                    .padding(.horizontal, 16)
                saveButton
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
        .navigationTitle("Draw Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { locationService.startUpdating() }
        .sheet(isPresented: $showingSaveSheet) { saveSheet }
    }

    // MARK: Stats

    private var statsCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                statColumn(title: "DISTANCE",
                           value: String(format: "%.2f", model.distanceMeters / 1609.344),
                           unit: "mi")
                Spacer()
                statColumn(title: "POINTS", value: "\(model.pointCount)", unit: nil)
            }
            .padding(.horizontal, 24)

            Text(hint.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(darkText.opacity(0.45))
                .kerning(1.0)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(lavender)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 16, x: 6, y: 6)
    }

    private var hint: String {
        if model.isSnapping { return "Finding walking path…" }
        switch model.tool {
        case .tap:      return model.snapToPaths ? "Tap to add points along paths" : "Tap the map to add points"
        case .freehand: return "Drag one finger to draw · pinch to zoom"
        }
    }

    private func statColumn(title: String, value: String, unit: String?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(darkText.opacity(0.45))
                .kerning(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(darkText)
                if let unit {
                    Text(unit)
                        .font(.caption2).fontWeight(.bold)
                        .foregroundColor(darkText.opacity(0.35))
                }
            }
        }
    }

    // MARK: Controls

    private var controlsCard: some View {
        VStack(spacing: 12) {
            Picker("Tool", selection: $model.tool) {
                Label("Tap", systemImage: "hand.tap.fill").tag(DrawRouteModel.Tool.tap)
                Label("Draw", systemImage: "scribble").tag(DrawRouteModel.Tool.freehand)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("drawRouteToolPicker")

            HStack(spacing: 10) {
                controlButton("Undo", icon: "arrow.uturn.backward", id: "drawRouteUndo",
                              disabled: model.strokes.isEmpty || model.isSnapping) { model.undo() }
                controlButton("Clear", icon: "trash", id: "drawRouteClear",
                              disabled: model.strokes.isEmpty || model.isSnapping) { model.clear() }
                Toggle(isOn: $model.snapToPaths) {
                    Label("Snap", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(darkText)
                }
                .toggleStyle(.button)
                .tint(Color(red: 0.18, green: 0.72, blue: 0.70))
                .disabled(model.tool == .freehand)
                .accessibilityIdentifier("drawRouteSnapToggle")
            }
        }
        .padding(14)
        .background(lavender)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color(red: 0.01, green: 0.01, blue: 0.04), radius: 10, x: 5, y: 5)
    }

    private func controlButton(_ title: String, icon: String, id: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(darkText.opacity(disabled ? 0.35 : 1))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(lavenderInset)
                .clipShape(Capsule())
        }
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private var saveButton: some View {
        Button {
            routeName = "Drawn \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            saveErrorMessage = nil
            showingSaveSheet = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("SAVE ROUTE")
                    .font(.system(size: 18, weight: .bold))
                    .kerning(1.5)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(LinearGradient(
                colors: [Color(red: 0.1, green: 0.8, blue: 0.4), Color(red: 0.0, green: 0.6, blue: 0.3)],
                startPoint: .top, endPoint: .bottom))
            .clipShape(Capsule())
            .shadow(color: Color.green.opacity(0.25), radius: 15, x: 0, y: 8)
            .opacity(model.canSave && !model.isSnapping ? 1 : 0.45)
        }
        .disabled(!model.canSave || model.isSnapping)
        .accessibilityIdentifier("drawRouteSave")
    }

    // MARK: Save Sheet

    private var saveSheet: some View {
        NavigationView {
            Form {
                Section("Route Details") {
                    TextField("Route Name", text: $routeName)
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(String(format: "%.2f miles", model.distanceMeters / 1609.344))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Drawn Points")
                        Spacer()
                        Text("\(model.pointCount)").foregroundColor(.secondary)
                    }
                }
                Section {
                    Text("Drawn routes are placed in AR from GPS and compass, so coins can sit a few metres off until you start running and the route settles under you.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let saveErrorMessage {
                        Text(saveErrorMessage).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveRoute)
                }
            }
        }
    }

    private func saveRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            saveErrorMessage = "Route name is empty."
            return
        }
        guard let route = DrawnRouteBuilder.makeRoute(
            name: name,
            coordinates: model.path,
            startAltitude: locationService.currentLocation?.altitude ?? 0
        ) else {
            saveErrorMessage = "Draw at least two separate points."
            return
        }
        dataStore.saveRoute(route)
        showingSaveSheet = false
        dismiss()
    }
}

// MARK: - Map

/// MKMapView with tap-to-add and one-finger freehand drawing. Freehand mode turns off
/// map scrolling so the drag draws instead of panning; pinch still zooms.
private struct DrawRouteMapView: UIViewRepresentable {
    @ObservedObject var model: DrawRouteModel
    let initialCenter: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        if let initialCenter {
            map.setRegion(MKCoordinateRegion(center: initialCenter, latitudinalMeters: 500,
                                             longitudinalMeters: 500), animated: false)
            context.coordinator.didCenter = true
        }

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        context.coordinator.panRecognizer = pan
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.model = model
        map.isScrollEnabled = model.tool == .tap
        context.coordinator.render(on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var model: DrawRouteModel
        weak var panRecognizer: UIPanGestureRecognizer?
        var didCenter = false
        private var renderedVersion = -1
        private var lastFreehandPoint: CGPoint?
        /// Screen distance between freehand samples; finer than this is just noise.
        private let freehandSpacingPoints: CGFloat = 8

        init(model: DrawRouteModel) { self.model = model }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard model.tool == .tap, let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            model.addTapPoint(map.convert(point, toCoordinateFrom: map))
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard model.tool == .freehand, let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            switch gesture.state {
            case .began:
                lastFreehandPoint = point
                model.beginFreehand(map.convert(point, toCoordinateFrom: map))
            case .changed:
                guard let last = lastFreehandPoint,
                      hypot(point.x - last.x, point.y - last.y) >= freehandSpacingPoints else { return }
                lastFreehandPoint = point
                model.extendFreehand(map.convert(point, toCoordinateFrom: map))
            default:
                if gesture.state == .ended, let last = lastFreehandPoint, last != point {
                    model.extendFreehand(map.convert(point, toCoordinateFrom: map))
                }
                lastFreehandPoint = nil
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panRecognizer { return model.tool == .freehand }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let the map's own pinch/double-tap keep working alongside ours.
            gestureRecognizer !== panRecognizer
        }

        func render(on map: MKMapView) {
            guard model.version != renderedVersion else { return }
            renderedVersion = model.version
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

            let path = model.path
            if path.count > 1 {
                map.addOverlay(MKPolyline(coordinates: path, count: path.count))
            }
            if let first = path.first {
                map.addAnnotation(EndpointAnnotation(coordinate: first, isStart: true))
            }
            if path.count > 1, let last = path.last {
                map.addAnnotation(EndpointAnnotation(coordinate: last, isStart: false))
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didCenter, let location = userLocation.location else { return }
            didCenter = true
            mapView.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 500,
                                                 longitudinalMeters: 500), animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.orange
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let endpoint = annotation as? EndpointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: endpoint, reuseIdentifier: nil)
            view.markerTintColor = endpoint.isStart ? .systemGreen : .systemRed
            view.glyphImage = UIImage(systemName: endpoint.isStart ? "flag.fill" : "flag.checkered")
            view.displayPriority = .required
            return view
        }
    }
}

private final class EndpointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let isStart: Bool

    init(coordinate: CLLocationCoordinate2D, isStart: Bool) {
        self.coordinate = coordinate
        self.isStart = isStart
    }
}
