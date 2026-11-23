import Network
import Observation
import SwiftUI
import WebKit

/// LiveATC's own player page, inside Skyfi. LiveATC refuses app players (HTTP 403) and its terms
/// only allow listening through its site, so the tower plays the way it would in Safari: their page,
/// their player, your tap on play. Skyfi never reads the stream address out of the page.
/// One web view lives for the whole session, so audio keeps going while the panel is minimized.
@Observable
@MainActor
final class LiveATCBrowser {
    static let shared = LiveATCBrowser()

    enum Media: Equatable {
        case none
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var isOpen = false
    private(set) var expanded = false
    /// The feed on the page right now (follows the page if you pick another feed on it).
    private(set) var feed: ATCFeed?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var media: Media = .none
    private(set) var pageURL: URL?
    /// Set by Skyfi's pause button; the page's own play button can't start audio until it's lifted.
    private(set) var suspended = false
    /// The Cloudflare "checking your browser" page has been up for a while.
    private(set) var stuckOnCheck = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The stuck check already got one fresh start (cookies cleared, page reloaded) this time.
    @ObservationIgnored private var retriedCheck = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let helper = BrowserHelper()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var online = true
    /// The network came back while Skyfi had the page paused: reload when you resume.
    @ObservationIgnored private var reloadOnResume = false

    private init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Keeps LiveATC's Cloudflare check cookie, so the page doesn't re-check every launch.
        config.websiteDataStore = .default()
        // Skyfi's media observer runs in its own script world, so LiveATC's page and Cloudflare's
        // browser check never see it (no globals, no message handler in the page's world).
        let script = WKUserScript(source: Self.mediaScript, injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: false, in: .defaultClient)
        config.userContentController.addUserScript(script)
        config.userContentController.add(helper, contentWorld: .defaultClient, name: "skyfiMedia")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = true
        helper.owner = self
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.shawnzhu.skyfi.network", qos: .utility))
        webView.navigationDelegate = helper
        webView.uiDelegate = helper

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let title = view.title ?? ""
                Task { @MainActor in self?.titleChanged(title) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let loading = view.isLoading
                Task { @MainActor in self?.isLoading = loading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                let back = view.canGoBack
                Task { @MainActor in self?.canGoBack = back }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                let url = view.url
                Task { @MainActor in self?.urlChanged(url) }
            },
        ]
    }

    // MARK: Opening and closing

    /// Opens the player page for a feed and shows the panel.
    func open(_ feed: ATCFeed) {
        let same = isOpen && self.feed?.mount == feed.mount
        self.feed = feed
        isOpen = true
        Mixer.shared.setMixesWithWebPlayer(true)
        expand()
        // A new connect is a fresh start: lift any old Skyfi pause so the page's play works.
        setSuspended(false)
        guard !same else { return }
        media = .none
        retriedCheck = false
        load(Self.playerURL(for: feed))
        startPolling()
    }

    /// LiveATC's page for an airport, to pick one of its feeds there.
    func openAirport(_ icao: String) {
        feed = nil
        isOpen = true
        Mixer.shared.setMixesWithWebPlayer(true)
        expand()
        setSuspended(false)
        media = .none
        load(Self.airportURL(icao: icao))
        startPolling()
    }

    /// Shows the panel. A Skyfi pause stays in place: Skyfi's play button lifts it.
    func expand() {
        expanded = true
    }

    func minimize() {
        expanded = false
    }

    /// LiveATC's page for the airport, with every feed it has there.
    func showAllFeeds() {
        guard let icao = feed?.airport ?? Mixer.shared.airport else { return }
        load(Self.airportURL(icao: icao))
    }

