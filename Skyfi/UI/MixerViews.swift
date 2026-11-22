import CoreLocation
import SwiftUI
import UIKit

/// The always-visible strip at the bottom: what's playing, play/pause, tap for the mixer.
struct MixerBar: View {
    @Environment(Mixer.self) private var mixer
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(mixer.isPlaying ? Theme.amber : Theme.muted)
                        .symbolEffect(.variableColor.iterative, isActive: mixer.isPlaying)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mixer.music?.title ?? "Pick music")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(mixer.feed.map { "+ \($0.name)" } ?? "Tap an airport to connect")
                            .font(.system(size: 11))
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

    var body: some View {
        @Bindable var mixer = mixer
        NavigationStack {
            List {
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

                if mixer.music != nil && mixer.feed != nil {
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
            .navigationTitle("Mixer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Split out of `body`: one big expression is too slow for the type checker.
    @ViewBuilder private var airportSection: some View {
        @Bindable var mixer = mixer
        Section {
            if let feed = mixer.feed {
                nowPlaying(title: feed.name, subtitle: "LiveATC · \(feed.airport)", status: mixer.atcStatus,
                           tint: Theme.cyan, onStop: mixer.disconnect)
                slider("ATC volume", value: $mixer.atcVolume, tint: Theme.cyan)
            }
            ForEach(Catalog.airports(near: center).prefix(12)) { item in
                airportRow(item)
            }
        } header: {
            Text("Airport")
        } footer: {
            HStack(spacing: 16) {
                NavigationLink("Check feeds") { FeedCheckView() }
                NavigationLink("Debug log") { DebugLogView() }
            }
            .font(.system(size: 12))
        }
    }

    private func airportRow(_ item: Catalog.NearbyAirport) -> some View {
        Button { mixer.connect(item.airport) } label: {
            HStack {
                Image(systemName: mixer.airport == item.airport.icao ? "headphones.circle.fill" : "headphones")
                    .foregroundStyle(Theme.cyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.airport.code).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                    Text(item.airport.name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Text("\(Int(item.distanceNM)) nm").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func playLink() {
        let input = link
        guard !input.isEmpty else { return }
        linkFocused = false
        Task {
            await mixer.playYouTube(input)
            if mixer.musicStatus != .failed("That doesn't look like a YouTube link.") { link = "" }
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
