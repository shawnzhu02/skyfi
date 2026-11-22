import SwiftUI

struct AirportSheet: View {
    let airport: Airport
    var onPickPlane: (Plane) -> Void

    @Environment(TrafficStore.self) private var traffic
    @Environment(Mixer.self) private var mixer

    var body: some View {
        let feed = Catalog.feed(at: airport.icao)
        let approaching = traffic.approaching(airport)
        let events = traffic.events(at: airport)
        let ground = traffic.onGround(at: airport).count

        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(airport.name).font(Theme.rounded(18, .bold))
                        Text([airport.icao, airport.iata, airport.city].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        Text("\(ground) on the ground · \(approaching.count) on approach")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Tower audio") {
                    if let feed {
                        let tuned = mixer.feed == feed
                        Button {
                            // An offline feed retries; a playing one stops.
                            if tuned, !isFailed(mixer.atcStatus) { mixer.stopATC() } else { mixer.tune(feed) }
                        } label: {
                            HStack {
                                Image(systemName: tuned ? "headphones.circle.fill" : "headphones")
                                    .foregroundStyle(Theme.cyan)
                                Text(feed.name)
                                Spacer()
                                Text(tuned ? statusText(mixer.atcStatus) : "Tune")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(tuned ? Theme.cyan : Theme.muted)
                            }
                        }
                    } else {
                        Text("No LiveATC feed for this airport in Skyfi yet.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }

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
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(airport.code)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func isFailed(_ status: Mixer.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func statusText(_ status: Mixer.Status) -> String {
        switch status {
        case .loading: return "Connecting…"
        case .playing: return "Live"
        case .paused: return "Paused"
        case .failed: return "Offline · tap to retry"
        case .idle: return "Tune"
        }
    }
}