    func reload() {
        dlog("web", "reload")
        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func setSuspended(_ value: Bool) {
        guard isOpen, value != suspended else { return }
        suspended = value
        dlog("web", value ? "media suspended (Skyfi pause)" : "media resumed")
        webView.setAllMediaPlaybackSuspended(value, completionHandler: nil)
        if value, media == .playing { setMedia(.paused) }
        if !value, reloadOnResume {
            reloadOnResume = false
            if case .failed = media {
                dlog("web", "reloading the player (network came back while paused)")
                webView.reload()
            }
        }
    }

    func close() {
        guard isOpen else { return }
        dlog("web", "close")
        pollTask?.cancel()
        pollTask = nil
        checkTask?.cancel()
        stuckOnCheck = false
        webView.pauseAllMediaPlayback(completionHandler: nil)
        if suspended { webView.setAllMediaPlaybackSuspended(false, completionHandler: nil) }
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        suspended = false
        isOpen = false
        Mixer.shared.setMixesWithWebPlayer(false)
        expanded = false
        feed = nil
        pageURL = nil
        setMedia(.none)
    }

    private func load(_ url: URL) {
        dlog("web", "load \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    // MARK: URLs

    static func playerURL(for feed: ATCFeed) -> URL {
        var parts = URLComponents(string: "https://www.liveatc.net/hlisten.php")!
        parts.queryItems = [URLQueryItem(name: "mount", value: feed.mount),
                            URLQueryItem(name: "icao", value: feed.airport.lowercased())]
        return parts.url!
    }

    static func airportURL(icao: String) -> URL {
        URL(string: "https://www.liveatc.net/search/?icao=\(icao.lowercased())")!
    }

    /// An https page on liveatc.net or one of its subdomains.
    nonisolated static func isLiveATC(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "liveatc.net" || host.hasSuffix(".liveatc.net")
    }

    /// The feed a LiveATC player URL plays, if it's one (hlisten.php?mount=kbos_twr&icao=kbos).
    nonisolated static func feed(fromPlayerURL url: URL) -> ATCFeed? {
        guard isLiveATC(url), url.path.hasSuffix("hlisten.php"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mount = items.first(where: { $0.name == "mount" })?.value, !mount.isEmpty else { return nil }
        if let known = Catalog.feeds.first(where: { $0.mount == mount }) { return known }
        let icao = (items.first(where: { $0.name == "icao" })?.value ?? String(mount.prefix(4))).uppercased()
        let kind: ATCFeed.Kind
        if mount.contains("_app") { kind = .approach } else if mount.contains("_dep") { kind = .departure } else { kind = .tower }
        return ATCFeed(mount: mount, airport: icao, name: "\(icao) \(mount)", kind: kind)
    }

    // MARK: Page events

    private func titleChanged(_ title: String) {
        self.title = title
        let checking = title.localizedCaseInsensitiveContains("just a moment")
            || title.localizedCaseInsensitiveContains("attention required")
        checkTask?.cancel()
        guard checking else {
            stuckOnCheck = false
            return
        }
        // Give the check 15 s to finish by itself. Then start it once more from scratch (an old,
        // half-finished check cookie can keep it spinning), and only after that offer Safari.
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            if !self.retriedCheck {
                self.retriedCheck = true
                dlog("web", "browser check stuck after 15 s: clearing LiveATC's cookies and reloading")
                await self.clearLiveATCData()
                self.webView.reload()
            } else {
                self.stuckOnCheck = true
                dlog("web", "still on the browser check after a fresh start")
            }
        }
    }

    /// Forgets LiveATC's cookies and storage (only LiveATC's and Cloudflare's), for a clean check.
    private func clearLiveATCData() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { $0.displayName.contains("liveatc") || $0.displayName.contains("cloudflare") }
        guard !mine.isEmpty else { return }
        await store.removeData(ofTypes: types, for: mine)
    }

    private func urlChanged(_ url: URL?) {
        pageURL = url
        guard isOpen, let url, let feed = Self.feed(fromPlayerURL: url), feed.mount != self.feed?.mount else { return }
        dlog("web", "page switched to \(feed.mount)")
        self.feed = feed
        Mixer.shared.browserFeedChanged(feed)
    }

    fileprivate func handleMedia(type: String, detail: String, host: String) {
        dlog("web", "media \(type)\(detail.isEmpty ? "" : " \(detail)")\(host.isEmpty ? "" : " via \(host)")")
        // You tapped play on the page while Skyfi had it paused: that's a resume, not something to block.
        // Only the tower resumes; the music stays as you left it.
        if type == "play", suspended {
            Mixer.shared.pageResumedTower()
            return
        }
        switch type {
        case "play", "waiting", "stalled": setMedia(.loading)
        case "playing": setMedia(.playing)
        case "pause", "ended": setMedia(.paused)
        case "error": setMedia(.failed(detail.isEmpty ? "LiveATC's player stopped" : "LiveATC's player: \(detail)"))
        default: break
        }
    }

    fileprivate func pageResponse(status: Int, url: String, mainFrame: Bool) {
        guard mainFrame else { return }
        // LiveATC sits behind Cloudflare: its "checking your browser" page comes back as 403 and
        // then reloads by itself, so a 403 here isn't a failure yet.
        dlog("web", "HTTP \(status) \(url)\(status == 403 ? " (Cloudflare check?)" : "")")
    }

    fileprivate func navigationFailed(_ error: Error) {
        let ns = error as NSError
        // A new load cancelling the old one isn't a failure.
        guard ns.code != NSURLErrorCancelled else { return }
        dlog("web", "load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        setMedia(.failed(ns.localizedDescription))
    }

    /// Back online after a drop (a tunnel, a dead zone): reload a page that failed, so you only tap play.
    private func networkChanged(_ up: Bool) {
        defer { online = up }
        guard up, !online else { return }
        dlog("web", "network back")
        guard isOpen, case .failed = media else { return }
        if suspended {
            reloadOnResume = true
        } else {
            dlog("web", "reloading the player after the network came back")
            webView.reload()
        }
    }

    fileprivate func contentProcessEnded() {
        dlog("web", "page process ended, reloading")
        setMedia(.failed("Player page stopped · reloading"))
        if isOpen { webView.reload() }
    }

    private func setMedia(_ next: Media) {
        guard next != media else { return }
        media = next
        Mixer.shared.browserMediaChanged()
    }

    /// Media events miss players that aren't in the page, so also ask WebKit what's playing.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.isOpen else { return }
                let state = await self.webView.requestMediaPlaybackState()
                // A Skyfi pause may still be landing; don't flip back to playing meanwhile.
                guard !self.suspended else { continue }
                switch state {
                case .playing:
                    self.setMedia(.playing)
                case .paused, .suspended:
                    if self.media == .playing { self.setMedia(.paused) }
                default:
                    break
                }
            }
        }
    }

