import MapKit
import SwiftUI

enum MapLook: String, CaseIterable {
    case satellite
    case night

    var label: String { self == .satellite ? "Satellite" : "Night" }
}

/// Where the map should move next: a center, and optionally a zoom (latitude span in degrees).
struct MapFocus: Equatable {
    var center: CLLocationCoordinate2D
    var spanDegrees: Double?

    init(_ center: CLLocationCoordinate2D, spanDegrees: Double? = nil) {
        self.center = center
        self.spanDegrees = spanDegrees
    }

    static func == (a: MapFocus, b: MapFocus) -> Bool {
        a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude && a.spanDegrees == b.spanDegrees
    }
}

/// The 3D globe. MapKit draws a real globe when zoomed out with the satellite/hybrid configurations.
struct GlobeView: UIViewRepresentable {
    let planes: [String: Plane]
    /// The connected airport (ICAO): highlighted, with its 60 nm range ring.
    let tunedAirport: String?
    let talking: [String: TalkStore.Talk]
    /// Starred airports (ICAO): an amber star on their labels.
    var favorites: [String] = []
    /// Where the selected plane has been.
    var trail: [CLLocationCoordinate2D] = []
    let look: MapLook
    @Binding var selectedPlaneID: String?
    @Binding var selectedAirport: Airport?
    @Binding var focus: MapFocus?
    var onCenterChange: (CLLocationCoordinate2D) -> Void
    /// Keep the map centered on the selected plane.
    var followSelected = false
    /// You dragged or pinched the map (ends follow mode).
    var onUserMove: () -> Void = {}
    /// Show the blue dot (only once you've allowed location).
    var showUser = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(PlaneAnnotationView.self, forAnnotationViewWithReuseIdentifier: PlaneAnnotationView.reuseID)
        map.register(AirportAnnotationView.self, forAnnotationViewWithReuseIdentifier: AirportAnnotationView.reuseID)
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        apply(look, to: map)
        // Start over the US with every connectable airport in view; pinch out for the globe.
        let start = CLLocationCoordinate2D(latitude: 38.5, longitude: -97)
        map.setRegion(MKCoordinateRegion(center: start, span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 45)), animated: false)
        context.coordinator.map = map
        // Our own recognizers (alongside MapKit's) tell a finger on the map from code moving it.
        for gesture in [UIPanGestureRecognizer(), UIPinchGestureRecognizer(), UIRotationGestureRecognizer()] as [UIGestureRecognizer] {
            gesture.addTarget(context.coordinator, action: #selector(Coordinator.userGesture(_:)))
            gesture.delegate = context.coordinator
            gesture.cancelsTouchesInView = false
            map.addGestureRecognizer(gesture)
        }
        context.coordinator.installArrow(on: map)
        context.coordinator.startTicker()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if map.showsUserLocation != showUser { map.showsUserLocation = showUser }
        if coordinator.look != look {
            coordinator.look = look
            apply(look, to: map)
        }
        if let focus {
            if let span = focus.spanDegrees {
                // A degree of longitude shrinks with latitude: widen it so the view is `span` tall AND wide.
                let lonSpan = min(span / max(cos(focus.center.latitude * .pi / 180), 0.2), 360)
                let region = MKCoordinateRegion(center: focus.center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: lonSpan))
                map.setRegion(map.regionThatFits(region), animated: true)
            } else {
                map.setCenter(focus.center, animated: true)
            }
            DispatchQueue.main.async { self.focus = nil }
        }
        coordinator.sync()
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopTicker()
    }

    private func apply(_ look: MapLook, to map: MKMapView) {
        switch look {
        case .satellite:
            map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            map.overrideUserInterfaceStyle = .dark
        case .night:
            let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
            map.overrideUserInterfaceStyle = .dark
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        @objc func userGesture(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began, parent.followSelected { parent.onUserMove() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        var parent: GlobeView
        weak var map: MKMapView?
        var look: MapLook?
        private var planeAnnotations: [String: PlaneAnnotation] = [:]
        private var airportAnnotations: [String: AirportAnnotation] = [:]
        private var ticker: Timer?
        private var appObservers: [NSObjectProtocol] = []
        private var lastAirportRegion: MKCoordinateRegion?
        private let arrow = UIImageView(image: UIImage(systemName: "location.north.fill",
                                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)))
        private var lastTuned: String?
        private var lastFavorites: [String] = []
        private var rangeRing: MKCircle?
        private var trailLine: MKPolyline?
        private var lastTrail: (id: String?, count: Int, last: CLLocationCoordinate2D?) = (nil, 0, nil)

        static let maxPlanes = 1500
        static let labelSpan = 1.2

        init(_ parent: GlobeView) {
            self.parent = parent
            self.look = parent.look
        }

        func startTicker() {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            guard appObservers.isEmpty else { return }
            // No gliding planes while the screen is off or the app is in the background: audio keeps going, the map doesn't.
            let center = NotificationCenter.default
            appObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseTicker() }
            })
            appObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.startTicker() }
            })
        }

        private func pauseTicker() {
            ticker?.invalidate()
            ticker = nil
        }

        func stopTicker() {
            ticker?.invalidate()
            ticker = nil
        }

        func installArrow(on map: MKMapView) {
            arrow.isHidden = true
            arrow.layer.shadowColor = UIColor.black.cgColor
            arrow.layer.shadowOpacity = 0.8
            arrow.layer.shadowRadius = 3
            arrow.layer.shadowOffset = .zero
            map.addSubview(arrow)
        }

        /// Points at the plane that's talking when it is off screen.
        private func updateArrow() {
            guard let map else { return }
            let latest = parent.talking.filter { $0.value.isFresh }.max { $0.value.time < $1.value.time }
            guard let latest, let plane = parent.planes[latest.key] else {
                arrow.isHidden = true
                return
            }
            let point = map.convert(plane.position(at: Date()), toPointTo: map)
            guard point.x.isFinite, point.y.isFinite else {
                arrow.isHidden = true
                return
            }
            let safe = map.bounds.inset(by: UIEdgeInsets(top: 120, left: 24, bottom: 200, right: 24))
            if safe.contains(point) || map.bounds.contains(point) {
                arrow.isHidden = true
                return
            }
            let center = CGPoint(x: safe.midX, y: safe.midY)
            let dx = point.x - center.x, dy = point.y - center.y
            let scale = min(abs(safe.width / 2 / max(abs(dx), 0.001)), abs(safe.height / 2 / max(abs(dy), 0.001)))
            arrow.center = CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
            arrow.transform = CGAffineTransform(rotationAngle: atan2(dy, dx) + .pi / 2)
            arrow.tintColor = latest.value.speaker == .pilot ? Theme.uiAmber : Theme.uiCyan
            arrow.isHidden = false
        }

        /// Glides every plane to where it should be one second from now.
        private func tick() {
            updateArrow()
            if let map {
                // Ring and bubble expire on their own, without waiting for new traffic.
                for annotation in planeAnnotations.values {
                    if let view = map.view(for: annotation) as? PlaneAnnotationView {
                        view.setTalk(parent.talking[annotation.id])
                    }
                }
            }
            let target = Date().addingTimeInterval(1)
            let followed = parent.followSelected ? parent.selectedPlaneID.flatMap { planeAnnotations[$0] } : nil
            UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .allowUserInteraction, .beginFromCurrentState]) {
                for annotation in self.planeAnnotations.values {
                    annotation.coordinate = annotation.plane.position(at: target)
                }
            }
            // Keep the followed plane in the middle (MapKit animates the move).
            if let followed { map?.setCenter(followed.plane.position(at: target), animated: true) }
        }

        // MARK: Sync

        func sync() {
            guard let map else { return }
            syncPlanes(map)
            let tunedChanged = parent.tunedAirport != lastTuned
            if tunedChanged {
                lastTuned = parent.tunedAirport
                syncRangeRing(map)
            }
            syncTrail(map)
            let favoritesChanged = parent.favorites != lastFavorites
            lastFavorites = parent.favorites
            syncAirports(map, force: tunedChanged || favoritesChanged)
        }

        /// The selected plane's path so far, redrawn when it grows.
        private func syncTrail(_ map: MKMapView) {
            let points = parent.selectedPlaneID == nil ? [] : parent.trail
            let last = points.last
            if lastTrail.id == parent.selectedPlaneID, lastTrail.count == points.count,
               lastTrail.last?.latitude == last?.latitude, lastTrail.last?.longitude == last?.longitude { return }
            lastTrail = (parent.selectedPlaneID, points.count, last)
            if let line = trailLine { map.removeOverlay(line) }
            trailLine = nil
            guard points.count >= 2 else { return }
            let line = MKPolyline(coordinates: points, count: points.count)
            trailLine = line
            map.addOverlay(line, level: .aboveRoads)
        }

        /// A faint ring showing the 60 nm the connected airport's planes come from.
        private func syncRangeRing(_ map: MKMapView) {
            if let ring = rangeRing { map.removeOverlay(ring) }
            rangeRing = nil
            guard let icao = parent.tunedAirport, let airport = AirportIndex.shared.airport(icao: icao) else { return }
            let ring = MKCircle(center: airport.coordinate, radius: Double(TrafficStore.rangeNM) * 1852)
            rangeRing = ring
            map.addOverlay(ring, level: .aboveRoads)
        }

        private func visibleRect(_ map: MKMapView) -> MKMapRect {
            // A little margin so planes don't pop in at the edges.
            let rect = map.visibleMapRect
            return rect.insetBy(dx: -rect.size.width * 0.15, dy: -rect.size.height * 0.15)
        }

        private func syncPlanes(_ map: MKMapView) {
            let rect = visibleRect(map)
            let now = Date()
            var visible = parent.planes.values.filter { rect.contains(MKMapPoint($0.position(at: now))) }
            if visible.count > Self.maxPlanes {
                // Too many: keep the selected one, then airborne planes nearest the center.
                let center = map.centerCoordinate
                visible.sort {
                    if $0.id == parent.selectedPlaneID { return true }
                    if $1.id == parent.selectedPlaneID { return false }
                    if $0.onGround != $1.onGround { return !$0.onGround }
                    return Geo.distanceNM($0.lat, $0.lon, center.latitude, center.longitude)
                        < Geo.distanceNM($1.lat, $1.lon, center.latitude, center.longitude)
                }
                visible = Array(visible.prefix(Self.maxPlanes))
            }
            let wanted = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            let gone = planeAnnotations.filter { wanted[$0.key] == nil }
            if !gone.isEmpty {
                map.removeAnnotations(Array(gone.values))
                for key in gone.keys { planeAnnotations[key] = nil }
            }

            var added: [PlaneAnnotation] = []
            let tuned = parent.tunedAirport.flatMap { AirportIndex.shared.airport(icao: $0) }
            for (id, plane) in wanted {
                if let annotation = planeAnnotations[id] {
                    annotation.plane = plane
                    if let view = map.view(for: annotation) as? PlaneAnnotationView {
                        configure(view, plane: plane, tuned: tuned, map: map)
                    }
                } else {
                    let annotation = PlaneAnnotation(plane, coordinate: plane.position(at: now))
                    planeAnnotations[id] = annotation
                    added.append(annotation)
                }
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        private func syncAirports(_ map: MKMapView, force: Bool) {
            let region = map.region
            if !force, let last = lastAirportRegion,
               abs(last.center.latitude - region.center.latitude) < region.span.latitudeDelta * 0.2,
               abs(last.center.longitude - region.center.longitude) < region.span.longitudeDelta * 0.2,
               abs(last.span.latitudeDelta - region.span.latitudeDelta) < region.span.latitudeDelta * 0.3 {
                return
            }
            lastAirportRegion = region
            let span = region.span
            // Other big airports, for orientation, only when zoomed in.
            let minLon = region.center.longitude - span.longitudeDelta / 2
            let maxLon = region.center.longitude + span.longitudeDelta / 2
            var airports = span.latitudeDelta > 8 ? [] : AirportIndex.shared.airports(
                minLat: region.center.latitude - span.latitudeDelta / 2,
                maxLat: region.center.latitude + span.latitudeDelta / 2,
                minLon: minLon < -180 ? minLon + 360 : minLon,
                maxLon: maxLon > 180 ? maxLon - 360 : maxLon,
                includeMedium: false, limit: 150)
            // Airports you can connect to are always on the map, at any zoom.
            airports += Catalog.connectable.compactMap { AirportIndex.shared.airport(icao: $0) }
            // So are your starred ones.
            airports += parent.favorites.compactMap { AirportIndex.shared.airport(icao: $0) }
            let wanted = Dictionary(airports.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
            let gone = airportAnnotations.filter { wanted[$0.key] == nil }
            if !gone.isEmpty {
                map.removeAnnotations(Array(gone.values))
                for key in gone.keys { airportAnnotations[key] = nil }
            }
            var added: [AirportAnnotation] = []
            for (icao, airport) in wanted {
                if let existing = airportAnnotations[icao] {
                    if let view = map.view(for: existing) as? AirportAnnotationView {
                        view.configure(airport: airport, tuned: icao == parent.tunedAirport, hasFeed: Catalog.connectable.contains(icao),
                                       favorite: parent.favorites.contains(icao))
                    }
                } else {
                    let annotation = AirportAnnotation(airport)
                    airportAnnotations[icao] = annotation
                    added.append(annotation)
                }
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        private func style(for plane: Plane, tuned: Airport?) -> PlaneAnnotationView.Style {
            if plane.id == parent.selectedPlaneID { return .selected }
            if plane.emergency != nil { return .emergency }
            if plane.onGround { return .ground }
            if let tuned, EventDetector.isApproaching(plane, to: tuned) { return .approach }
            return .airborne
        }

        private func configure(_ view: PlaneAnnotationView, plane: Plane, tuned: Airport?, map: MKMapView) {
            view.configure(plane: plane, style: style(for: plane, tuned: tuned),
                           showLabel: map.region.span.latitudeDelta < Self.labelSpan || plane.id == parent.selectedPlaneID,
                           mapHeading: map.camera.heading)
            view.setTalk(parent.talking[plane.id])
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let plane = annotation as? PlaneAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PlaneAnnotationView.reuseID, for: plane) as! PlaneAnnotationView
                let tuned = parent.tunedAirport.flatMap { AirportIndex.shared.airport(icao: $0) }
                configure(view, plane: plane.plane, tuned: tuned, map: mapView)
                return view
            }
            if let airport = annotation as? AirportAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: AirportAnnotationView.reuseID, for: airport) as! AirportAnnotationView
                view.configure(airport: airport.airport, tuned: airport.airport.icao == parent.tunedAirport,
                               hasFeed: Catalog.connectable.contains(airport.airport.icao),
                               favorite: parent.favorites.contains(airport.airport.icao))
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = Theme.uiAmber.withAlphaComponent(0.8)
                renderer.lineWidth = 2.5
                renderer.lineDashPattern = [2, 4]
                renderer.lineCap = .round
                return renderer
            }
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = Theme.uiCyan.withAlphaComponent(0.55)
            renderer.fillColor = Theme.uiCyan.withAlphaComponent(0.05)
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [6, 6]
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let plane = annotation as? PlaneAnnotation {
                parent.selectedPlaneID = plane.id
                parent.selectedAirport = nil
            } else if let airport = annotation as? AirportAnnotation {
                parent.selectedAirport = airport.airport
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Following moves the map every second; the nearby-airports list doesn't need each step.
            if !parent.followSelected { parent.onCenterChange(mapView.region.center) }
            syncAirports(mapView, force: false)
            syncPlanes(mapView)
            // Labels and headings depend on zoom and rotation.
            let tuned = parent.tunedAirport.flatMap { AirportIndex.shared.airport(icao: $0) }
            for annotation in planeAnnotations.values {
                if let view = mapView.view(for: annotation) as? PlaneAnnotationView {
                    configure(view, plane: annotation.plane, tuned: tuned, map: mapView)
                }
            }
        }
    }
}
