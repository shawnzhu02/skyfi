import SwiftUI

struct AirportSheet: View {
    let airport: Airport
    var onConnect: () -> Void
    var onPickPlane: (Plane) -> Void

    @Environment(TrafficStore.self) private var traffic
    @Environment(Mixer.self) private var mixer

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
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    if feeds.isEmpty {
                        Text("No live feed for this airport in Skyfi yet.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    } else {
                        connectButton
                    }
                } footer: {
                    if !feeds.isEmpty {
                        Text("Plays \(feeds.map(\.kind.label).joined(separator: ", then ")) if one is offline, and shows the planes within \(TrafficStore.rangeNM) nm they could be talking to.")
                    }
                }

                if isConnected {
                    if !approaching.isEmpty {
                        Section("On approach") {
                            ForEach(approaching) { plane in
                                Button { onPickPlane(plane) } label: {
                                    HStack {
                                        Text(plane.title).font(Theme.mono(13)).foregroundStyle(Theme.text)
                                        if let type = plane.type {
                                            Text(type).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                        Text(Format.altitude(plane)).font(Theme.mono(12)).foregroundStyle(Theme.amber)
                                    }
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
        default: return "Connected · \(mixer.feed?.name ?? "")"
        }
    }

    private func isFailed(_ status: Mixer.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