    /// Watches the page's audio elements (events only, never their address) so Skyfi knows when
    /// the tower is playing and why it stopped.
    private static let mediaScript = #"""
    (function () {
      // Only LiveATC's own frames; Cloudflare's check frame is left alone.
      if (!/(^|\.)liveatc\.net$/.test(location.hostname)) { return; }
      if (window.__skyfiMedia) { return; }
      window.__skyfiMedia = true;
      var names = { 1: 'aborted', 2: 'network error', 3: 'decode error', 4: 'stream refused or not supported' };
      ['play', 'playing', 'pause', 'waiting', 'stalled', 'ended', 'error'].forEach(function (type) {
        document.addEventListener(type, function (event) {
          var el = event.target;
          if (!el || !(el instanceof HTMLMediaElement)) { return; }
          var detail = '';
          if (type === 'error' && el.error) {
            detail = 'code ' + el.error.code + ' ' + (names[el.error.code] || '') + (el.error.message ? ' ' + el.error.message : '');
          }
          var host = '';
          try { host = new URL(el.currentSrc || el.src).host; } catch (e) {}
          try { window.webkit.messageHandlers.skyfiMedia.postMessage({ type: type, detail: detail, host: host }); } catch (e) {}
        }, true);
      });
    })();
    """#
}

/// WebKit delegates for the browser (kept apart so the browser itself needn't be an NSObject).
@MainActor
private final class BrowserHelper: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var owner: LiveATCBrowser?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        owner?.handleMedia(type: type, detail: body["detail"] as? String ?? "", host: body["host"] as? String ?? "")
    }

    /// The panel only shows LiveATC: other top-level links (ads, social) open in Safari instead.
    /// Frames inside a LiveATC page (Cloudflare's check, the player) load as usual.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else { return .allow }
        if url.absoluteString == "about:blank" || LiveATCBrowser.isLiveATC(url) { return .allow }
        // Only a link you tapped leaves for Safari; a script redirect off LiveATC is just stopped.
        if navigationAction.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
            dlog("web", "tapped outside link sent to Safari: \(url.host ?? "?")")
            await UIApplication.shared.open(url)
        } else {
            dlog("web", "blocked navigation off LiveATC: \(url.host ?? url.scheme ?? "?")")
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse {
            owner?.pageResponse(status: http.statusCode, url: http.url?.absoluteString ?? "?",
                                mainFrame: navigationResponse.isForMainFrame)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.contentProcessEnded()
    }

    /// LiveATC opens players in pop-up windows: load them in the same view instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit only lets pages open windows from a tap. LiveATC pop-ups load here (the navigation
        // policy above still vets them); anything else goes to Safari.
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if LiveATCBrowser.isLiveATC(url) {
            webView.load(navigationAction.request)
        } else if url.scheme == "https" || url.scheme == "http" {
            dlog("web", "tapped outside pop-up sent to Safari: \(url.host ?? "?")")
            UIApplication.shared.open(url)
        }
        return nil
    }
}

/// The shared web view, placed in SwiftUI.
struct LiveATCWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { LiveATCBrowser.shared.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The LiveATC player over the map. It stays in the view tree while minimized (moved off-screen),
/// so the page and its audio keep running.
struct LiveATCPanel: View {
    @State private var browser = LiveATCBrowser.shared
    @Environment(Mixer.self) private var mixer
    @Environment(\.openURL) private var openURL
    /// Half height leaves the map in view; tall shows more of LiveATC's page.
    @AppStorage("liveATCPanelTall") private var tall = false
    /// Opens the mixer (it sits under the panel while the panel is up).
    var onMixer: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                    .contentShape(Rectangle())
                    // On the header only, so the page itself still scrolls.
                    .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                        // Up for tall, down for half, further down (or down from half) to minimize.
                        if drag.translation.height < -40 { tall = true }
                        else if drag.translation.height > 120 || (drag.translation.height > 40 && !tall) { browser.minimize() }
                        else if drag.translation.height > 40 { tall = false }
                    })
                if let problem = problem {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer(minLength: 4)
                        Button("Open in Safari") { openInSafari() }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.cyan)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                LiveATCWebView()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            .frame(height: geo.size.height * (tall ? 0.78 : 0.5))
            .panel()
            .frame(maxHeight: .infinity, alignment: .bottom)
            .offset(y: browser.expanded ? 0 : geo.size.height + 60)
            .allowsHitTesting(browser.expanded)
        }
        .padding(.horizontal, 8)
        .animation(.spring(duration: 0.3), value: browser.expanded)
        .animation(.spring(duration: 0.3), value: tall)
    }

    private var header: some View {
        HStack(spacing: 4) {
            iconButton("chevron.down", label: "Minimize") { browser.minimize() }
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.feed?.name ?? "LiveATC")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(LiveATCMiniBar.status(browser))
                    .font(.system(size: 11)).foregroundStyle(Theme.cyan).lineLimit(1)
            }
            Spacer(minLength: 4)
            // Everything else lives in one menu, so the header stays simple.
            Menu {
                if browser.canGoBack {
                    Button { browser.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                }
                Button { browser.showAllFeeds() } label: { Label("Other feeds here", systemImage: "list.bullet") }
                Button { tall.toggle() } label: {
                    Label(tall ? "Shorter panel" : "Taller panel",
                          systemImage: tall ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                Button { browser.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Button { openInSafari() } label: { Label("Open in Safari", systemImage: "safari") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
            iconButton("xmark", label: "Stop tower") { mixer.stopTower() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// Your starred and recent airports, one tap to switch the tower (and the map) there.
    @ViewBuilder private var quickSwitch: some View {
        let places = Places.shared
        var seen = Set<String>()
        let icaos = (places.favorites + places.recents).filter { seen.insert($0).inserted }
        let airports = icaos.compactMap { AirportIndex.shared.airport(icao: $0) }
        if airports.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(airports) { airport in
                        let here = mixer.airport == airport.icao
                        Button {
                            if !here { mixer.connectViaLiveATC(airport) }
                        } label: {
                            Text((places.isFavorite(airport.icao) ? "★" : "") + airport.code)
                                .font(Theme.mono(12, .bold))
                                .foregroundStyle(here ? Color.black : Theme.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(here ? Theme.cyan : Theme.muted.opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(here ? "\(airport.name), playing" : "Switch to \(airport.name)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    /// Why the page might not be working, with Safari as the way out.
    private var problem: String? {
        if case .failed(let message) = browser.media { return message }
        if browser.stuckOnCheck { return "LiveATC's check won't finish here." }
        return nil
    }

    private func openInSafari() {
        let page = browser.pageURL.flatMap { LiveATCBrowser.isLiveATC($0) ? $0 : nil }
        if let url = page ?? browser.feed.map(LiveATCBrowser.playerURL(for:)) {
            dlog("web", "opened in Safari")
            openURL(url)
        }
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// The minimized player: one row above the mixer bar.
struct LiveATCMiniBar: View {
    @State private var browser = LiveATCBrowser.shared
    @Environment(Mixer.self) private var mixer

    var body: some View {
        HStack(spacing: 10) {
            Button { browser.expand() } label: {
                HStack(spacing: 10) {
                    Image(systemName: browser.media == .playing ? "waveform" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.cyan)
                        .symbolEffect(.variableColor.iterative, isActive: browser.media == .playing)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(browser.feed?.name ?? "LiveATC")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(Self.status(browser))
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if browser.suspended {
                Button { mixer.resume() } label: {
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.cyan)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Resume")
            }
            Button { mixer.stopTower() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Stop tower")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .panel()
    }

    static func status(_ media: LiveATCBrowser.Media, loading: Bool) -> String {
        switch media {
        case .playing: return "Live from LiveATC.net"
        case .loading: return "Connecting…"
        case .paused: return "Paused · tap play on the page"
        case .failed(let message): return message
        case .none: return loading ? "Opening LiveATC…" : "Tap play on the page to listen"
        }
    }

    static func status(_ browser: LiveATCBrowser) -> String {
        browser.suspended ? "Paused in Skyfi" : status(browser.media, loading: browser.isLoading)
    }
}
