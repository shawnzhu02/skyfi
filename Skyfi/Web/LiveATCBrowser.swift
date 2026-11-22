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

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let helper = BrowserHelper()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Keeps LiveATC's Cloudflare check cookie, so the page doesn't re-check every launch.
        config.websiteDataStore = .default()
        let script = WKUserScript(source: Self.mediaScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(helper, name: "skyfiMedia")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = true
        helper.owner = self
        webView.navigationDelegate = helper
        webView.uiDelegate = helper

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let title = view.title ?? ""
                Task { @MainActor in self?.title = title }
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
        expand()
        // A new connect is a fresh start: lift any old Skyfi pause so the page's play works.
        setSuspended(false)
        guard !same else { return }
        media = .none
        load(Self.playerURL(for: feed))
        startPolling()
    }

    /// LiveATC's page for an airport, to pick one of its feeds there.
    func openAirport(_ icao: String) {
        feed = nil
        isOpen = true
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
    }

    func close() {
        guard isOpen else { return }
        dlog("web", "close")
        pollTask?.cancel()
        pollTask = nil
        webView.pauseAllMediaPlayback(completionHandler: nil)
        if suspended { webView.setAllMediaPlaybackSuspended(false, completionHandler: nil) }
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        suspended = false
        isOpen = false
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

    private func urlChanged(_ url: URL?) {
        pageURL = url
        guard isOpen, let url, let feed = Self.feed(fromPlayerURL: url), feed.mount != self.feed?.mount else { return }
        dlog("web", "page switched to \(feed.mount)")
        self.feed = feed
        Mixer.shared.browserFeedChanged(feed)
    }

    fileprivate func handleMedia(type: String, detail: String, host: String) {
        dlog("web", "media \(type)\(detail.isEmpty ? "" : " \(detail)")\(host.isEmpty ? "" : " via \(host)")")
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

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                LiveATCWebView()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 8)
                Text("Tower audio plays from LiveATC.net's own player. Balance it with the music volume. Who's talking needs Skyfi's own player, which LiveATC blocks.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(height: geo.size.height * 0.7)
            .panel()
            .frame(maxHeight: .infinity, alignment: .bottom)
            .offset(y: browser.expanded ? 0 : geo.size.height + 60)
            .allowsHitTesting(browser.expanded)
        }
        .padding(.horizontal, 8)
        .animation(.spring(duration: 0.3), value: browser.expanded)
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
            if browser.suspended {
                iconButton("play.fill", label: "Resume") { mixer.resume() }
            }
            iconButton("chevron.backward", label: "Back") { browser.goBack() }
                .disabled(!browser.canGoBack)
                .opacity(browser.canGoBack ? 1 : 0.35)
            iconButton("arrow.clockwise", label: "Reload") { browser.reload() }
            iconButton("list.bullet", label: "All feeds at this airport") { browser.showAllFeeds() }
            iconButton("safari", label: "Open in Safari") {
                let page = browser.pageURL.flatMap { LiveATCBrowser.isLiveATC($0) ? $0 : nil }
                if let url = page ?? browser.feed.map(LiveATCBrowser.playerURL(for:)) { openURL(url) }
            }
            iconButton("xmark", label: "Stop tower") { mixer.stopTower() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
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
