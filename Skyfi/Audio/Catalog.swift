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
/// Skyfi carries one feed per airport: the tower, or approach/departure where there's no tower feed.
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
    /// One feed per airport, best kind first (tower, then approach, then departure).
    static let feeds: [ATCFeed] = {
        let all: [ATCFeed] = load("feeds")
        var best: [String: ATCFeed] = [:]
        for feed in all where feed.kind.rank < (best[feed.airport]?.kind.rank ?? .max) {
            best[feed.airport] = feed
        }
        return all.filter { best[$0.airport] == $0 }
    }()

    private static func load<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return items
    }

    static func feed(at icao: String) -> ATCFeed? {
        feeds.first { $0.airport == icao }
    }

    struct NearbyFeed: Identifiable {
        let feed: ATCFeed
        let airport: Airport?
        let distanceNM: Double

        var id: String { feed.id }
    }

    /// Feeds sorted by the distance of their airport from `point`.
    static func feeds(near point: CLLocationCoordinate2D, index: AirportIndex = .shared) -> [NearbyFeed] {
        feeds.map { feed in
            let airport = index.airport(icao: feed.airport)
            let distance = airport.map { Geo.distanceNM(point.latitude, point.longitude, $0.lat, $0.lon) } ?? .infinity
            return NearbyFeed(feed: feed, airport: airport, distanceNM: distance)
        }
        .sorted { $0.distanceNM < $1.distanceNM }
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
