import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays music (YouTube or radio) and one ATC feed at the same time, with their own volumes.
/// Keeps playing in the background and on the lock screen (UIBackgroundModes: audio).
@Observable
@MainActor
final class Mixer {
    static let shared = Mixer()

    enum Status: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)

        var isActive: Bool { self == .playing || self == .loading }
    }

    struct Music: Equatable {
        let title: String
        let subtitle: String
        let youtubeID: String?
        let isLive: Bool
    }

    private(set) var music: Music?
    private(set) var musicStatus: Status = .idle
    /// The airport you're connected to (ICAO). Its planes show on the map.
    private(set) var airport: String?
    /// The airport's feed that's on right now (tower, or approach/departure as a fallback).
    private(set) var feed: ATCFeed?
    private(set) var atcStatus: Status = .idle

    var musicVolume: Float = 0.7 { didSet { applyVolumes() } }
    var atcVolume: Float = 1.0 { didSet { applyVolumes() } }
    /// 0 = all music, 0.5 = both at full, 1 = all ATC.
    var mix: Float = 0.5 { didSet { applyVolumes() } }

    /// Tower audio plays in LiveATC's own player page (LiveATC refuses app players with HTTP 403).
    /// Off = Skyfi's own player: volume, mix and who's talking, once a feed allows it.
    var towerInBrowser: Bool = UserDefaults.standard.object(forKey: "towerInBrowser") as? Bool ?? true {
        didSet {
            guard towerInBrowser != oldValue else { return }
            UserDefaults.standard.set(towerInBrowser, forKey: "towerInBrowser")
            dlog("atc", "tower in LiveATC player: \(towerInBrowser)")
            // Reconnect in the new mode, but only restart the tower if it was on.
            guard let icao = airport else { return }
            guard feed != nil else {
                // Tower already off: stay on the airport (planes keep showing), just switch players.
                LiveATCBrowser.shared.close()
                return
            }
            disconnect()
            if let airport = AirportIndex.shared.airport(icao: icao) { connect(airport) }
        }
    }

    var isPlaying: Bool {
        musicStatus.isActive || atcStatus.isActive || LiveATCBrowser.shared.media == .playing
    }
    var hasSomething: Bool { music != nil || feed != nil }

    /// When the sleep timer pauses everything (nil = off).
    private(set) var sleepAt: Date?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes, minutes > 0 else {
            if sleepAt != nil { dlog("app", "sleep timer off") }
            sleepAt = nil
            return
        }
        let at = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = at
        dlog("app", "sleep timer \(minutes) min")
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow))
            guard let self, !Task.isCancelled else { return }
            dlog("app", "sleep timer fired")
            self.sleepAt = nil
            self.sleepTask = nil
            self.pause()
        }
    }

    @ObservationIgnored private let musicPlayer = AVPlayer()
    @ObservationIgnored private let atcPlayer = AVPlayer()
    @ObservationIgnored private var musicURL: URL?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var musicRequest = 0
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var retryTask: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchdogs: [String: Task<Void, Never>] = [:]
    /// Told about every new tower item, so the transcript tap can attach to it.
    @ObservationIgnored var onATCItemChange: ((AVPlayerItem?, ATCFeed?) -> Void)?
    /// Told when playback pauses, so a half-heard transmission doesn't keep the music ducked.
    @ObservationIgnored var onPause: (() -> Void)?
    @ObservationIgnored private var duckGain: Float = 1
    @ObservationIgnored private var duckTask: Task<Void, Never>?
    @ObservationIgnored private var retryCount: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var chain: FeedChain?
    /// Set by pause(): nothing may start playing again on its own until resume().
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var backgroundTasks: [ObjectIdentifier: UIBackgroundTaskIdentifier] = [:]
    /// Why the tower feed won't play, from the last probe or player error (shown in the status).
    @ObservationIgnored private var atcProblem: String?

    private init() {
        musicPlayer.automaticallyWaitsToMinimizeStalling = true
        atcPlayer.automaticallyWaitsToMinimizeStalling = true
        configureSession()
        configureRemoteCommands()
        observePlayers()
        applyVolumes()
    }

    // MARK: Music

    func playYouTube(_ input: String) async {
        guard let id = YouTubeLink.videoID(from: input) else {
            musicStatus = .failed("That doesn't look like a YouTube link.")
            return
        }
        UserDefaults.standard.set("youtube:\(id)", forKey: "lastMusic")
        await playYouTube(id: id, title: nil, subtitle: "YouTube")
    }

    /// What you last played ("preset:lofi-girl" or "youtube:<id>"), for the resume chip.
    var lastMusicTitle: String? {
        guard let last = UserDefaults.standard.string(forKey: "lastMusic") else { return nil }
        if last.hasPrefix("preset:") {
            return Catalog.presets.first { $0.id == String(last.dropFirst(7)) }?.title
        }
        return last.hasPrefix("youtube:") ? "your YouTube link" : nil
    }

    func playLastMusic() async {
        guard let last = UserDefaults.standard.string(forKey: "lastMusic") else { return }
        if last.hasPrefix("preset:"), let preset = Catalog.presets.first(where: { $0.id == String(last.dropFirst(7)) }) {
            await play(preset)
        } else if last.hasPrefix("youtube:") {
            await playYouTube(String(last.dropFirst(8)))
        }
    }

    func play(_ preset: Preset) async {
        UserDefaults.standard.set("preset:\(preset.id)", forKey: "lastMusic")
        switch preset.kind {
        case .youtube:
            await playYouTube(id: preset.value, title: preset.title, subtitle: preset.subtitle)
        case .radio:
            dlog("music", "radio preset \(preset.id): \(preset.value)")
            guard let url = URL(string: preset.value) else { return }
            musicRequest += 1
            music = Music(title: preset.title, subtitle: preset.subtitle, youtubeID: nil, isLive: true)
            artwork = nil
            startMusic(url)
        }
    }

    private func playYouTube(id: String, title: String?, subtitle: String) async {
        musicRequest += 1
        let request = musicRequest
        music = Music(title: title ?? "Loading…", subtitle: subtitle, youtubeID: id, isLive: false)
        musicStatus = .loading
        musicPlayer.pause()
        loadArtwork(youtubeID: id, request: request)
        dlog("music", "YouTube resolve \(id)")
        do {
            let resolved = try await YouTubeSource.resolve(videoID: id)
            dlog("music", "YouTube \(id) resolved: live=\(resolved.isLive) host=\(resolved.url.host ?? "?") title=\(resolved.title ?? "?")")
            guard request == musicRequest else { return }
            music = Music(title: title ?? resolved.title ?? "YouTube", subtitle: subtitle, youtubeID: id, isLive: resolved.isLive)
            startMusic(resolved.url)
        } catch {
            dlog("music", "YouTube \(id) resolve failed: \(String(describing: error))")
            guard request == musicRequest else { return }
            musicStatus = .failed("YouTube wouldn't give audio for this one. Try another link.")
            updateNowPlaying()
        }
    }

    private func startMusic(_ url: URL) {
        dlog("music", "start \(url.host ?? "?")\(url.path.prefix(60))")
        activateSession()
        musicURL = url
        musicPlayer.replaceCurrentItem(with: makeMusicItem(url))
        musicStatus = .loading
        musicPlayer.play()
        watchdog(isMusic: true)
        updateNowPlaying()
    }

    /// YouTube live HLS always carries video; cap it at the smallest variant so hours of
    /// lofi don't stream 1-3 Mbps of picture nobody sees.
    private func makeMusicItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        if music?.youtubeID != nil, music?.isLive == true {
            item.preferredPeakBitRate = 350_000
            item.preferredMaximumResolution = CGSize(width: 256, height: 144)
        }
        return item
    }

    /// Reconnects music after a pause or drop. YouTube URLs expire after a few hours, so a
    /// YouTube live stream is resolved again; a normal video picks up where it stopped.
    private func reconnectMusic() async {
        guard let music else { return }
        let request = musicRequest
        if let id = music.youtubeID, music.isLive {
            guard let resolved = try? await YouTubeSource.resolve(videoID: id) else {
                dlog("music", "reconnect: YouTube \(id) resolve failed")
                guard request == musicRequest else { return }
                musicStatus = .failed("Stream stopped. Tap play to try again.")
                updateNowPlaying()
                return
            }
            guard request == musicRequest else { return }
            musicURL = resolved.url
            musicPlayer.replaceCurrentItem(with: makeMusicItem(resolved.url))
        } else if let id = music.youtubeID {
            if musicPlayer.currentItem?.status == .failed {
                let resumeAt = musicPlayer.currentTime()
                // The old URL may have expired too.
                if let resolved = try? await YouTubeSource.resolve(videoID: id) {
                    guard request == musicRequest else { return }
                    musicURL = resolved.url
                }
                guard request == musicRequest, let url = musicURL else { return }
                musicPlayer.replaceCurrentItem(with: makeMusicItem(url))
                await musicPlayer.seek(to: resumeAt)
            }
        } else if let url = musicURL {
            musicPlayer.replaceCurrentItem(with: makeMusicItem(url))
        }
        guard request == musicRequest else { return }
        musicPlayer.play()
        watchdog(isMusic: true)
    }

    func stopMusic() {
        musicRequest += 1
        musicPlayer.replaceCurrentItem(with: nil)
        musicURL = nil
        music = nil
        musicStatus = .idle
        artwork = nil
        updateNowPlaying()
    }

    // MARK: ATC

    /// Connects to an airport: plays its tower (or approach/departure if the tower feed is offline)
    /// and, through RootView, makes the map show that airport's planes.
    func connect(_ airport: Airport) {
        let candidates = Catalog.feeds(at: airport.icao)
        guard !candidates.isEmpty else { return }
        Places.shared.noteConnected(airport.icao)
        if towerInBrowser {
            connectInBrowser(airport, candidates: candidates)
            return
        }
        // Already playing this airport. After Stop tower (feed gone) a tap starts it again.
        if self.airport == airport.icao, feed != nil, !isFailed(atcStatus) { return }
        dlog("atc", "connect \(airport.icao): \(candidates.map(\.mount).joined(separator: ", "))")
        cancelRetry(isMusic: false)
        retryCount[ObjectIdentifier(atcPlayer)] = 0
        userPaused = false
        atcProblem = nil
        self.airport = airport.icao
        chain = FeedChain(airport: airport.icao, candidates: candidates)
        startATC(candidates[0])
    }

    /// Browser mode: the tower plays in LiveATC's player page; Skyfi's own tower player stays off.
    private func connectInBrowser(_ airport: Airport, candidates: [ATCFeed], pick: ATCFeed? = nil) {
        let browser = LiveATCBrowser.shared
        if self.airport == airport.icao, browser.isOpen, pick == nil || pick?.mount == browser.feed?.mount {
            browser.expand()
            return
        }
        let chosen = pick ?? candidates[0]
        dlog("atc", "connect \(airport.icao) in the LiveATC player: \(chosen.mount)")
        cancelRetry(isMusic: false)
        watchdogs["atc"]?.cancel()
        chain = nil
        userPaused = false
        atcProblem = nil
        setATCItem(nil)
        atcStatus = .idle
        self.airport = airport.icao
        feed = chosen
        // WebKit plays through the app's audio session; make sure it's active for background audio.
        activateSession()
        browser.open(chosen)
        updateNowPlaying()
    }

    /// Plays one of the airport's feeds in the LiveATC player (connecting to the airport if needed).
    func play(_ feed: ATCFeed, at airport: Airport) {
        let candidates = Catalog.feeds(at: airport.icao)
        guard towerInBrowser, !candidates.isEmpty else {
            connect(airport)
            return
        }
        Places.shared.noteConnected(airport.icao)
        connectInBrowser(airport, candidates: candidates, pick: feed)
    }

    /// For an airport Skyfi has no feed list for: connects its planes and opens LiveATC's page
    /// for it, where you pick a feed (the pick becomes the tower feed).
    /// Connects to any airport: its feeds when Skyfi has them, LiveATC's airport page in browser
    /// mode, or just its planes otherwise. Links, Siri and the resume chip all come through here.
    func connectViaLiveATC(_ airport: Airport) {
        if !Catalog.feeds(at: airport.icao).isEmpty {
            connect(airport)
            return
        }
        if !towerInBrowser {
            dlog("atc", "\(airport.icao) has no feed in Skyfi: planes only")
            Places.shared.noteConnected(airport.icao)
            if self.airport != airport.icao { disconnect() }
            self.airport = airport.icao
            return
        }
        let browser = LiveATCBrowser.shared
        if self.airport == airport.icao, browser.isOpen {
            // Already here (maybe with a feed you picked on the page): just show it.
            browser.expand()
            return
        }
        dlog("atc", "connect \(airport.icao) via LiveATC's airport page")
        activateSession()
        Places.shared.noteConnected(airport.icao)
        cancelRetry(isMusic: false)
        watchdogs["atc"]?.cancel()
        chain = nil
        userPaused = false
        setATCItem(nil)
        atcStatus = .idle
        self.airport = airport.icao
        feed = nil
        LiveATCBrowser.shared.openAirport(airport.icao)
        updateNowPlaying()
    }

    /// Stops the tower but stays connected: the airport's planes stay on the map.
    func stopTower() {
        dlog("atc", "stop tower")
        LiveATCBrowser.shared.close()
        if towerInBrowser {
            feed = nil
        } else {
            cancelRetry(isMusic: false)
            watchdogs["atc"]?.cancel()
            chain = nil
            feed = nil
            setATCItem(nil)
            atcStatus = .idle
        }
        updateNowPlaying()
    }

    /// The LiveATC page moved to another feed (you picked one on it).
    func browserFeedChanged(_ feed: ATCFeed) {
        guard towerInBrowser, airport != nil else { return }
        self.feed = feed
        // You picked another airport's feed on the page: follow it, so the map shows its planes.
        if feed.airport != airport, AirportIndex.shared.airport(icao: feed.airport) != nil {
            dlog("atc", "page moved to \(feed.airport): following it")
            airport = feed.airport
            Places.shared.noteConnected(feed.airport)
        }
        updateNowPlaying()
    }

    /// Play was tapped on LiveATC's page while Skyfi had it paused: let the tower go, leave the music.
    func pageResumedTower() {
        guard towerInBrowser else { return }
        dlog("atc", "page play lifted the Skyfi pause")
        userPaused = false
        activateSession()
        LiveATCBrowser.shared.setSuspended(false)
        updateNowPlaying()
    }

    /// The LiveATC page started or stopped playing: keep the lock screen and play button right.
    func browserMediaChanged() {
        updateNowPlaying()
    }

    func disconnect() {
        dlog("atc", "disconnect")
        LiveATCBrowser.shared.close()
        cancelRetry(isMusic: false)
        watchdogs["atc"]?.cancel()
        chain = nil
        airport = nil
        feed = nil
        setATCItem(nil)
        atcStatus = .idle
        updateNowPlaying()
    }

    private func startATC(_ feed: ATCFeed) {
        dlog("atc", "start \(feed.name) \(feed.url.absoluteString)")
        probe(feed)
        activateSession()
        self.feed = feed
        setATCItem(AVPlayerItem(url: feed.url))
        atcStatus = .loading
        atcPlayer.play()
        watchdog(isMusic: false)
        updateNowPlaying()
    }

    /// The current tower item failed, stalled or never started.
    private func atcFailed() {
        guard var chain else { return }
        let failedMount = chain.current?.mount ?? "?"
        let outcome = chain.failed()
        self.chain = chain
        dlog("atc", "\(failedMount) failed: \(outcome), next \(chain.current?.mount ?? "none")\(atcProblem.map { " (\($0))" } ?? "")")
        guard let next = chain.current else { return }
        if userPaused {
            // Paused: remember which feed is next, start it on resume().
            feed = next
            dropATCItem()
            return
        }
        switch outcome {
        case .next:
            // That mount is offline: move straight on to the airport's next feed.
            startATC(next)
        case .retrySame:
            // Drop the dead item so a late start or a second failure event can't act on it.
            dropATCItem()
            atcStatus = .failed(atcProblem.map { "\($0) · retrying" } ?? "Feed dropped · reconnecting")
            updateNowPlaying()
            scheduleRetry(isMusic: false)
        case .exhausted:
            dropATCItem()
            feed = next
            atcStatus = .failed("No live feed at \(chain.airport)\(atcProblem.map { ": \($0)" } ?? " right now") · retrying")
            updateNowPlaying()
            scheduleRetry(isMusic: false)
        }
    }

    /// Stops the tower item without telling anyone it changed: the next one is coming.
    private func dropATCItem() {
        watchdogs["atc"]?.cancel()
        atcPlayer.replaceCurrentItem(with: nil)
        // A transmission cut off mid-word never closes: un-duck the music.
        onPause?()
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        userPaused = true
        musicPlayer.pause()
        atcPlayer.pause()
        LiveATCBrowser.shared.setSuspended(true)
        onPause?()
        if music != nil { musicStatus = .paused }
        if feed != nil, !towerInBrowser { atcStatus = .paused }
        updateNowPlaying()
    }

    func resume() {
        userPaused = false
        activateSession()
        if let music {
            musicStatus = .loading
            if music.isLive || musicPlayer.currentItem?.status == .failed {
                // Live streams go stale while paused, so reconnect them instead of resuming.
                Task { await reconnectMusic() }
            } else {
                musicPlayer.play()
            }
        }
        if towerInBrowser {
            let browser = LiveATCBrowser.shared
            if browser.suspended {
                // Skyfi paused it: lift that and the page carries on.
                browser.setSuspended(false)
            } else if browser.isOpen, browser.media != .playing {
                // The page stopped on its own; only your tap on its play button can restart it.
                browser.expand()
            }
        } else if let feed {
            setATCItem(AVPlayerItem(url: feed.url))
            atcPlayer.play()
            atcStatus = .loading
        }
        if music != nil { watchdog(isMusic: true) }
        if feed != nil, !towerInBrowser { watchdog(isMusic: false) }
        updateNowPlaying()
    }

    private func setATCItem(_ item: AVPlayerItem?) {
        atcPlayer.replaceCurrentItem(with: item)
        onATCItemChange?(item, item == nil ? nil : feed)
    }

    /// Dips the music while the tower is talking: 150 ms down to 35%, 600 ms back up.
    func setDucked(_ ducked: Bool) {
        let target: Float = ducked ? 0.35 : 1
        guard target != duckGain || duckTask != nil else { return }
        duckTask?.cancel()
        let steps = ducked ? 5 : 20
        let start = duckGain
        duckTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !Task.isCancelled else { return }
                self.duckGain = start + (target - start) * Float(step) / Float(steps)
                self.applyVolumes()
            }
            self?.duckTask = nil
        }
    }

    private func applyVolumes() {
        let musicGain = min(1, 2 * (1 - mix)) * duckGain
        let atcGain = min(1, 2 * mix)
        musicPlayer.volume = musicVolume * musicGain
        atcPlayer.volume = atcVolume * atcGain
    }

    // MARK: Session

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observePlayers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: raw, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones unplugged: pause, like every other audio app.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.playbackStalledNotification,
                     AVPlayerItem.didPlayToEndTimeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let item = note.object as? AVPlayerItem
                let ended = note.name == AVPlayerItem.didPlayToEndTimeNotification
                MainActor.assumeIsolated { self?.handleItemProblem(item, ended: ended) }
            })
        }
        observers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, let event = item.errorLog()?.events.last else { return }
                dlog(self.area(of: item), "player error log: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") \(event.uri ?? "")")
                if item === self.atcPlayer.currentItem, event.errorStatusCode >= 400 {
                    self.atcProblem = Self.problem(forHTTP: event.errorStatusCode)
                }
            }
        })
        for (player, isMusic) in [(musicPlayer, true), (atcPlayer, false)] {
            statusObservers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                let item = player.currentItem
                let failed = item?.status == .failed
                Task { @MainActor in
                    // A report about an item that's since been replaced is stale.
                    guard let self, item === (isMusic ? self.musicPlayer : self.atcPlayer).currentItem else { return }
                    self.syncStatus(isMusic: isMusic, status, failed: failed)
                }
            })
        }
        // An item that fails while loading never stalls, so it needs its own retry trigger.
        for player in [musicPlayer, atcPlayer] {
            statusObservers.append(player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
                guard player.currentItem?.status == .failed else { return }
                let item = player.currentItem
                Task { @MainActor in self?.handleItemProblem(item, ended: false) }
            })
        }
    }

    private func syncStatus(isMusic: Bool, _ status: AVPlayer.TimeControlStatus, failed: Bool) {
        let current = isMusic ? musicStatus : atcStatus
        guard current != .idle else { return }
        var next = current
        switch status {
        case .playing:
            next = .playing
            retryCount[ObjectIdentifier(isMusic ? musicPlayer : atcPlayer)] = 0
            cancelRetry(isMusic: isMusic)
            if !isMusic { chain?.markPlayed() }
        case .waitingToPlayAtSpecifiedRate: next = .loading
        case .paused:
            if failed {
                next = .failed(isMusic ? "Stream stopped." : "Feed offline right now.")
            } else if current != .loading, !isFailed(current) {
                next = .paused
            }
        @unknown default: break
        }
        guard next != current else { return }
        dlog(isMusic ? "music" : "atc", "status \(current) to \(next)")
        if isMusic { musicStatus = next } else { atcStatus = next }
        updateNowPlaying()
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func handleInterruption(type raw: UInt?, options: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        dlog("audio", "interruption \(type == .began ? "began" : "ended")\(options.map { " options \($0)" } ?? "")")
        switch type {
        case .began:
            if music != nil { musicStatus = .paused }
            if feed != nil, !towerInBrowser { atcStatus = .paused }
            updateNowPlaying()
        case .ended:
            // A pause you made yourself outlasts the interruption.
            if let options, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume), !userPaused {
                resume()
            }
        @unknown default: break
        }
    }

    /// A live stream dropped, stalled or failed to load: reconnect with backoff (3, 6, 12, 24, 30 s…).
    /// A background task keeps the app alive through the wait when the screen is locked.
    private func handleItemProblem(_ item: AVPlayerItem?, ended: Bool) {
        guard let item else { return }
        let isMusic = item === musicPlayer.currentItem
        let isATC = item === atcPlayer.currentItem
        guard isMusic || isATC else { return }
        dlog(isMusic ? "music" : "atc", "\(ended ? "ended" : "problem"): \(describe(item))")
        if isMusic, ended, music?.isLive == false {
            musicStatus = .paused
            updateNowPlaying()
            return
        }
        if isATC {
            atcFailed()
            return
        }
        scheduleRetry(isMusic: true)
    }

    private func cancelRetry(isMusic: Bool) {
        let key = ObjectIdentifier(isMusic ? musicPlayer : atcPlayer)
        retryTask[key]?.cancel()
        retryTask[key] = nil
        endBackgroundTask(key)
    }

    private func scheduleRetry(isMusic: Bool) {
        let isATC = !isMusic
        let key = ObjectIdentifier(isMusic ? musicPlayer : atcPlayer)
        guard retryTask[key] == nil else { return }
        let attempt = retryCount[key, default: 0]
        retryCount[key] = attempt + 1
        let delay = min(3 * pow(2, Double(attempt)), 30)
        dlog(isMusic ? "music" : "atc", "retry #\(attempt + 1) in \(Int(delay)) s")
        if backgroundTasks[key] == nil {
            backgroundTasks[key] = UIApplication.shared.beginBackgroundTask { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask(key) }
            }
        }
        retryTask[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask[key] = nil
            defer {
                if self.retryTask[key] == nil { self.endBackgroundTask(key) }
            }
            if self.userPaused { return }
            if isMusic, self.music != nil, self.musicStatus != .paused {
                if self.musicPlayer.currentItem?.status == .failed || self.music?.isLive == true {
                    await self.reconnectMusic()
                } else {
                    self.musicPlayer.play()
                }
            } else if isATC, !self.towerInBrowser, let feed = self.chain?.current ?? self.feed, self.atcStatus != .paused {
                self.startATC(feed)
            }
        }
    }

    private func endBackgroundTask(_ key: ObjectIdentifier) {
        guard let id = backgroundTasks.removeValue(forKey: key) else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    // MARK: Lock screen

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard hasSomething else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        let tower = feed?.name
        if let music {
            info[MPMediaItemPropertyTitle] = music.title
            info[MPMediaItemPropertyArtist] = tower.map { "Skyfi · \($0)" } ?? music.subtitle
        } else {
            info[MPMediaItemPropertyTitle] = tower ?? "Skyfi"
            info[MPMediaItemPropertyArtist] = "Skyfi · LiveATC"
        }
        info[MPNowPlayingInfoPropertyIsLiveStream] = music?.isLive ?? true
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // Tower only (or music without a thumbnail): Skyfi's own tile instead of a blank square.
        info[MPMediaItemPropertyArtwork] = artwork ?? Self.towerArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(youtubeID: String, request: Int) {
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: YouTubeLink.thumbnail(for: youtubeID)),
                  let image = UIImage(data: result.0) else { return }
            guard let self, request == self.musicRequest else { return }
            self.artwork = Self.makeArtwork(image)
            self.updateNowPlaying()
        }
    }

    /// A night-sky tile with the radio waves symbol, for the lock screen.
    private static let towerArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 600, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.03, green: 0.05, blue: 0.12, alpha: 1).cgColor,
                          UIColor(red: 0.08, green: 0.16, blue: 0.32, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: 260, weight: .semibold)
            if let symbol = UIImage(systemName: "antenna.radiowaves.left.and.right", withConfiguration: config)?
                .withTintColor(Theme.uiCyan, renderingMode: .alwaysOriginal) {
                let rect = CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                                  width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: rect)
            }
        }
        return makeArtwork(image)
    }()

    /// Built outside the main actor: MediaPlayer calls the handler on its own queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Marks a stream as failed if it hasn't started after 15 s.
    private func watchdog(isMusic: Bool) {
        let key = isMusic ? "music" : "atc"
        watchdogs[key]?.cancel()
        watchdogs[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            if isMusic, self.musicStatus == .loading {
                dlog("music", "watchdog: no sound after 15 s, \(self.describe(self.musicPlayer.currentItem))")
                self.musicStatus = .failed("Stream didn't start. Try again or pick another.")
            } else if !isMusic, self.atcStatus == .loading {
                dlog("atc", "watchdog: no sound after 15 s, \(self.describe(self.atcPlayer.currentItem))")
                self.atcFailed()
            }
        }
    }

    // MARK: Diagnostics (Mixer sheet > Debug log)

    private func area(of item: AVPlayerItem) -> String {
        item === atcPlayer.currentItem ? "atc" : (item === musicPlayer.currentItem ? "music" : "old item")
    }

    /// Player state and the newest error, for the log.
    private func describe(_ item: AVPlayerItem?) -> String {
        guard let item else { return "no item" }
        var parts = ["item status \(item.status.rawValue)"]
        if let error = item.error as NSError? {
            parts.append("error \(error.domain) \(error.code): \(error.localizedDescription)")
            if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("underlying \(under.domain) \(under.code): \(under.localizedDescription)")
            }
        }
        if let event = item.errorLog()?.events.last {
            parts.append("last log error \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "")")
        }
        if let access = item.accessLog()?.events.last {
            parts.append("server \(access.serverAddress ?? "?") bytes \(access.numberOfBytesTransferred)")
        }
        return parts.joined(separator: " | ")
    }

    private static func problem(forHTTP code: Int) -> String {
        switch code {
        case 401, 403: return "LiveATC refused the stream (HTTP \(code))"
        case 404: return "Feed not found (HTTP 404)"
        default: return "Feed server error (HTTP \(code))"
        }
    }

    /// Asks the feed for its headers once (then hangs up), so the log and the status line
    /// say whether the server refused us, the mount is gone, or the stream itself is fine.
    private func probe(_ feed: ATCFeed) {
        let url = feed.url
        let mount = feed.mount
        Task { [weak self] in
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                bytes.task.cancel()
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
                dlog("atc", "probe \(mount): HTTP \(code) \(type) via \(response.url?.host ?? "?")")
                guard let self, self.feed?.mount == mount else { return }
                self.atcProblem = code >= 400 ? Self.problem(forHTTP: code) : nil
            } catch {
                dlog("atc", "probe \(mount) failed: \(error.localizedDescription)")
            }
        }
    }
}
