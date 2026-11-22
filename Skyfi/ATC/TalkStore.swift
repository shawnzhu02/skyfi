import AVFoundation
import Foundation
import Observation

/// "Who's talking": takes the tuned tower's audio, cuts it into transmissions, transcribes
/// each one with the on-device ATC model, matches the callsign to a nearby plane and keeps
/// the transcript plus which plane should glow on the map.
@Observable
@MainActor
final class TalkStore {
    static let shared = TalkStore()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let planeID: String?
        let label: String?
        let speaker: CallsignMatcher.Speaker
        let score: Double
        let runnerUp: Double?
        let candidateCount: Int
        let time: Date
        let duration: Double
        let seconds: Double
    }

    struct Talk: Equatable {
        let time: Date
        let speaker: CallsignMatcher.Speaker
        let text: String

        var isFresh: Bool { Date().timeIntervalSince(time) < TalkStore.glowSeconds }
    }

    nonisolated static let glowSeconds = 6.0
    nonisolated static let candidateRadiusNM = 60.0

    private(set) var lines: [Line] = []
    private(set) var talking: [String: Talk] = [:]
    private(set) var transmitting = false
    let model = ATCModel()

    var enabled: Bool = UserDefaults.standard.object(forKey: "talk.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "talk.enabled")
            if enabled, ATCModel.isDownloaded { model.start() }
        }
    }
    var duck: Bool = UserDefaults.standard.object(forKey: "talk.duck") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(duck, forKey: "talk.duck")
            if !duck { Mixer.shared.setDucked(false) }
        }
    }
    /// Feed nearby callsigns to the model as a prompt. Off by default until measured on device:
    /// the model was trained without prompts.
    var useHints: Bool = UserDefaults.standard.bool(forKey: "talk.hints") {
        didSet { UserDefaults.standard.set(useHints, forKey: "talk.hints") }
    }
    var foreground = true

    @ObservationIgnored private let tap = ATCTap()
    @ObservationIgnored private let squelch = Squelch()
    @ObservationIgnored private let matcher = CallsignMatcher()
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private var backlog: [Transmission] = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private var feedAirport: Airport?

    private init() {
        let squelch = self.squelch
        tap.onAudio = { samples in
            // Tap queue: squelch only ever runs here.
            let events = squelch.process(samples)
            guard !events.isEmpty else { return }
            Task { @MainActor in TalkStore.shared.handle(events) }
        }
        Mixer.shared.onATCItemChange = { [weak self] item, feed in
            self?.feedChanged(item: item, feed: feed)
        }
        if enabled, ATCModel.isDownloaded { model.start() }
    }

    func connect(traffic: TrafficStore) {
        self.traffic = traffic
    }

    private func feedChanged(item: AVPlayerItem?, feed: ATCFeed?) {
        let squelch = self.squelch
        tap.queue.async { squelch.reset() }
        tap.attach(to: item)
        let airport = feed.flatMap { AirportIndex.shared.airport(icao: $0.airport) }
        if airport?.icao != feedAirport?.icao {
            lines = []
            talking = [:]
        }
        feedAirport = airport
        traffic?.setPinned(airport)
        if item == nil, transmitting {
            transmitting = false
            Mixer.shared.setDucked(false)
        }
    }

    private func handle(_ events: [Squelch.Event]) {
        for event in events {
            switch event {
            case .opened:
                transmitting = true
                if duck { Mixer.shared.setDucked(true) }
            case .closed(let transmission):
                transmitting = false
                Mixer.shared.setDucked(false)
                if let transmission { enqueue(transmission) }
            }
        }
    }

    private func enqueue(_ transmission: Transmission) {
        // Transcription runs only on screen: in the background the audio plays on, battery is spared.
        guard enabled, foreground, model.isReady, feedAirport != nil else { return }
        backlog.append(transmission)
        if backlog.count > 3 { backlog.removeFirst(backlog.count - 3) }
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = backlog.first {
            backlog.removeFirst()
            await transcribe(next)
        }
        working = false
    }

    private func transcribe(_ transmission: Transmission) async {
        let candidates = currentCandidates()
        let prompt = useHints ? matcher.hint(for: candidates) : nil
        let started = Date()
        guard let heard = await model.transcribe(transmission.samples, prompt: prompt) else { return }
        let seconds = Date().timeIntervalSince(started)
        let tokens = Phraseology.tokens(heard.text)
        let result = matcher.match(tokens: tokens, candidates: candidates)
        let plane = result.accepted.flatMap { traffic?.planes[$0.candidateID] }
        let line = Line(text: heard.text, planeID: result.accepted?.candidateID, label: plane?.title,
                        speaker: result.accepted?.speaker ?? .unknown, score: result.best?.score ?? 0,
                        runnerUp: result.runnerUp?.score, candidateCount: candidates.count,
                        time: transmission.start, duration: transmission.duration, seconds: seconds)
        lines.insert(line, at: 0)
        if lines.count > 100 { lines.removeLast(lines.count - 100) }
        if let accepted = result.accepted {
            talking = talking.filter { $0.value.isFresh }
            talking[accepted.candidateID] = Talk(time: Date(), speaker: accepted.speaker, text: heard.text)
        }
    }

    /// Planes on this frequency: within 60 nm of the tuned airport, or on the ground there.
    func currentCandidates() -> [Candidate] {
        guard let airport = feedAirport, let traffic else { return [] }
        return traffic.planes.values
            .map { ($0, Geo.distanceNM($0.lat, $0.lon, airport.lat, airport.lon)) }
            .filter { $0.1 <= Self.candidateRadiusNM }
            .sorted { $0.1 < $1.1 }
            .map { plane, _ in
                Candidate(id: plane.id, callsign: plane.callsign, registration: plane.registration, type: plane.type,
                          onGround: plane.onGround, approaching: EventDetector.isApproaching(plane, to: airport),
                          track: plane.track)
            }
    }

    /// The freshest talking plane, for the off-screen arrow.
    var latestTalker: (id: String, talk: Talk)? {
        talking.filter { $0.value.isFresh }.max { $0.value.time < $1.value.time }.map { ($0.key, $0.value) }
    }
}
