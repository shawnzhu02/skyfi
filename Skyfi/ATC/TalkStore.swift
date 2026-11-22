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
            if enabled, ATCModel.isDownloaded, feedAirport != nil { model.start() }
            if !enabled { model.unload() }
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
    @ObservationIgnored private var feedKind: ATCFeed.Kind = .tower

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
        Mixer.shared.onPause = { [weak self] in
            self?.stopTransmitting()
        }
    }

    /// A transmission can't finish once its audio stops, so close it by hand.
    private func stopTransmitting() {
        let squelch = self.squelch
        tap.queue.async { squelch.reset() }
        if transmitting { transmitting = false }
        Mixer.shared.setDucked(false)
    }

    func connect(traffic: TrafficStore) {
        self.traffic = traffic
    }

    /// Called by Mixer on every tower item change (connect, fallback to approach, reconnect, disconnect).
    func feedChanged(item: AVPlayerItem?, feed: ATCFeed?) {
        stopTransmitting()
        tap.attach(to: item)
        let airport = feed.flatMap { AirportIndex.shared.airport(icao: $0.airport) }
        if airport?.icao != feedAirport?.icao {
            lines = []
            talking = [:]
        }
        feedAirport = airport
        feedKind = feed?.kind ?? .tower
        // TrafficStore already polls this airport: it follows Mixer.airport through RootView.
        // The 1.5 GB model only sits in memory while a tower is tuned.
        if feed == nil {
            model.unload()
        } else if enabled, ATCModel.isDownloaded {
            model.start()
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
        // The feed may have changed while the model was busy.
        guard feedAirport != nil else { return }
        ingest(text: heard.text, start: transmission.start, duration: transmission.duration,
               seconds: seconds, candidates: candidates)
    }

    /// Everything after speech-to-text: normalize, match the callsign against the planes on
    /// frequency, add the transcript line and make the matched plane glow. Tests and the
    /// "Test highlight" button call this directly.
    @discardableResult
    func ingest(text: String, start: Date = Date(), duration: Double = 0, seconds: Double = 0,
                candidates: [Candidate]? = nil) -> Line {
        let candidates = candidates ?? currentCandidates()
        let result = matcher.match(tokens: Phraseology.tokens(text), candidates: candidates)
        let plane = result.accepted.flatMap { traffic?.planes[$0.candidateID] }
        let line = Line(text: text, planeID: result.accepted?.candidateID, label: plane?.title,
                        speaker: result.accepted?.speaker ?? .unknown, score: result.best?.score ?? 0,
                        runnerUp: result.runnerUp?.score, candidateCount: candidates.count,
                        time: start, duration: duration, seconds: seconds)
        lines.insert(line, at: 0)
        if lines.count > 100 { lines.removeLast(lines.count - 100) }
        if let accepted = result.accepted {
            talking = talking.filter { $0.value.isFresh }
            talking[accepted.candidateID] = Talk(time: Date(), speaker: accepted.speaker, text: text)
        }
        return line
    }

    /// Debug: pretends the tower just called the nearest plane on frequency, so the glow,
    /// bubble, edge arrow and transcript can be checked without the speech model.
    /// Returns false when there's no plane to call.
    @discardableResult
    func testHighlight() -> Bool {
        let candidates = currentCandidates()
        guard let pick = candidates.first(where: { !matcher.forms(for: $0).isEmpty }) else { return false }
        let callsign = matcher.hint(for: [pick])
        let instruction = pick.onGround ? "taxi to runway two two right via alpha" : "cleared to land runway four right"
        return ingest(text: "\(callsign), \(instruction)", candidates: candidates).planeID != nil
    }

    /// Planes that could be on the tuned frequency. A tower feed only talks to planes on the
    /// field or close in and low; approach and departure talk to airborne planes further out.
    /// A smaller list means fewer look-alike callsigns to confuse.
    func currentCandidates() -> [Candidate] {
        guard let airport = feedAirport, let traffic else { return [] }
        let kind = feedKind
        return traffic.planes.values
            .map { ($0, Geo.distanceNM($0.lat, $0.lon, airport.lat, airport.lon)) }
            .filter { Self.onFrequency($0.0, distanceNM: $0.1, airport: airport, kind: kind) }
            .sorted { $0.1 < $1.1 }
            .map { plane, _ in
                Candidate(id: plane.id, callsign: plane.callsign, registration: plane.registration, type: plane.type,
                          onGround: plane.onGround, approaching: EventDetector.isApproaching(plane, to: airport),
                          track: plane.track)
            }
    }

    nonisolated static func onFrequency(_ plane: Plane, distanceNM: Double, airport: Airport, kind: ATCFeed.Kind) -> Bool {
        let agl = plane.altitude.map { $0 - airport.elev }
        switch kind {
        case .tower:
            if plane.onGround { return distanceNM <= 3 }
            guard distanceNM <= 15 else { return false }
            return (agl ?? 0) <= 5000
        case .approach, .departure:
            if plane.onGround { return false }
            guard distanceNM <= candidateRadiusNM else { return false }
            return (agl ?? 0) <= 18000
        }
    }

    /// The freshest talking plane, for the off-screen arrow.
    var latestTalker: (id: String, talk: Talk)? {
        talking.filter { $0.value.isFresh }.max { $0.value.time < $1.value.time }.map { ($0.key, $0.value) }
    }
}
