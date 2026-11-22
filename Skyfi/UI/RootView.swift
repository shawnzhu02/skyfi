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
    @AppStorage("seenFirstRunTip") private var seenTip = false
    @State private var following = false
    @State private var resumeDismissed = false
    @AppStorage("altitudeColors") private var altitudeColors = false
    @State private var locator = Locator.shared
    @State private var locationDenied = false

    private var selectedPlane: Plane? { selectedPlaneID.flatMap { traffic.planes[$0] } }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeView(planes: traffic.planes, tunedAirport: mixer.airport,
                      talking: talk.talking, favorites: Places.shared.favorites,
                      trail: traffic.trail(selectedPlaneID), look: look,
                      selectedPlaneID: $selectedPlaneID, selectedAirport: $selectedAirport, focus: $focus,
                      onCenterChange: { center = $0 },
                      followSelected: following, onUserMove: { following = false },
                      showUser: locator.authorized, altitudeColors: altitudeColors)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer()
                if let plane = traffic.emergencyPlane, let kind = plane.emergency {
                    Button { pick(planeID: plane.id) } label: {
                        Label("\(plane.title) squawking \(plane.squawk ?? "") · \(kind)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.85), in: Capsule())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if seenTip, !resumeDismissed, traffic.connected == nil, mixer.music == nil, selectedPlane == nil,
                   let icao = Places.shared.recents.first, let airport = AirportIndex.shared.airport(icao: icao) {
                    ResumeChip(airport: airport, music: mixer.lastMusicTitle) {
                        resumeDismissed = true
                        // Works for airports without a Skyfi feed list too (LiveATC's airport page).
                        mixer.connectViaLiveATC(airport)
                        Task { await mixer.playLastMusic() }
                    } onClose: {
                        resumeDismissed = true
                    }
                    .transition(.opacity)
                }
                if !seenTip, traffic.connected == nil, selectedPlane == nil {
                    FirstRunTip { seenTip = true }
                        .transition(.opacity)
                }
                if let plane = selectedPlane {
                    PlaneCard(plane: plane, following: $following) { selectedPlaneID = nil }
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
        .onAppear {
            traffic.setActive(true)
            // A shortcut may have connected before this view was watching.
            if let icao = mixer.airport, traffic.connected?.icao != icao {
                traffic.connect(AirportIndex.shared.airport(icao: icao))
            }
        }
        .onOpenURL { url in
            if let airport = SkyfiLink.airport(from: url) {
                dlog("app", "link: connect \(airport.icao)")
                selectedAirport = nil
                mixer.connect(airport)
            }
        }
        .onChange(of: selectedPlaneID) { _, _ in following = false }
        // A tap of feedback when you connect, and a warning buzz when an emergency squawk appears.
        .sensoryFeedback(.success, trigger: mixer.airport) { _, new in new != nil }
        .sensoryFeedback(.warning, trigger: traffic.emergencyPlane?.id) { _, new in new != nil }
        .onChange(of: selectedPlane == nil) { _, gone in
            // The plane left the picture (out of range or no reports): drop the card and stop following.
            if gone, selectedPlaneID != nil {
                selectedPlaneID = nil
                following = false
            }
        }
        .onChange(of: locator.denied) { _, denied in
            if denied { locationDenied = true }
        }
        .onChange(of: locator.location) { _, location in
            guard let location else { return }
            focus = MapFocus(location.coordinate, spanDegrees: 4)
            // Not connected yet: offer the nearest airport with a feed.
            if traffic.connected == nil,
               let nearest = Catalog.airports(near: location.coordinate).first, nearest.distanceNM < 200 {
                selectedAirport = nearest.airport
            }
        }
        .alert("Location is off for Skyfi", isPresented: $locationDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Turn it on in Settings to center the map on you.")
        }
        .task(id: traffic.connected?.icao) {
            // The connected airport's weather for the top bar (the store caches 10 minutes).
            guard let icao = traffic.connected?.icao else { return }
            while !Task.isCancelled {
                await WeatherStore.shared.refresh(icao)
                await ATISStore.shared.refresh(icao)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .onChange(of: traffic.connected) { _, airport in
            // Connected once: the tip has done its job.
            if airport != nil { seenTip = true }
        }
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
            ActivityList(events: traffic.events, planes: Array(traffic.planes.values), onPickPlane: { plane in
                showActivity = false
                selectedPlaneID = plane.id
                focus = MapFocus(plane.coordinate)
            }) { event in
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
                if let airport = traffic.connected, let metar = WeatherStore.shared.metar(airport.icao) {
                    HStack(spacing: 6) {
                        Text(metar.category.rawValue).font(Theme.mono(10, .bold))
                            .foregroundStyle(WeatherSection.color(metar.category))
                        Text(metar.windText).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        let atis = ATISStore.shared.atis(airport.icao)
                        let runways = ATIS.runways(in: atis, airport: airport)
                        // Only a current broadcast (an hour old at most) earns the top bar.
                        if let code = atis.first?.code, !code.isEmpty,
                           let updated = atis.compactMap(\.updated).max(), Date().timeIntervalSince(updated) < 3600 {
                            Text("ATIS \(code)\(runways.landing.first.map { " · \($0)" } ?? "")")
                                .font(Theme.mono(10)).foregroundStyle(Theme.cyan)
                        }
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

            Button {
                locator.request()
                if locator.denied { locationDenied = true }
            } label: {
                Image(systemName: locator.authorized ? "location.fill" : "location")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .panel()
            .accessibilityLabel("Near me")

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
    @Binding var following: Bool
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
            if let airport = traffic.connected, EventDetector.isApproaching(plane, to: airport),
               let minutes = EventDetector.minutesToLanding(plane, at: airport) {
                Text("Landing \(airport.code)\(EventDetector.landingRunway(plane, at: airport).map { " \($0)" } ?? "") in about \(minutes) min")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cyan)
            }
            HStack(spacing: 14) {
                stat("ALT", Format.altitude(plane))
                stat("SPD", Format.speed(plane.groundSpeed))
                stat("V/S", Format.verticalRate(plane.verticalRate))
                if let reg = plane.registration { stat("REG", reg) }
                // Only an emergency code earns the room (the row is full on small phones).
                if plane.emergency != nil, let squawk = plane.squawk { stat("SQK", squawk) }
                if let airport = traffic.connected, let facility = LikelyFacility.guess(plane, airport: airport) {
                    stat("ON", facility.rawValue)
                        .accessibilityLabel("Likely talking to \(airport.code) \(facility.label)")
                }
            }
            HStack(spacing: 16) {
                Button { following.toggle() } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "location.fill" : "location")
                }
                if let url = Self.flightAware(plane) {
                    Link(destination: url) {
                        Label("FlightAware", systemImage: "arrow.up.right.square")
                    }
                    ShareLink(item: url, message: Text(Self.shareText(plane, near: traffic.connected))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.cyan)
            .buttonStyle(.plain)
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

    static func shareText(_ plane: Plane, near airport: Airport?) -> String {
        var parts = [plane.title]
        if let type = plane.type { parts.append(type) }
        parts.append(plane.onGround ? "on the ground" : "at \(Format.altitude(plane))")
        if let airport { parts.append("near \(airport.code)") }
        return parts.joined(separator: " ") + ", spotted on Skyfi"
    }

    /// The flight's page on FlightAware (by callsign, else registration).
    static func flightAware(_ plane: Plane) -> URL? {
        let ident = (plane.callsign ?? plane.registration ?? "").filter { $0.isLetter || $0.isNumber }
        guard !ident.isEmpty else { return nil }
        return URL(string: "https://www.flightaware.com/live/flight/\(ident)")
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
    var planes: [Plane] = []
    var onPickPlane: (Plane) -> Void = { _ in }
    var onPick: (AirportEvent) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if !query.isEmpty {
                    let found = Self.search(planes, query)
                    if found.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(found) { plane in
                            Button { onPickPlane(plane) } label: {
                                HStack {
                                    Text(plane.title).font(Theme.mono(13)).foregroundStyle(Theme.text)
                                    if let type = plane.type {
                                        Text(type).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                    if let name = plane.operatorName {
                                        Text(name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(Format.altitude(plane)).font(Theme.mono(12)).foregroundStyle(Theme.amber)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                    }
                } else if events.isEmpty {
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
            .searchable(text: $query, prompt: "Find a flight (DAL234, N123AB, A321)")
        }
    }

    /// Planes on the map matching a callsign, registration, type or airline.
    static func search(_ planes: [Plane], _ query: String) -> [Plane] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return planes.filter { plane in
            [plane.callsign, plane.registration, plane.type, plane.operatorName, plane.id]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(q) }
        }
        .sorted { $0.title < $1.title }
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

/// Shown until dismissed: how to get from the globe to tower audio.
struct FirstRunTip: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Welcome to Skyfi").font(Theme.rounded(16, .bold)).foregroundStyle(Theme.amber)
                Spacer()
                Button(action: onDone) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Close tip")
            }
            step("1", "Tap a cyan airport, then Connect. Its planes show up within 60 nm.")
            step("2", "LiveATC's player opens. Tap play on their page to hear the tower.")
            step("3", "Pick lofi or paste a YouTube link in the mixer below. Minimize the player and enjoy.")
            Button("Got it", action: onDone)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.cyan)
        }
        .padding(14)
        .panel()
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(Theme.mono(12, .bold)).foregroundStyle(Theme.cyan).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text)
        }
    }
}

/// "Resume BOS + Lofi Girl": the last airport and music, one tap away at launch.
struct ResumeChip: View {
    let airport: Airport
    let music: String?
    var onResume: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onResume) {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Resume \(airport.code)\(music.map { " + \($0)" } ?? "")")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("Where you left off").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panel()
    }
}
