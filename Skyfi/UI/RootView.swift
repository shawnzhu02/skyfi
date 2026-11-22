import MapKit
import SwiftUI

struct RootView: View {
    @Environment(TrafficStore.self) private var traffic
    @Environment(Mixer.self) private var mixer
    @Environment(TalkStore.self) private var talk

    @State private var selectedPlaneID: String?
    @State private var selectedAirport: Airport?
    @State private var focus: MapFocus?
    @State private var center = CLLocationCoordinate2D(latitude: 42.36, longitude: -71.0)
    @State private var look: MapLook = .satellite
    @State private var showMixer = false
    @State private var showActivity = false
    @State private var showTranscript = false
    @State private var browser = LiveATCBrowser.shared

    private var selectedPlane: Plane? { selectedPlaneID.flatMap { traffic.planes[$0] } }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeView(planes: traffic.planes, tunedAirport: mixer.airport,
                      talking: talk.talking, favorites: Places.shared.favorites,
                      trail: traffic.trail(selectedPlaneID), look: look,
                      selectedPlaneID: $selectedPlaneID, selectedAirport: $selectedAirport, focus: $focus,
                      onCenterChange: { center = $0 })
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer()
                if let plane = selectedPlane {
                    PlaneCard(plane: plane) { selectedPlaneID = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TranscriptStrip(onPick: pick(planeID:), onOpen: { showTranscript = true })
                if browser.isOpen, !browser.expanded {
                    LiveATCMiniBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MixerBar { showMixer = true }
                Text("Traffic: \(traffic.provider.rawValue) · ATC: LiveATC.net")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .animation(.spring(duration: 0.3), value: selectedPlaneID)
            .animation(.spring(duration: 0.3), value: browser.expanded)

            if browser.isOpen {
                LiveATCPanel()
                    .padding(.bottom, 4)
            }
        }
        .background(Theme.background)
        .onAppear { traffic.setActive(true) }
        .onChange(of: mixer.airport) { _, icao in
            // Connecting shows that airport's planes and zooms to its 60 nm ring; disconnecting clears them.
            let airport = icao.flatMap { AirportIndex.shared.airport(icao: $0) }
            traffic.connect(airport)
            selectedPlaneID = nil
            // The ring is 120 nm (2° of latitude) across; leave room for the top bar and the mixer.
            if let airport { focus = MapFocus(airport.coordinate, spanDegrees: 2.9) }
        }
        .sheet(item: $selectedAirport) { airport in
            AirportSheet(airport: airport, onConnect: { selectedAirport = nil }) { plane in
                selectedAirport = nil
                selectedPlaneID = plane.id
                focus = MapFocus(plane.coordinate)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showMixer) {
            MixerSheet(center: center)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet { id in
                showTranscript = false
                pick(planeID: id)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showActivity) {
            ActivityList(events: traffic.events) { event in
                showActivity = false
                if let plane = traffic.planes[event.planeID] {
                    selectedPlaneID = plane.id
                    focus = MapFocus(plane.coordinate)
                } else if let airport = AirportIndex.shared.airport(icao: event.airport) {
                    focus = MapFocus(airport.coordinate)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private func pick(planeID: String) {
        guard let plane = traffic.planes[planeID] else { return }
        selectedAirport = nil
        selectedPlaneID = plane.id
        focus = MapFocus(plane.position(at: Date()))
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("skyfi").font(Theme.rounded(17, .heavy)).foregroundStyle(Theme.amber)
                    if let airport = traffic.connected {
                        Circle().fill(traffic.failing ? Color.red : Color.green).frame(width: 6, height: 6)
                        Text("\(airport.code)\(mixer.feed.map { " · \($0.kind.label)" } ?? "") · \(traffic.planes.count) planes")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                if traffic.connected == nil {
                    Text("Tap a cyan airport to connect").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .panel()

            Spacer()

            Button { showActivity = true } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .panel()

            Button {
                look = look == .satellite ? .night : .satellite
            } label: {
                Image(systemName: look == .satellite ? "globe.americas.fill" : "moon.stars.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .panel()
        }
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottomLeading) {
            if let event = traffic.events.first, Date().timeIntervalSince(event.time) < 90 {
                Text(event.text)
                    .font(Theme.mono(11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .panel()
                    .offset(y: 34)
                    .transition(.opacity)
                    .id(event.id)
            }
        }
    }
}

struct PlaneCard: View {
    let plane: Plane
    var onClose: () -> Void
    @State private var route: String?
    @Environment(TrafficStore.self) private var traffic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(plane.title).font(Theme.mono(20, .bold)).foregroundStyle(Theme.cyan)
                if let type = plane.type {
                    Text(type).font(Theme.mono(13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            if let line = [plane.operatorName, plane.typeName].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(line).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if let route {
                Text(route).font(Theme.mono(13)).foregroundStyle(Theme.amber)
            }
            HStack(spacing: 18) {
                stat("ALT", Format.altitude(plane))
                stat("SPD", Format.speed(plane.groundSpeed))
                stat("V/S", Format.verticalRate(plane.verticalRate))
                if let reg = plane.registration { stat("REG", reg) }
                if let airport = traffic.connected, let facility = LikelyFacility.guess(plane, airport: airport) {
                    stat("ON", facility.rawValue)
                        .accessibilityLabel("Likely talking to \(airport.code) \(facility.label)")
                }
            }
        }
        .padding(14)
        .panel()
        .task(id: plane.id) {
            route = nil
            if let callsign = plane.callsign {
                route = await RouteLookup.shared.route(callsign: callsign, lat: plane.lat, lon: plane.lon)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(13)).foregroundStyle(Theme.text)
        }
    }
}

struct ActivityList: View {
    let events: [AirportEvent]
    var onPick: (AirportEvent) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView("No takeoffs or landings yet", systemImage: "airplane.departure",
                                           description: Text("Zoom in near a busy airport. Takeoffs and landings show up here as they happen."))
                } else {
                    List(events) { event in
                        Button { onPick(event) } label: { EventRow(event: event) }
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct EventRow: View {
    let event: AirportEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind == .departure ? "airplane.departure" : "airplane.arrival")
                .foregroundStyle(event.kind == .departure ? Theme.amber : Theme.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text).font(Theme.mono(13)).foregroundStyle(Theme.text)
                if let type = event.type {
                    Text(type).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Text(Format.ago(event.time)).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
