import AVKit
import CoreLocation
import SwiftUI
import UIKit

/// The always-visible strip at the bottom: what's playing, play/pause, tap for the mixer.
struct MixerBar: View {
    @Environment(Mixer.self) private var mixer
    var onOpen: () -> Void

    var body: some View {
        @Bindable var mixer = mixer
        VStack(spacing: 8) {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(mixer.isPlaying ? Theme.amber : Theme.muted)
                        .symbolEffect(.variableColor.iterative, isActive: mixer.isPlaying)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mixer.music.map { "Music: \($0.title)" } ?? "Add music")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(mixer.feed.map { "Tower: \($0.name)" } ?? "Tower: none yet")
                            .font(.system(size: 12))
                            .foregroundStyle(mixer.feed == nil ? Theme.muted : Theme.cyan)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if mixer.hasSomething {
                Button { mixer.togglePlayPause() } label: {
                    Image(systemName: mixer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                }
            }
        }
            // Music volume right on the player: turn it down to hear the tower over it.
            if mixer.music != nil {
                HStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.plane)
                        .frame(width: 26)
                    Slider(value: $mixer.musicVolume, in: 0...1)
                        .tint(Theme.plane)
                        .accessibilityLabel("Music volume")
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .panel()
    }
}

struct MixerSheet: View {
    let center: CLLocationCoordinate2D
    @Environment(Mixer.self) private var mixer
    @State private var link = ""
    @FocusState private var linkFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var places = Places.shared
    @State private var query = ""

