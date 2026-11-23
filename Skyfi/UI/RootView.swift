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
    /// The selected plane just landed or took off: a short banner.
    @State private var selectedEvent: AirportEvent?
    /// "BOS information Lima now current": a new ATIS at the connected airport.
    @State private var notice: String?

    /// The connected airport and its current ATIS letter(s).
    private var atisKey: String {
        guard let icao = traffic.connected?.icao else { return "" }
        // Sorted "arr:L" pairs, so the API listing them in another order isn't a change.
        return icao + "|" + ATISStore.shared.atis(icao).map { "\($0.kind.rawValue):\($0.code)" }.sorted().joined(separator: ",")
    }
    /// Callsign of a plane picked from the worldwide search, shown while it loads.
    @State private var pendingTitle: String?

    @State private var activeRunways: Set<String> = []

    /// Changes only when something the runway pick depends on changes, so the pick isn't redone every tick.
    private var runwayInputs: String {
        guard let icao = traffic.connected?.icao else { return "" }
        let atis = ATISStore.shared.atis(icao).map { "\($0.kind)\($0.code)" }.joined()
        let metar = WeatherStore.shared.metar(icao)?.observed?.timeIntervalSince1970 ?? 0
        return "\(icao)|\(atis)|\(metar)|\(traffic.events.count)|\(traffic.events.last?.id.uuidString ?? "")"
    }

    /// Runways in use at the connected airport: what the ATIS says, else what traffic and wind suggest.
    private func pickActiveRunways() -> Set<String> {
        guard let airport = traffic.connected else { return [] }
        let atis = ATIS.runways(in: ATISStore.shared.atis(airport.icao), airport: airport)
        if !atis.isEmpty { return Set(atis.landing + atis.departing) }
        let guess = RunwayGuess.guess(airport: airport, events: traffic.events(at: airport),
                                      metar: WeatherStore.shared.metar(airport.icao))
        return Set(guess?.runways ?? [])
    }

    /// No position report for 15 s: the plane may have dropped out of receiver range.
    static func lostSignal(_ plane: Plane) -> Bool { Date().timeIntervalSince(plane.fixTime) > 15 }
    @AppStorage("altitudeColors") private var altitudeColors = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("dataBlocks") private var dataBlocks = false
    @AppStorage("hideGround") private var hideGround = false
    /// Zoom to the plane the tower is talking to when Skyfi is sure which one it is.
    @AppStorage("autoZoomTalking") private var autoZoomTalking = true
    @State private var locator = Locator.shared
    @State private var locationDenied = false

    private var selectedPlane: Plane? { selectedPlaneID.flatMap { traffic.planes[$0] } }

    /// Off: the map keeps to the essentials (weather line, event toasts, resume chip and notices
    /// stay hidden). Kept as a switch so they can come back if they're missed.
    static let busyTopBar = false

    /// The map and everything over it.
    private var layout: some View {
        ZStack(alignment: .bottom) {
            GlobeView(planes: traffic.planes, tunedAirport: mixer.airport,
                      talking: talk.talking, favorites: Places.shared.favorites,
                      trail: traffic.trail(selectedPlaneID), look: look,
                      selectedPlaneID: $selectedPlaneID, selectedAirport: $selectedAirport, focus: $focus,
                      onCenterChange: { center = $0 },
                      // Don't keep the camera on a frozen dot once reports stop.
                      followSelected: following && !(selectedPlane.map(Self.lostSignal) ?? false),
                      onUserMove: { following = false },
                      showUser: locator.authorized, altitudeColors: altitudeColors,
                      dataBlocks: dataBlocks, hideGround: hideGround, activeRunways: activeRunways)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if altitudeColors {
                    HStack {
                        Spacer()
                        AltitudeLegend()
                    }
                }
                Spacer()
                banners
                if let plane = selectedPlane {
                    PlaneCard(plane: plane, following: $following, onAirport: { selectedAirport = $0 }) { selectedPlaneID = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TranscriptStrip(onPick: pick(planeID:), onOpen: { showTranscript = true })
                if browser.isOpen, !browser.expanded {
                    LiveATCMiniBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MixerBar { showMixer = true }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .animation(.spring(duration: 0.3), value: selectedPlaneID)
            .animation(.spring(duration: 0.3), value: browser.expanded)

            if browser.isOpen {
                LiveATCPanel { showMixer = true }
                    .padding(.bottom, 4)
            }
        }
        .background(Theme.background)
    }

    /// Banners above the plane card: emergency, resume, tip, notices, the finding-flight row.
    @ViewBuilder private var banners: some View {
        if let plane = traffic.emergencyPlane, let kind = plane.emergency {
            Button { pick(planeID: plane.id) } label: {
                Label("\(plane.title) squawking \(plane.squawk ?? "") · \(kind)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.85), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if Self.busyTopBar, seenTip, !resumeDismissed, traffic.connected == nil, mixer.music == nil, selectedPlane == nil,
           let icao = Places.shared.recents.first, let airport = AirportIndex.shared.airport(icao: icao) {
            ResumeChip(airport: airport, music: mixer.lastMusicTitle,
                       note: mixer.towerInBrowser ? "Then tap play on LiveATC's page" : "Where you left off") {
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
        if Self.busyTopBar, let notice {
            Label(notice, systemImage: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.cyan)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .panel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
        if Self.busyTopBar, let event = selectedEvent {
            Label(event.text, systemImage: event.kind == .departure ? "airplane.departure" : "airplane.arrival")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.kind == .departure ? Theme.amber : Theme.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .panel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if selectedPlane == nil, let id = selectedPlaneID {
            // Picked from the worldwide search: its area is loading.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding \(pendingTitle ?? id.uppercased())…").font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                Button { selectedPlaneID = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Cancel")
            }
            .padding(12)
            .panel()
            .task(id: id) {
                // Not in the feed after 20 s: give up quietly.
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled, selectedPlaneID == id, selectedPlane == nil {
                    dlog("traffic", "\(id) not found after 20 s")
                    selectedPlaneID = nil
                }
            }
        }
    }

    /// State changes the view reacts to (kept apart so the compiler can type-check the body).
    private func observed(_ view: some View) -> some View {
        view
        .onAppear {
            traffic.setActive(true)
            // A shortcut may have connected before this view was watching.
            if let icao = mixer.airport, traffic.connected?.icao != icao, let airport = AirportIndex.shared.airport(icao: icao) {
                traffic.connect(airport)
                focus = MapFocus(airport.coordinate, spanDegrees: 2.9)
            }
        }
        .onOpenURL { url in
            if let airport = SkyfiLink.airport(from: url) {
                dlog("app", "link: connect \(airport.icao)")
                selectedAirport = nil
                mixer.connectViaLiveATC(airport)
            }
        }
        .onChange(of: selectedPlaneID) { _, _ in
            following = false
            selectedEvent = nil
        }
        // A tap of feedback when you connect, and a warning buzz when an emergency squawk appears.
        .sensoryFeedback(.success, trigger: mixer.airport) { _, new in new != nil }
        .onChange(of: atisKey) { old, new in
            // Same airport, new letter (not the first fetch after connecting).
            let oldParts = old.split(separator: "|", omittingEmptySubsequences: false)
            let newParts = new.split(separator: "|", omittingEmptySubsequences: false)
            guard oldParts.count == 2, newParts.count == 2, oldParts[0] == newParts[0],
                  !oldParts[1].isEmpty, !newParts[1].isEmpty, oldParts[1] != newParts[1],
                  let airport = traffic.connected else { return }
            let broadcasts = ATISStore.shared.atis(airport.icao)
            let runways = ATIS.runways(in: broadcasts, airport: airport)
            // Name the broadcast whose letter changed (arrival and departure ATIS change separately).
            let before = Set(oldParts[1].split(separator: ",").map(String.init))
            let changed = broadcasts.first { !before.contains("\($0.kind.rawValue):\($0.code)") } ?? broadcasts.first
            let which = changed?.kind == .arrival ? " arrival" : (changed?.kind == .departure ? " departure" : "")
            var text = "\(airport.code)\(which) information \(changed?.code ?? "") now current"
            if !runways.landing.isEmpty { text += " · landing \(runways.landing.joined(separator: ", "))" }
            dlog("weather", text)
            withAnimation { notice = text }
            Task {
                try? await Task.sleep(for: .seconds(10))
                if notice == text { withAnimation { notice = nil } }
            }
        }
        .onChange(of: traffic.events.first(where: { $0.planeID == selectedPlaneID })?.id) { _, _ in
            // The plane you're watching touched down or lifted off (just now, not before you picked it).
            guard let event = traffic.events.first(where: { $0.planeID == selectedPlaneID }),
                  Date().timeIntervalSince(event.time) < 60 else { return }
            withAnimation { selectedEvent = event }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if selectedEvent?.id == event.id { withAnimation { selectedEvent = nil } }
            }
        }
    }

    private func observedMore(_ view: some View) -> some View {
        view
        .onChange(of: talk.lines.first?.id) { _, _ in
            // A confident callsign match (the matcher only names a plane when it's clearly ahead).
            guard autoZoomTalking, let line = talk.lines.first, let id = line.planeID,
                  let plane = traffic.planes[id], Date().timeIntervalSince(line.time) < 30 else { return }
            following = false
            selectedAirport = nil
            selectedPlaneID = plane.id
            focus = MapFocus(plane.position(at: Date()), spanDegrees: 0.25)
        }
        .sensoryFeedback(.warning, trigger: traffic.emergencyPlane?.id) { _, new in new != nil }
        .onChange(of: selectedPlaneID) { _, new in
            // Picked something else (or closed the card): stop polling around a pinned plane.
            if let pinned = traffic.pinnedID, pinned != new { traffic.unpin() }
        }
        .onChange(of: selectedPlane?.id) { old, new in
            // The plane left the picture (out of range or no reports): drop the card and stop following.
            // A plane picked from the worldwide search isn't loaded yet, so only the one that vanished counts.
            if new == nil, let old, old == selectedPlaneID {
                selectedPlaneID = nil
                following = false
            }
        }
        .onChange(of: runwayInputs, initial: true) { _, _ in
            let picked = pickActiveRunways()
            if picked != activeRunways { activeRunways = picked }
        }
        .onChange(of: keepAwake && traffic.connected != nil, initial: true) { _, awake in
            // A desk radio: the map stays up while you listen.
            UIApplication.shared.isIdleTimerDisabled = awake
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
    }

    var body: some View {
        observedMore(observed(layout))
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
                pendingTitle = plane.title
                // From the worldwide search: not in this airport's picture, so poll around it.
                if traffic.planes[plane.id] == nil { traffic.pin(plane) }
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

    private var statusTitle: String {
        guard let airport = traffic.connected else { return "Skyfi" }
        guard let feed = mixer.feed else { return "\(airport.name) · tower off" }
        if mixer.towerInBrowser {
            if browser.suspended { return "Paused · \(feed.name)" }
            switch browser.media {
            case .playing: return "Listening to \(feed.name)"
            case .loading: return "Connecting to \(feed.name)…"
            case .failed: return "\(feed.name) isn't playing"
            case .paused, .none: return "\(feed.name) · tap play below"
            }
        }
        switch mixer.atcStatus {
        case .playing: return "Listening to \(feed.name)"
        case .loading: return "Connecting to \(feed.name)…"
        case .failed: return "\(feed.name) isn't playing"
        default: return feed.name
        }
    }

    private var statusColor: Color {
        guard traffic.connected != nil else { return Theme.amber }
        let playing = mixer.towerInBrowser ? (browser.media == .playing && !browser.suspended) : mixer.atcStatus == .playing
        if playing { return Theme.live }
        if case .failed = browser.media, mixer.towerInBrowser { return .red }
        return Theme.muted
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
                // One plain sentence about what Skyfi is doing, then the plane count.
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                if let airport = traffic.connected {
                    Text(traffic.failing ? "Plane data is offline, retrying" : "\(traffic.planes.count) planes around \(airport.code)")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if Self.busyTopBar, let airport = traffic.connected, let metar = WeatherStore.shared.metar(airport.icao) {
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
                    Text("Tap a blue airport to listen to its tower").font(.system(size: 12)).foregroundStyle(Theme.muted)
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
            if Self.busyTopBar, let event = traffic.events.first, Date().timeIntervalSince(event.time) < 90 {
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
    /// Tapped an airport on the route bar.
    var onAirport: (Airport) -> Void = { _ in }
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
            if RootView.busyTopBar, let whereText = Self.position(plane, near: traffic.connected) {
                Text(whereText).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if RootView.lostSignal(plane) {
                Label("No signal for \(Int(Date().timeIntervalSince(plane.fixTime))) s", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
            }
            if let route {
                if RootView.busyTopBar, !plane.onGround, let progress = FlightProgress.from(route: route, plane: plane) {
                    ProgressRow(progress: progress, onAirport: onAirport)
                } else {
                    Text(route).font(Theme.mono(13)).foregroundStyle(Theme.amber)
                }
            }
            if RootView.busyTopBar, let airport = traffic.connected, EventDetector.isApproaching(plane, to: airport),
               let minutes = EventDetector.minutesToLanding(plane, at: airport) {
                Text("Landing \(airport.code)\(EventDetector.landingRunway(plane, at: airport).map { " \($0)" } ?? "") in about \(minutes) min")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cyan)
            }
            HStack(spacing: 14) {
                stat("ALT", Format.altitude(plane))
                stat("SPD", Format.speed(plane.groundSpeed))
                // Only an emergency code earns the room.
                if plane.emergency != nil, let squawk = plane.squawk { stat("SQK", squawk) }
                if RootView.busyTopBar, let airport = traffic.connected, TrafficStore.inRange(plane, of: airport),
                   let facility = LikelyFacility.guess(plane, airport: airport) {
                    // "TWR 128.8" when the airport has just one tower frequency.
                    let mhz = FrequencyIndex.shared.single(airport.icao, kind: facility.rawValue)?.mhzText
                    stat("ON", [facility.rawValue, mhz].compactMap { $0 }.joined(separator: " "))
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

    /// "12 nm SW of BOS": from the connected airport, or the nearest one within 60 nm.
    static func position(_ plane: Plane, near connected: Airport?) -> String? {
        // A plane from the worldwide search can be an ocean away from the connected airport.
        let local = connected.flatMap { Geo.distanceNM($0.lat, $0.lon, plane.lat, plane.lon) <= 150 ? $0 : nil }
        let airport = local ?? AirportIndex.shared.nearest(lat: plane.lat, lon: plane.lon, withinNM: 60)
        guard let airport else { return nil }
        let distance = Geo.distanceNM(airport.lat, airport.lon, plane.lat, plane.lon)
        if distance < 1 { return "At \(airport.code)" }
        let bearing = Geo.bearing(airport.lat, airport.lon, plane.lat, plane.lon)
        return "\(Int(distance.rounded())) nm \(compass(bearing)) of \(airport.code)"
    }

    static func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
        return points[index]
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
    @State var worldwide: [Plane] = []

    /// Military, rare types and emergencies on the map right now, emergencies first.
    var notableNow: [Plane] {
        planes.filter { $0.notable != nil }
            .sorted { ($0.emergency == nil ? 1 : 0, $0.title) < ($1.emergency == nil ? 1 : 0, $1.title) }
            .prefix(20).map { $0 }
    }
    @State var searching = false
    @State var searchedFor = ""

    var body: some View {
        // "Notable nearby" is off with the rest of the extras.
        let notable = RootView.busyTopBar ? notableNow : []
        NavigationStack {
            Group {
                if !query.isEmpty {
                    let found = Self.search(planes, query)
                    if found.isEmpty {
                        worldwideResults
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
                } else if events.isEmpty, notable.isEmpty {
                    ContentUnavailableView("No takeoffs or landings yet", systemImage: "airplane.departure",
                                           description: Text("Zoom in near a busy airport. Takeoffs and landings show up here as they happen."))
                } else {
                    List {
                        if !notable.isEmpty {
                            Section("Notable nearby") {
                                ForEach(notable) { plane in
                                    Button { onPickPlane(plane) } label: {
                                        HStack {
                                            Image(systemName: plane.emergency != nil ? "exclamationmark.triangle.fill" : "star.fill")
                                                .font(.system(size: 11)).foregroundStyle(plane.emergency != nil ? .red : Theme.amber)
                                            Text(plane.title).font(Theme.mono(13)).foregroundStyle(Theme.text)
                                            Text(plane.notable ?? "").font(.system(size: 12)).foregroundStyle(Theme.amber)
                                            Spacer()
                                            Text(Format.altitude(plane)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                        if !events.isEmpty {
                            Section("Takeoffs and landings") {
                                ForEach(events) { event in
                                    Button { onPick(event) } label: { EventRow(event: event) }
                                        .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a flight (DAL234, N123AB, A321)")
            .onSubmit(of: .search) { Task { await searchWorldwide() } }
            .onChange(of: query) { _, _ in
                if query.uppercased() != searchedFor {
                    worldwide = []
                    searching = false
                }
            }
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
    let note: String
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
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
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

/// BOS ━━━━✈︎───── LAX, with the distance left.
struct ProgressRow: View {
    let progress: FlightProgress
    var onAirport: (Airport) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                code(progress.from)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.muted.opacity(0.3)).frame(height: 3)
                        Capsule().fill(Theme.amber).frame(width: geo.size.width * progress.fraction, height: 3)
                        Image(systemName: "airplane")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.amber)
                            .offset(x: max(0, geo.size.width * progress.fraction - 6))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 14)
                code(progress.to)
            }
            Text("\(Int(progress.remainingNM.rounded()).formatted()) nm to \(progress.to.city ?? progress.to.code)")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(progress.from.code) to \(progress.to.code), \(Int(progress.fraction * 100)) percent flown, \(Int(progress.remainingNM)) nautical miles to go")
    }
    private func code(_ airport: Airport) -> some View {
        Button { onAirport(airport) } label: {
            Text(airport.code).font(Theme.mono(13, .bold)).foregroundStyle(Theme.amber).underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(airport.name)")
    }

}

extension ActivityList {
    /// Not on the map here: offer adsb.lol's worldwide lookup, then list what it finds.
    @ViewBuilder var worldwideResults: some View {
        if searching {
            ProgressView("Searching worldwide…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !worldwide.isEmpty {
            List(worldwide) { plane in
                Button { onPickPlane(plane) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(plane.title).font(Theme.mono(13)).foregroundStyle(Theme.text)
                            if let type = plane.type { Text(type).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                            Spacer()
                            Text(Format.altitude(plane)).font(Theme.mono(12)).foregroundStyle(Theme.amber)
                        }
                        Text(nearText(plane)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        } else if searchedFor == query.uppercased(), !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("Not near you", systemImage: "globe")
            } description: {
                Text("Search every flight in the world for \(query.uppercased()).")
            } actions: {
                Button("Search worldwide") { Task { await searchWorldwide() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.cyan)
            }
        }
    }

    func searchWorldwide() async {
        let q = query.uppercased()
        guard !ADSBClient.Lookup.from(q).isEmpty else { return }
        searching = true
        dlog("traffic", "worldwide search \(q)")
        let found = await ADSBClient().find(q)
        // You typed something else meanwhile: this answer is for an old question.
        guard query.uppercased() == q else { return }
        worldwide = found.compactMap { Plane($0, now: Date()) }
        searchedFor = q
        searching = false
    }

    /// "Near London Heathrow Airport", or the coordinates out over the ocean.
    func nearText(_ plane: Plane) -> String {
        if let airport = AirportIndex.shared.nearest(lat: plane.lat, lon: plane.lon, withinNM: 150) {
            return "Near \(airport.name)"
        }
        return String(format: "%.1f°, %.1f°", plane.lat, plane.lon)
    }
}

/// The altitude color scale, shown while planes are colored by altitude.
struct AltitudeLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("0").font(Theme.mono(9)).foregroundStyle(Theme.muted)
            LinearGradient(colors: stride(from: 0, through: 40000, by: 4000).map { Color(PlaneAnnotationView.altitudeColor($0)) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 90, height: 6)
                .clipShape(Capsule())
            Text("40k ft").font(Theme.mono(9)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Altitude colors: orange near the ground to violet at 40,000 feet")
    }
}
