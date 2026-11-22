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
    let look: MapLook
    @Binding var selectedPlaneID: String?
    @Binding var selectedAirport: Airport?
    @Binding var focus: MapFocus?
    var onCenterChange: (CLLocationCoordinate2D) -> Void

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
        context.coordinator.startTicker()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
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
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: GlobeView
        weak var map: MKMapView?
        var look: MapLook?
        private var planeAnnotations: [String: PlaneAnnotation] = [:]
        private var airportAnnotations: [String: AirportAnnotation] = [:]
        private var ticker: Timer?
        private var appObservers: [NSObjectProtocol] = []
        private var lastAirportRegion: MKCoordinateRegion?
        private var lastTuned: String?
        private var rangeRing: MKCircle?

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

        /// Glides every plane to where it should be one second from now.
        private func tick() {
            let target = Date().addingTimeInterval(1)
            UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .allowUserInteraction, .beginFromCurrentState]) {
                for annotation in self.planeAnnotations.values {
                    annotation.coordinate = annotation.plane.position(at: target)
                }
            }
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
            syncAirports(map, force: tunedChanged)
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
                        view.configure(airport: airport, tuned: icao == parent.tunedAirport, hasFeed: Catalog.connectable.contains(icao))
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
            if plane.onGround { return .ground }
            if let tuned, EventDetector.isApproaching(plane, to: tuned) { return .approach }
            return .airborne
        }

        private func configure(_ view: PlaneAnnotationView, plane: Plane, tuned: Airport?, map: MKMapView) {
            view.configure(plane: plane, style: style(for: plane, tuned: tuned),
                           showLabel: map.region.span.latitudeDelta < Self.labelSpan || plane.id == parent.selectedPlaneID,
                           mapHeading: map.camera.heading)
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
                               hasFeed: Catalog.connectable.contains(airport.airport.icao))
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
            parent.onCenterChange(mapView.region.center)
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