    var body: some View {
        @Bindable var mixer = mixer
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("Airports") {
                        let results = Catalog.search(query)
                        if results.isEmpty {
                            Text("No airport with a live feed matches \"\(query)\".")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        ForEach(results.prefix(20)) { airport in
                            airportRow(airport, distanceNM: distance(to: airport))
                        }
                    }
                }

                if query.isEmpty, !(places.favorites.isEmpty && places.recents.isEmpty) {
                    Section("Your airports") {
                        ForEach(yourAirports) { airport in
                            airportRow(airport, distanceNM: distance(to: airport), starred: places.isFavorite(airport.icao))
                        }
                    }
                    .task(id: yourAirports.map(\.icao)) {
                        await WeatherStore.shared.refresh(many: yourAirports.map(\.icao))
                    }
                }

                Section("Music") {
                    HStack {
                        TextField("Paste a YouTube link", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($linkFocused)
                            .submitLabel(.go)
                            .onSubmit(playLink)
                        if link.isEmpty {
                            Button("Paste") {
                                link = UIPasteboard.general.string ?? ""
                                playLink()
                            }
                            .font(.system(size: 13, weight: .semibold))
                        } else {
                            Button("Play", action: playLink).font(.system(size: 13, weight: .semibold))
                        }
                    }
                    if case .failed(let message) = mixer.musicStatus {
                        Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    if let music = mixer.music {
                        nowPlaying(title: music.title, subtitle: music.subtitle, status: mixer.musicStatus,
                                   tint: Theme.amber, onStop: mixer.stopMusic)
                        slider("Music volume", value: $mixer.musicVolume, tint: Theme.amber)
                    }
                }

                Section("24/7 lofi") {
                    ForEach(Catalog.presets) { preset in
                        Button {
                            Task { await mixer.play(preset) }
                        } label: {
                            HStack {
                                Image(systemName: preset.kind == .youtube ? "play.rectangle.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(Theme.amber)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.title).foregroundStyle(Theme.text)
                                    Text(preset.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }

                airportSection

                if mixer.music != nil && mixer.feed != nil && !mixer.towerInBrowser {
                    Section("Mix") {
                        VStack(spacing: 6) {
                            Slider(value: $mixer.mix, in: 0...1)
                                .tint(Theme.cyan)
                            HStack {
                                Text("More music").font(.system(size: 11)).foregroundStyle(Theme.amber)
                                Spacer()
                                Text("More tower").font(.system(size: 11)).foregroundStyle(Theme.cyan)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search airports (BOS, Logan, Boston)")
            .navigationTitle("Mixer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sleepMenu }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Split out of `body`: one big expression is too slow for the type checker.
    @ViewBuilder private var airportSection: some View {
        @Bindable var mixer = mixer
        Section {
            if let feed = mixer.feed {
                if mixer.towerInBrowser {
                    nowPlaying(title: feed.name, subtitle: "LiveATC player · \(feed.airport)",
                               status: Self.status(of: LiveATCBrowser.shared.media),
                               tint: Theme.cyan, onStop: mixer.stopTower)
                    Button {
                        if let airport = AirportIndex.shared.airport(icao: mixer.airport ?? feed.airport) {
                            mixer.connect(airport)
                        }
                        dismiss()
                    } label: {
                        Label("Show LiveATC player", systemImage: "rectangle.on.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.cyan)
                    }
                } else {
                    nowPlaying(title: feed.name, subtitle: "LiveATC · \(feed.airport)", status: mixer.atcStatus,
                               tint: Theme.cyan, onStop: mixer.disconnect)
                    slider("ATC volume", value: $mixer.atcVolume, tint: Theme.cyan)
                }
            }
            // The LiveATC-player switch lives in About; nearby airports are on the map.
            if mixer.feed == nil {
                Text("Tap an airport on the map, or search above.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        } header: {
            Text("Tower")
        } footer: {
            HStack(spacing: 16) {
                // Checks Skyfi's own player, which only matters with the LiveATC player off.
                if !mixer.towerInBrowser {
                    NavigationLink("Check feeds") { FeedCheckView() }
                }
                NavigationLink("Debug log") { DebugLogView() }
                NavigationLink("What am I hearing?") { GlossaryView() }
                NavigationLink("About") { AboutView() }
            }
            .font(.system(size: 12))
        }
    }

    private var sleepMenu: some View {
        Menu {
            ForEach([15, 30, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutes") { mixer.setSleepTimer(minutes: minutes) }
            }
            if mixer.sleepAt != nil {
                Button("Turn off", role: .destructive) { mixer.setSleepTimer(minutes: nil) }
            }
        } label: {
            if let at = mixer.sleepAt {
                Label { Text(at, style: .timer) } icon: { Image(systemName: "moon.zzz.fill") }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            } else {
                Image(systemName: "moon.zzz").foregroundStyle(Theme.text)
            }
        }
        .accessibilityLabel("Sleep timer")
    }

    /// Starred airports first, then recent ones that aren't starred.
    private var yourAirports: [Airport] {
        let icaos = places.favorites + places.recents.filter { !places.isFavorite($0) }
        return icaos.compactMap { AirportIndex.shared.airport(icao: $0) }.filter { Catalog.connectable.contains($0.icao) }
    }

    private func distance(to airport: Airport) -> Double {
        Geo.distanceNM(center.latitude, center.longitude, airport.lat, airport.lon)
    }

    private func airportRow(_ airport: Airport, distanceNM: Double, starred: Bool = false) -> some View {
        Button {
            query = ""
            mixer.connect(airport)
            // The LiveATC player opens behind this sheet: get out of its way.
            if mixer.towerInBrowser { dismiss() }
        } label: {
            HStack {
                Image(systemName: mixer.airport == airport.icao ? "headphones.circle.fill" : "headphones")
                    .foregroundStyle(Theme.cyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(airport.code).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                        if starred {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.amber)
                        }
                    }
                    Text(airport.name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if let metar = WeatherStore.shared.metar(airport.icao) {
                    Text(metar.category.rawValue)
                        .font(Theme.mono(9, .bold))
                        .foregroundStyle(WeatherSection.color(metar.category))
                }
                Text("\(Int(distanceNM)) nm").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .swipeActions {
            Button {
                places.toggleFavorite(airport.icao)
            } label: {
                Label(places.isFavorite(airport.icao) ? "Unstar" : "Star", systemImage: places.isFavorite(airport.icao) ? "star.slash" : "star")
            }
            .tint(Theme.amber)
        }
    }

    static func status(of media: LiveATCBrowser.Media) -> Mixer.Status {
        switch media {
        case .playing: return .playing
        case .loading: return .loading
        case .failed(let message): return .failed(message)
        case .paused, .none: return .paused
        }
    }

    private func playLink() {
        let input = link
        guard !input.isEmpty else { return }
        linkFocused = false
        Task {
            await mixer.playYouTube(input)
            // Keep the link on any failure so you can fix or retry it.
            if case .failed = mixer.musicStatus { return }
            link = ""
        }
    }

    private func nowPlaying(title: String, subtitle: String, status: Mixer.Status, tint: Color, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Group {
                switch status {
                case .loading: ProgressView().controlSize(.small)
                case .playing: Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                case .failed: Image(systemName: "exclamationmark.triangle.fill")
                default: Image(systemName: "pause.fill")
                }
            }
            .foregroundStyle(tint)
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(action: onStop) {
                Image(systemName: "stop.fill").foregroundStyle(Theme.muted)
            }
            .buttonStyle(.borderless)
        }
    }

    private func slider(_ label: String, value: Binding<Float>, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 24)
            Slider(value: value, in: 0...1).tint(tint)
                .accessibilityLabel(label)
        }
    }
}

/// The system AirPlay / Bluetooth output picker: music and tower (LiveATC's page too) follow it.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = Theme.uiCyan
        picker.activeTintColor = Theme.uiCyan
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
