import MapKit
import SwiftUI

enum MapLook: String, CaseIterable {
    case satellite
    case night

    var label: String { self == .satellite ? "Satellite" : "Night" }
}

/// The 3D globe. MapKit draws a real globe when zoomed out with the satellite/hybrid configurations.
struct GlobeView: UIViewRepresentable {
    let traffic: TrafficStore
    let planes: [String: Plane]
    let tunedAirport: String?
    let talking: [String: TalkStore.Talk]
    let look: MapLook
    @Binding var selectedPlaneID: String?
    @Binding var selectedAirport: Airport?
    @Binding var focus: CLLocationCoordinate2D?
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
        // Start over Boston at a regional zoom; pinch out for the globe.
        let start = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.0)
        map.setRegion(MKCoordinateRegion(center: start, span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3)), animated: false)
        context.coordinator.map = map
        context.coordinator.installArrow(on: map)
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
            map.setCenter(focus, animated: true)
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
        private var lastAirportRegion: MKCoordinateRegion?
        private let arrow = UIImageView(image: UIImage(systemName: "location.north.fill",
                                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)))

        static let maxPlanes = 1500
        static let labelSpan = 1.2

        init(_ parent: GlobeView) {
            self.parent = parent
            self.look = parent.look
        }

        func startTicker() {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
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
            syncAirports(map, force: false)
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
            let includeMedium = span.latitudeDelta < 6
            let minLon = region.center.longitude - span.longitudeDelta / 2
            let maxLon = region.center.longitude + span.longitudeDelta / 2
            let airports = span.latitudeDelta > 60 ? [] : AirportIndex.shared.airports(
                minLat: region.center.latitude - span.latitudeDelta / 2,
                maxLat: region.center.latitude + span.latitudeDelta / 2,
                minLon: minLon < -180 ? minLon + 360 : minLon,
                maxLon: maxLon > 180 ? maxLon - 360 : maxLon,
                includeMedium: includeMedium, limit: 250)
            var wanted = Dictionary(airports.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
            if let tuned = parent.tunedAirport, let airport = AirportIndex.shared.airport(icao: tuned) {
                wanted[tuned] = airport
            }
            let gone = airportAnnotations.filter { wanted[$0.key] == nil }
            if !gone.isEmpty {
                map.removeAnnotations(Array(gone.values))
                for key in gone.keys { airportAnnotations[key] = nil }
            }
            var added: [AirportAnnotation] = []
            for (icao, airport) in wanted {
                if let existing = airportAnnotations[icao] {
                    if let view = map.view(for: existing) as? AirportAnnotationView {
                        view.configure(airport: airport, tuned: icao == parent.tunedAirport, hasFeed: !Catalog.feeds(at: icao).isEmpty)
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
                               hasFeed: !Catalog.feeds(at: airport.airport.icao).isEmpty)
                return view
            }
            return nil
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
            let region = mapView.region
            parent.traffic.setVisibleRegion(center: region.center, latDelta: region.span.latitudeDelta,
                                            lonDelta: region.span.longitudeDelta)
            parent.onCenterChange(region.center)
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
