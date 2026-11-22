import CoreLocation
import Foundation

/// A music preset: a YouTube video or live stream, or a plain internet radio stream.
struct Preset: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case youtube
        case radio
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    /// YouTube video ID, or the stream URL for radio.
    let value: String
}

/// A LiveATC feed. `mount` is the LiveATC mount point (for example `kbos_twr`).
/// An airport has up to three: tower, approach, departure. Connecting plays one at a time,
/// tower first, and moves to the next only when one is offline (see `FeedChain`).
struct ATCFeed: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case tower
        case approach
        case departure

        var rank: Int {
            switch self {
            case .tower: return 0
            case .approach: return 1
            case .departure: return 2
            }
        }

        var label: String {
            switch self {
            case .tower: return "Tower"
            case .approach: return "Approach"
            case .departure: return "Departure"
            }
        }
    }

    let mount: String
    let airport: String
    let name: String
    let kind: Kind

    var id: String { mount }
    var url: URL { URL(string: "http://d.liveatc.net/\(mount)")! }
}

/// Presets and feeds bundled with the app.
enum Catalog {
    static let presets: [Preset] = load("presets")
    /// Every mount, built by scripts/build_feeds.py.
    static let feeds: [ATCFeed] = load("feeds")
    /// Candidates per airport, tower first.
    private static let byAirport: [String: [ATCFeed]] = Dictionary(grouping: feeds, by: \.airport)
        .mapValues { $0.sorted { $0.kind.rank < $1.kind.rank } }
    /// ICAO codes of the airports you can connect to.
    static let connectable: Set<String> = Set(byAirport.keys)

    private static func load<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return items
    }

    /// The airport's feeds in the order Skyfi tries them: tower, approach, departure.
    static func feeds(at icao: String) -> [ATCFeed] {
        byAirport[icao] ?? []
    }

    /// The first feed Skyfi tries at this airport.
    static func feed(at icao: String) -> ATCFeed? {
        feeds(at: icao).first
    }

    struct NearbyAirport: Identifiable {
        let airport: Airport
        let distanceNM: Double

        var id: String { airport.icao }
    }

    /// Connectable airports sorted by distance from `point`.
    static func airports(near point: CLLocationCoordinate2D, index: AirportIndex = .shared) -> [NearbyAirport] {
        connectable.compactMap { index.airport(icao: $0) }
            .map { NearbyAirport(airport: $0, distanceNM: Geo.distanceNM(point.latitude, point.longitude, $0.lat, $0.lon)) }
            .sorted { $0.distanceNM < $1.distanceNM }
    }
}

/// The order Skyfi works through an airport's feeds. Only one plays at a time: before any of
/// them has played, an offline one hands over to the next; once one has played, a drop retries
/// that same one (it's the right frequency and LiveATC streams blip).
struct FeedChain: Equatable {
    enum Outcome: Equatable {
        /// Try `current` now: it's the next candidate.
        case next
        /// Retry `current` after a backoff.
        case retrySame
        /// Every candidate failed; `current` is the first again, retry after a backoff.
        case exhausted
    }

    let airport: String
    let candidates: [ATCFeed]
    private(set) var index = 0
    private(set) var played = false

    init(airport: String, candidates: [ATCFeed]) {
        self.airport = airport
        self.candidates = candidates
    }

    var current: ATCFeed? { candidates.indices.contains(index) ? candidates[index] : nil }

    mutating func markPlayed() {
        played = true
    }

    mutating func failed() -> Outcome {
        if played { return .retrySame }
        if index + 1 < candidates.count {
            index += 1
            return .next
        }
        index = 0
        return .exhausted
    }
}

enum YouTubeLink {
    /// Pulls the 11-character video ID out of a pasted link or bare ID.
    static func videoID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isID(text) { return text }
        guard let url = URL(string: text.contains("://") ? text : "https://\(text)"),
              let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") {
            return parts.first.flatMap { isID($0) ? $0 : nil }
        }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, isID(v) {
            return v
        }
        if parts.count >= 2, ["live", "shorts", "embed", "v"].contains(parts[0]), isID(parts[1]) {
            return parts[1]
        }
        return nil
    }

    private static func isID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && text.allSatisfy(\.isASCII)
    }

    static func thumbnail(for id: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }
}
