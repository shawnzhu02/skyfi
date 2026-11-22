import SwiftUI

struct AirportSheet: View {
    let airport: Airport
    var onConnect: () -> Void
    var onPickPlane: (Plane) -> Void

    @Environment(TrafficStore.self) private var traffic
    @Environment(Mixer.self) private var mixer
    @State private var places = Places.shared
    @State private var weather = WeatherStore.shared
    @State private var atisStore = ATISStore.shared

    private var isConnected: Bool { mixer.airport == airport.icao }

    var body: some View {
        let feeds = Catalog.feeds(at: airport.icao)
        let approaching = isConnected ? traffic.approaching(airport) : []
        let events = traffic.events(at: airport)
        let ground = isConnected ? traffic.onGround(at: airport).count : 0

        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(airport.name).font(Theme.rounded(18, .bold))
                        Text([airport.icao, airport.iata, airport.city].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        if isConnected {
                            Text("\(ground) on the ground · \(approaching.count) on approach")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            let hour = events.filter { Date().timeIntervalSince($0.time) < 3600 }
                            if !hour.isEmpty {
                                Text("Last hour: \(hour.filter { $0.kind == .arrival }.count) landings · \(hour.filter { $0.kind == .departure }.count) takeoffs")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                let broadcasts = atisStore.atis(airport.icao)
                let atisRunways = ATIS.runways(in: broadcasts, airport: airport)
                // The ATIS says which runways are in use; only guess when it doesn't.
                WeatherSection(airport: airport, metar: weather.metar(airport.icao),
                               runways: atisRunways.isEmpty ? RunwayGuess.guess(airport: airport, events: events, metar: weather.metar(airport.icao)) : nil)
                ATISSection(broadcasts: broadcasts, runways: atisRunways)

                Section {
                    if feeds.isEmpty, !mixer.towerInBrowser {
                        Text("No live feed for this airport in Skyfi yet.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    } else if feeds.isEmpty {
                        if isConnected {
                            Button { mixer.disconnect() } label: {
                                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.cyan)
                            }
                        }
                        Button {
                            mixer.connectViaLiveATC(airport)
                            onConnect()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(isConnected ? "Show LiveATC's feeds here" : "Find feeds on LiveATC",
                                      systemImage: "magnifyingglass")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.cyan)
                                Text("Skyfi has no feed list for \(airport.code). LiveATC's page shows any it has; pick one there.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    } else {
                        connectButton
                        if isConnected, mixer.towerInBrowser {
                            Button {
                                mixer.connect(airport)
                                onConnect()
                            } label: {
                                Label(LiveATCBrowser.shared.isOpen ? "Show LiveATC player" : "Play tower in LiveATC player",
                                      systemImage: "play.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.cyan)
                            }
                        }
                    }
                } footer: {
                    if !feeds.isEmpty {
                        if mixer.towerInBrowser {
                            Text("Opens LiveATC's own player for the \(feeds[0].kind.label.lowercased()) and shows the planes within \(TrafficStore.rangeNM) nm it could be talking to.")
                        } else {
                            Text("Plays \(feeds.map(\.kind.label).joined(separator: ", then ")) if one is offline, and shows the planes within \(TrafficStore.rangeNM) nm they could be talking to.")
                        }
                    }
                }

                if mixer.towerInBrowser, feeds.count > 1 {
                    Section("Feeds") {
                        ForEach(feeds) { feed in
                            Button {
                                mixer.play(feed, at: airport)
                                onConnect()
                            } label: {
                                HStack {
                                    Text(feed.kind.tag).font(Theme.mono(11, .bold)).foregroundStyle(Theme.cyan).frame(width: 34, alignment: .leading)
                                    Text(feed.name).font(.system(size: 14)).foregroundStyle(Theme.text)
                                    Spacer()
                                    if isConnected, mixer.feed?.mount == feed.mount {
                                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.cyan)
                                    }
                                }
                            }
                        }
                    }
                }

                if isConnected {
                    if !approaching.isEmpty {
                        Section("On approach") {
                            ForEach(approaching) { plane in
                                Button { onPickPlane(plane) } label: {
                                    ApproachRow(plane: plane, airport: airport)
                                }
                            }
                        }
                    }

                    Section("Takeoffs and landings") {
                        if events.isEmpty {
                            Text("Nothing yet. They show up here live while Skyfi is open.")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        ForEach(events.prefix(50)) { event in
                            Button {
                                if let plane = traffic.planes[event.planeID] { onPickPlane(plane) }
                            } label: { EventRow(event: event) }
                        }
                    }
                } else if !feeds.isEmpty {
                    Section {
                        Text("Connect to see its planes, takeoffs and landings.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(airport.code)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        places.toggleFavorite(airport.icao)
                    } label: {
                        Image(systemName: places.isFavorite(airport.icao) ? "star.fill" : "star")
                            .foregroundStyle(Theme.amber)
                    }
                    .accessibilityLabel(places.isFavorite(airport.icao) ? "Remove from favorites" : "Add to favorites")
                }
            }
            .task(id: airport.icao) {
                // Keeps the weather fresh while the card is open (the store caches 10 minutes).
                while !Task.isCancelled {
                    await weather.refresh(airport.icao)
                    await atisStore.refresh(airport.icao)
                    try? await Task.sleep(for: .seconds(120))
                }
            }
        }
    }

    private var connectButton: some View {
        Button {
            if isConnected, !isFailed(mixer.atcStatus) {
                mixer.disconnect()
            } else {
                mixer.connect(airport)
                onConnect()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isConnected ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
            .foregroundStyle(Theme.cyan)
            .padding(.vertical, 6)
        }
    }

    private var title: String {
        guard isConnected else { return "Connect" }
        switch mixer.atcStatus {
        case .loading: return "Connecting…"
        case .failed: return "Retry now"
        default: return "Disconnect"
        }
    }

    private var detail: String? {
        guard isConnected else { return Catalog.feed(at: airport.icao)?.name }
        switch mixer.atcStatus {
        case .failed(let message): return message
        case .paused: return "Connected · \(mixer.feed?.name ?? "") · paused"
        case .loading: return mixer.feed?.name
        default:
            guard let feed = mixer.feed else { return "Connected · tower off" }
            return mixer.towerInBrowser ? "Connected · \(feed.name) in LiveATC's player" : "Connected · \(feed.name)"
        }
    }

    private func isFailed(_ status: Mixer.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}

/// METAR line on the airport card: flight category, wind, visibility, ceiling, and the runway guess.
struct WeatherSection: View {
    let airport: Airport
    let metar: METAR?
    let runways: RunwayGuess.Result?
    @State private var showRaw = false

    var body: some View {
        if let metar {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(metar.category.rawValue)
                            .font(Theme.mono(11, .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.color(metar.category).opacity(0.25), in: Capsule())
                            .foregroundStyle(Self.color(metar.category))
                        Text(metar.windText).font(Theme.mono(13)).foregroundStyle(Theme.text)
                        Spacer()
                        if let observed = metar.observed {
                            Text(Format.ago(observed)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    Text([metar.visibilityText, metar.ceilingText, metar.weather, metar.temperatureText,
                          metar.altimeterInHg.map { String(format: "%.2f inHg", $0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if let runways, !runways.runways.isEmpty {
                        Text("Runway\(runways.runways.count > 1 ? "s" : "") \(runways.runways.joined(separator: ", ")) \(runways.fromTraffic ? "in use (recent traffic)" : "favored by the wind")")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cyan)
                    }
                    if showRaw {
                        Text(metar.raw).font(Theme.mono(11, .regular)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showRaw.toggle() }
            } header: {
                Text("Weather")
            }
        }
    }

    static func color(_ category: FlightCategory) -> Color {
        switch category {
        case .vfr: return .green
        case .mvfr: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .ifr: return .red
        case .lifr: return Color(red: 0.85, green: 0.35, blue: 0.95)
        }
    }
}

/// The airport's ATIS: information letter, runways in use, and the full broadcast on tap.
struct ATISSection: View {
    let broadcasts: [ATIS]
    let runways: ATIS.Runways
    @State private var expanded = false

    var body: some View {
        if !broadcasts.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach(Array(broadcasts.enumerated()), id: \.offset) { _, atis in
                            Text(label(atis))
                                .font(Theme.mono(11, .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.cyan.opacity(0.2), in: Capsule())
                                .foregroundStyle(Theme.cyan)
                        }
                        Spacer()
                        if let updated = broadcasts.compactMap(\.updated).max() {
                            Text(Format.ago(updated)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    if !runways.landing.isEmpty {
                        Text("Landing \(runways.landing.joined(separator: ", "))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    if !runways.departing.isEmpty {
                        Text("Departing \(runways.departing.joined(separator: ", "))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    if expanded {
                        ForEach(Array(broadcasts.enumerated()), id: \.offset) { _, atis in
                            Text(atis.text).font(Theme.mono(11, .regular)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                    } else {
                        Text("Tap for the full broadcast").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            } header: {
                Text("ATIS")
            }
        }
    }

    private func label(_ atis: ATIS) -> String {
        let code = atis.code.isEmpty ? "" : " \(atis.code)"
        switch atis.kind {
        case .combined: return "INFO\(code)"
        case .arrival: return "ARR\(code)"
        case .departure: return "DEP\(code)"
        }
    }
}

/// One plane on approach: callsign, type, where it's coming from, runway, ETA and altitude.
struct ApproachRow: View {
    let plane: Plane
    let airport: Airport
    @State private var route: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(plane.title).font(Theme.mono(13)).foregroundStyle(Theme.text)
                    if let type = plane.type {
                        Text(type).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                if let route {
                    Text(route).font(Theme.mono(10)).foregroundStyle(Theme.amber.opacity(0.8))
                }
            }
            Spacer()
            if let runway = EventDetector.landingRunway(plane, at: airport) {
                Text(runway).font(Theme.mono(11, .bold)).foregroundStyle(Theme.cyan)
            }
            if let minutes = EventDetector.minutesToLanding(plane, at: airport) {
                Text("~\(minutes) min").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Text(Format.altitude(plane)).font(Theme.mono(12)).foregroundStyle(Theme.amber)
        }
        .task(id: plane.id) {
            if let callsign = plane.callsign {
                route = await RouteLookup.shared.route(callsign: callsign, lat: plane.lat, lon: plane.lon)
            }
        }
    }
}
