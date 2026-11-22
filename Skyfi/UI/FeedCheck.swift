import AVFoundation
import Observation
import SwiftUI

/// Debug tool: tries every LiveATC mount in feeds.json on the phone (muted, one at a time)
/// and lists which ones play. LiveATC refuses scripted checks, so this is how dead mounts
/// get found; fix them in scripts/build_feeds.py.
@Observable
@MainActor
final class FeedChecker {
    enum Result: Equatable {
        case waiting
        case checking
        case live
        case dead(String)
    }

    private(set) var results: [String: Result] = [:]
    private(set) var running = false
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var liveCount: Int { results.values.filter { $0 == .live }.count }
    var deadCount: Int { results.values.filter { if case .dead = $0 { return true } else { return false } }.count }

    func start() {
        guard !running else { return }
        job?.cancel()
        generation += 1
        let gen = generation
        running = true
        results = Dictionary(uniqueKeysWithValues: Catalog.feeds.map { ($0.mount, Result.waiting) })
        job = Task {
            for feed in Catalog.feeds {
                if Task.isCancelled || gen != generation { return }
                results[feed.mount] = .checking
                let result = await Self.check(feed)
                // A stopped run must not write over a newer one.
                guard gen == generation else { return }
                results[feed.mount] = result
            }
            running = false
        }
    }

    func stop() {
        job?.cancel()
        generation += 1
        running = false
    }

    /// Plays the mount muted for up to 8 s and reports whether audio started.
    private static func check(_ feed: ATCFeed) async -> Result {
        let item = AVPlayerItem(url: feed.url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.play()
        defer { player.replaceCurrentItem(with: nil) }
        for _ in 0..<32 {
            if Task.isCancelled { return .waiting }
            if player.timeControlStatus == .playing { return .live }
            if item.status == .failed {
                return .dead(item.error?.localizedDescription ?? "Failed")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .dead("No audio after 8 s")
    }
}

struct FeedCheckView: View {
    @State private var checker = FeedChecker()

    var body: some View {
        List {
            Section {
                Button(checker.running ? "Stop" : "Check all \(Catalog.feeds.count) feeds") {
                    checker.running ? checker.stop() : checker.start()
                }
                if !checker.results.isEmpty {
                    Text("\(checker.liveCount) live · \(checker.deadCount) dead")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            } footer: {
                Text("Plays each tower, approach and departure mount muted for a few seconds. Screenshot the dead ones and send them over. Takes a few minutes.")
            }
            Section("Mounts") {
                ForEach(Catalog.feeds) { feed in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feed.mount).font(Theme.mono(13)).foregroundStyle(Theme.text)
                            Text(feed.name).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        status(checker.results[feed.mount])
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Feed check")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { checker.stop() }
    }

    @ViewBuilder private func status(_ result: FeedChecker.Result?) -> some View {
        switch result {
        case .checking: ProgressView().controlSize(.small)
        case .live: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .dead(let why): Text(why).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 140, alignment: .trailing)
        default: Image(systemName: "circle").foregroundStyle(Theme.muted)
        }
    }
}
