import SwiftUI

/// Mixer sheet > About: settings that don't fit elsewhere, data credits, and resets.
struct AboutView: View {
    @Environment(Mixer.self) private var mixer
    @State private var places = Places.shared
    @AppStorage("seenFirstRunTip") private var seenTip = false
    @State private var confirmClear = false
    @AppStorage("altitudeColors") private var altitudeColors = false

    var body: some View {
        @Bindable var mixer = mixer
        List {
            Section {
                Toggle("Play tower in LiveATC's player", isOn: $mixer.towerInBrowser)
                    .tint(Theme.cyan)
            } header: {
                Text("Tower audio")
            } footer: {
                Text("LiveATC only allows listening through its own site, so Skyfi opens their player page. Off tries Skyfi's own player (tower volume, mix and who's talking), which LiveATC currently refuses.")
            }

            Section {
                Toggle("Color planes by altitude", isOn: $altitudeColors)
                    .tint(Theme.cyan)
            } header: {
                Text("Map")
            } footer: {
                Text("Orange near the ground, then yellow, green, blue and violet up high. Planes on approach, on the ground or squawking an emergency keep their own colors.")
            }

            Section("Credits") {
                credit("Tower audio", "LiveATC.net, through its own player", "https://www.liveatc.net")
                credit("Planes", "adsb.lol (ODbL), adsb.fi as a fallback", "https://adsb.lol")
                credit("Weather", "aviationweather.gov (NOAA)", "https://aviationweather.gov")
                credit("Airports, runways and frequencies", "OurAirports (public domain)", "https://ourairports.com")
                credit("Who's talking model", "Whisper small.en fine-tuned on ATCO2", "https://huggingface.co/stebox/whisperkit-atc-coreml")
            }

            Section {
                Button("Show the welcome tip again") { seenTip = false }
                Button("Clear favorites and recents", role: .destructive) { confirmClear = true }
                    .disabled(places.favorites.isEmpty && places.recents.isEmpty)
            } footer: {
                Text(DebugLog.header())
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .navigationTitle("About Skyfi")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear your starred and recent airports?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { places.clearAll() }
        }
    }

    private func credit(_ title: String, _ detail: String, _ link: String) -> some View {
        Link(destination: URL(string: link)!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
}
