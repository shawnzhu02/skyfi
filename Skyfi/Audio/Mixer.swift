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

    var isPlaying: Bool { musicStatus.isActive || atcStatus.isActive }
    var hasSomething: Bool { music != nil || feed != nil }

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
    @ObservationIgnored private var backgroundTasks: [ObjectIdentifier: UIBackgroundTaskIdentifier] = [:]

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
        await playYouTube(id: id, title: nil, subtitle: "YouTube")
    }

    func play(_ preset: Preset) async {
        switch preset.kind {
        case .youtube:
            await playYouTube(id: preset.value, title: preset.title, subtitle: preset.subtitle)
        case .radio:
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
        do {
            let resolved = try await YouTubeSource.resolve(videoID: id)
            guard request == musicRequest else { return }
            music = Music(title: title ?? resolved.title ?? "YouTube", subtitle: subtitle, youtubeID: id, isLive: resolved.isLive)
            startMusic(resolved.url)
        } catch {
            guard request == musicRequest else { return }
            musicStatus = .failed("YouTube wouldn't give audio for this one. Try another link.")
            updateNowPlaying()
        }
    }

    private func startMusic(_ url: URL) {
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
        if self.airport == airport.icao, !isFailed(atcStatus) { return }
        cancelRetry(isMusic: false)
        retryCount[ObjectIdentifier(atcPlayer)] = 0
        self.airport = airport.icao
        chain = FeedChain(airport: airport.icao, candidates: candidates)
        startATC(candidates[0])
    }

    func disconnect() {
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
        let outcome = chain.failed()
        self.chain = chain
        guard let next = chain.current else { return }
        switch outcome {
        case .next:
            // That mount is offline: move straight on to the airport's next feed.
            startATC(next)
        case .retrySame:
            if atcStatus == .loading { atcStatus = .failed("Feed dropped · reconnecting") }
            scheduleRetry(isMusic: false)
        case .exhausted:
            feed = next
            atcStatus = .failed("No live feed at \(chain.airport) right now · retrying")
            updateNowPlaying()
            scheduleRetry(isMusic: false)
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        musicPlayer.pause()
        atcPlayer.pause()
        onPause?()
        if music != nil { musicStatus = .paused }
        if feed != nil { atcStatus = .paused }
        updateNowPlaying()
    }

    func resume() {
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
        if let feed {
            setATCItem(AVPlayerItem(url: feed.url))
            atcPlayer.play()
            atcStatus = .loading
        }
        if music != nil { watchdog(isMusic: true) }
        if feed != nil { watchdog(isMusic: false) }
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
        statusObservers.append(musicPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let failed = player.currentItem?.status == .failed
            Task { @MainActor in self?.syncStatus(isMusic: true, status, failed: failed) }
        })
        statusObservers.append(atcPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let failed = player.currentItem?.status == .failed
            Task { @MainActor in self?.syncStatus(isMusic: false, status, failed: failed) }
        })
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
        if isMusic { musicStatus = next } else { atcStatus = next }
        updateNowPlaying()
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func handleInterruption(type raw: UInt?, options: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if music != nil { musicStatus = .paused }
            if feed != nil { atcStatus = .paused }
            updateNowPlaying()
        case .ended:
            if let options, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
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
        if backgroundTasks[key] == nil {
            backgroundTasks[key] = UIApplication.shared.beginBackgroundTask { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask(key) }
            }
        }
        retryTask[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            defer {
                self.retryTask[key] = nil
                self.endBackgroundTask(key)
            }
            guard !Task.isCancelled else { return }
            if isMusic, self.music != nil, self.musicStatus != .paused {
                if self.musicPlayer.currentItem?.status == .failed || self.music?.isLive == true {
                    await self.reconnectMusic()
                } else {
                    self.musicPlayer.play()
                }
            } else if isATC, let feed = self.chain?.current ?? self.feed, self.atcStatus != .paused {
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
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
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
                self.musicStatus = .failed("Stream didn't start. Try again or pick another.")
            } else if !isMusic, self.atcStatus == .loading {
                self.atcFailed()
            }
        }
    }
}
