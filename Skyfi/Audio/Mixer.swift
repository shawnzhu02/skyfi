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
    @ObservationIgnored private var duckGain: Float = 1
    @ObservationIgnored private var duckTask: Task<Void, Never>?

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
        musicPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        musicStatus = .loading
        musicPlayer.play()
        watchdog(isMusic: true)
        updateNowPlaying()
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

    func tune(_ feed: ATCFeed) {
        activateSession()
        self.feed = feed
        setATCItem(AVPlayerItem(url: feed.url))
        atcStatus = .loading
        atcPlayer.play()
        watchdog(isMusic: false)
        updateNowPlaying()
    }

    func stopATC() {
        feed = nil
        setATCItem(nil)
        atcStatus = .idle
        updateNowPlaying()
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        musicPlayer.pause()
        atcPlayer.pause()
        if music != nil { musicStatus = .paused }
        if feed != nil { atcStatus = .paused }
        updateNowPlaying()
    }

    func resume() {
        activateSession()
        // Live streams go stale while paused, so reconnect them instead of resuming.
        if let music, music.isLive, let musicURL {
            musicPlayer.replaceCurrentItem(with: AVPlayerItem(url: musicURL))
        }
        if music != nil {
            musicPlayer.play()
            musicStatus = .loading
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
    }

    private func syncStatus(isMusic: Bool, _ status: AVPlayer.TimeControlStatus, failed: Bool) {
        let current = isMusic ? musicStatus : atcStatus
        guard current != .idle else { return }
        var next = current
        switch status {
        case .playing: next = .playing
        case .waitingToPlayAtSpecifiedRate: next = .loading
        case .paused:
            if failed {
                next = .failed(isMusic ? "Stream stopped." : "Feed offline right now.")
            } else if current != .loading {
                next = .paused
            }
        @unknown default: break
        }
        if isMusic { musicStatus = next } else { atcStatus = next }
    }

    private func handleInterruption(type raw: UInt?, options: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if music != nil { musicStatus = .paused }
            if feed != nil { atcStatus = .paused }
        case .ended:
            if let options, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                resume()
            }
        @unknown default: break
        }
    }

    /// A live stream dropped or stalled: reconnect after a short wait.
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
        let key = ObjectIdentifier(isMusic ? musicPlayer : atcPlayer)
        retryTask[key]?.cancel()
        retryTask[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if isMusic, let url = self.musicURL, self.musicStatus != .paused {
                self.musicPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                self.musicPlayer.play()
            } else if isATC, let feed = self.feed, self.atcStatus != .paused {
                self.setATCItem(AVPlayerItem(url: feed.url))
                self.atcPlayer.play()
            }
        }
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
                self.atcStatus = .failed("Feed offline right now. Try another tower.")
            }
        }
    }
}
