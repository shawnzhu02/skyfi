import SwiftUI

/// The last few tower transmissions, above the mixer bar. Tap a line to fly to that plane.
struct TranscriptStrip: View {
    @Environment(TalkStore.self) private var talk
    @Environment(Mixer.self) private var mixer
    var onPick: (String) -> Void
    var onOpen: () -> Void

    var body: some View {
        // Skyfi's own player is heard directly; LiveATC's page only with subtitles on (in-app recording).
        if mixer.feed != nil, talk.enabled, mixer.towerInBrowser, !talk.subtitles {
            Button { talk.subtitles = true } label: {
                row(icon: "captions.bubble", text: "Turn on live subtitles (iOS asks to record Skyfi's sound)")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
            }
            .buttonStyle(.plain)
        } else if mixer.feed != nil, talk.enabled, !mixer.towerInBrowser || talk.subtitles {
            VStack(alignment: .leading, spacing: 6) {
                switch talk.model.state {
                case .ready:
                    if let problem = talk.captureProblem, mixer.towerInBrowser {
                        row(icon: "exclamationmark.triangle", text: problem)
                    } else if talk.lines.isEmpty {
                        row(icon: talk.transmitting ? "waveform" : "ear", text: talk.transmitting ? "Listening…" : "Waiting for the tower to talk…")
                    }
                    // Subtitles: newest at the bottom, the callsign in orange.
                    ForEach(Array(talk.lines.prefix(2).reversed())) { line in
                        Button {
                            if let id = line.planeID { onPick(id) } else { onOpen() }
                        } label: { SubtitleLine(line: line) }
                        .buttonStyle(.plain)
                    }
                case .downloading(let fraction):
                    row(icon: "arrow.down.circle", text: "Downloading ATC speech model… \(Int(fraction * 100))%")
                case .preparing, .downloaded:
                    row(icon: "cpu", text: "Loading ATC speech model… (first time takes a minute)")
                case .notDownloaded, .failed:
                    Button(action: onOpen) {
                        row(icon: "text.bubble", text: "See who's talking: get the ATC speech model")
                    }
                    .buttonStyle(.plain)
                case .unsupported:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .onTapGesture(perform: onOpen)
        }
    }

    private func row(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.cyan).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

/// One transmission as a subtitle: white words, the callsign Skyfi matched in orange.
struct SubtitleLine: View {
    let line: TalkStore.Line

    var body: some View {
        Text(Self.attributed(line))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The words before, of and after the callsign; nil when no callsign was matched.
    static func parts(_ line: TalkStore.Line) -> (before: String, callsign: String, after: String)? {
        let tokens = line.tokens
        guard let range = line.callsignRange, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= tokens.count else { return nil }
        return (tokens[..<range.lowerBound].joined(separator: " "),
                tokens[range].joined(separator: " "),
                tokens[range.upperBound...].joined(separator: " "))
    }

    static func attributed(_ line: TalkStore.Line) -> AttributedString {
        guard let parts = parts(line) else { return AttributedString(line.text) }
        var callsign = AttributedString(parts.callsign)
        callsign.foregroundColor = Theme.highlight
        callsign.font = .system(size: 15, weight: .bold)
        var result = AttributedString(parts.before.isEmpty ? "" : parts.before + " ")
        result += callsign
        if !parts.after.isEmpty { result += AttributedString(" " + parts.after) }
        return result
    }
}

struct TranscriptRow: View {
    let line: TalkStore.Line
    var compact = false
    var debug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                chip
                Text(line.text)
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(line.planeID == nil ? Theme.muted : Theme.text)
                    .lineLimit(compact ? 1 : nil)
            }
            if debug {
                Text(String(format: "match %.2f · next %@ · %d planes · %.1fs audio · %.2fs to transcribe",
                            line.score, line.runnerUp.map { String(format: "%.2f", $0) } ?? "—",
                            line.candidateCount, line.duration, line.seconds))
                    .font(Theme.mono(9, .regular))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private var chip: some View {
        let color: Color = line.speaker == .pilot ? Theme.amber : Theme.cyan
        let label = line.label ?? "?"
        let text: String = {
            switch line.speaker {
            case .controller: return "\(line.facility) ▸ \(label)"
            case .pilot: return "\(label) ▸"
            case .unknown: return label
            }
        }()
        Text(text)
            .font(Theme.mono(compact ? 10 : 11, .bold))
            .foregroundStyle(line.planeID == nil ? Theme.muted : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((line.planeID == nil ? Color.white : color).opacity(0.12), in: Capsule())
    }
}

/// Full transcript, the model download, settings and match debug info.
struct TranscriptSheet: View {
    @Environment(TalkStore.self) private var talk
    @Environment(Mixer.self) private var mixer
    var onPick: (String) -> Void
    @State private var showDebug = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var talk = talk
        NavigationStack {
            List {
                Section {
                    modelRow
                    Toggle("Live transcript", isOn: $talk.enabled)
                    Toggle("Lower music when the tower talks", isOn: $talk.duck)
                    Toggle("Callsign hints (experimental)", isOn: $talk.useHints)
                    Toggle("Show match details", isOn: $showDebug)
                    if showDebug {
                        Button("Test highlight") {
                            testResult = talk.testHighlight()
                                ? "Sent: the nearest plane should glow now."
                                : "No plane to call. Connect to an airport with traffic first."
                        }
                        if let testResult {
                            Text(testResult).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                } footer: {
                    Text("Transcripts run on your phone and only while Skyfi is open. They're for listening along, not for operational use.")
                }

                Section("Transcript") {
                    if talk.lines.isEmpty {
                        Text("Nothing yet.").foregroundStyle(Theme.muted)
                    }
                    ForEach(talk.lines) { line in
                        Button {
                            if let id = line.planeID { onPick(id) }
                        } label: {
                            TranscriptRow(line: line, debug: showDebug)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Speech model: WhisperATC small.en fine-tuned on ATCO2 (TU Delft), Core ML conversion by stebox/whisperkit-atc-coreml (MIT), run with WhisperKit. Airline callsigns: OpenFlights (ODbL).")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Who's talking")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var modelRow: some View {
        let size = ByteCountFormatter.string(fromByteCount: ATCModel.totalBytes, countStyle: .file)
        switch talk.model.state {
        case .notDownloaded:
            Button {
                // Download now; load into memory only if a tower is tuned.
                talk.model.start(load: mixer.feed != nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download ATC speech model (\(size))")
                    Text("Whisper trained on real tower radio. Use Wi-Fi and keep Skyfi open until it finishes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading… \(Int(fraction * 100))%")
                ProgressView(value: fraction)
                Button("Pause") { talk.model.cancel() }.font(.system(size: 13))
                Text("Keep Skyfi open until it finishes. Pausing keeps what's downloaded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        case .preparing:
            HStack {
                ProgressView()
                Text("Loading the model. The first time takes a minute.").font(.system(size: 13))
            }
        case .downloaded:
            HStack {
                Label("ATC speech model downloaded", systemImage: "checkmark.circle").foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { talk.model.delete() }.font(.system(size: 13))
            }
            Text("It loads when you tune a tower.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        case .ready:
            HStack {
                Label("ATC speech model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { talk.model.delete() }.font(.system(size: 13))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Model problem: \(message)").font(.system(size: 13)).foregroundStyle(.red)
                Button("Try again") { talk.model.start(load: mixer.feed != nil) }
            }
        case .unsupported:
            Text("This iPhone doesn't have enough memory for the ATC speech model (needs 4 GB, iPhone 12 or newer).")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }
}
