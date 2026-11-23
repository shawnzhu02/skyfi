import SwiftUI

/// Mixer sheet > About: settings that don't fit elsewhere, data credits, and resets.
struct AboutView: View {
    @Environment(Mixer.self) private var mixer
    @State private var places = Places.shared
    @AppStorage("seenFirstRunTip") private var seenTip = false
    @State private var confirmClear = false
    @AppStorage("altitudeColors") private var altitudeColors = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("dataBlocks") private var dataBlocks = false
    @AppStorage("hideGround") private var hideGround = false
    @AppStorage("autoZoomTalking") private var autoZoomTalking = true
    @State private var talk = TalkStore.shared

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
                Toggle("Live subtitles", isOn: $talk.subtitles)
                    .tint(Theme.cyan)
                Toggle("Zoom to the plane being talked to", isOn: $autoZoomTalking)
                    .tint(Theme.cyan)
                Toggle("Mute music while subtitles are on", isOn: $talk.muteMusicForSubtitles)
                    .tint(Theme.cyan)
            } header: {
                Text("Subtitles")
            } footer: {
                Text("LiveATC's page doesn't share its sound with apps, so subtitles record what Skyfi is playing (iOS asks first) and transcribe it on the phone. Nothing is saved. Music is in that recording too: turn it down for better subtitles. Only while Skyfi is on screen.")
            }

            Section {
                Toggle("Color planes by altitude", isOn: $altitudeColors)
                    .tint(Theme.cyan)
                Toggle("Radar data blocks", isOn: $dataBlocks)
                    .tint(Theme.cyan)
                Toggle("Hide planes on the ground", isOn: $hideGround)
                    .tint(Theme.cyan)
                Toggle("Keep the screen on while connected", isOn: $keepAwake)
                    .tint(Theme.cyan)
            } header: {
                Text("Map")
            } footer: {
                Text("Data blocks show altitude in hundreds of feet and speed in tens of knots under each callsign (\"120 25\" = 12,000 ft, 250 kt), like a controller's scope. Altitude colors: orange near the ground, then yellow, green, blue and violet up high. Planes on approach, on the ground or squawking an emergency keep their own colors. Keeping the screen on uses more battery; plug in for long sessions.")
            }

            Section {
                siriRow("Connect to BOS in Skyfi")
                siriRow("Weather at BOS in Skyfi")
                siriRow("Pause Skyfi")
            } header: {
                Text("Siri and Shortcuts")
            } footer: {
                Text("Also in the Shortcuts app. Links like skyfi://connect/BOS open an airport too (share one from any airport card).")
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

    private func siriRow(_ phrase: String) -> some View {
        Label("“" + phrase + "”", systemImage: "mic.fill")
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
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
