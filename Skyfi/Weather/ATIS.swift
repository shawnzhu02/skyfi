import Foundation
import Observation

/// An airport's digital ATIS (the recorded airport information), from atis.info's free API.
/// Busy airports publish separate arrival and departure broadcasts.
struct ATIS: Equatable {
    enum Kind: String {
        case combined
        case arrival = "arr"
        case departure = "dep"
    }

    let airport: String
    let kind: Kind
    /// The information letter ("O" = information Oscar).
    let code: String
    let text: String
    let updated: Date?

    static func parse(_ data: Data) -> [ATIS] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { item in
            guard let airport = item["airport"] as? String, let text = item["datis"] as? String else { return nil }
            let updated = (item["updatedAt"] as? String).flatMap { raw -> Date? in
                // "2026-11-22T08:32:25.2719594Z": trim to milliseconds for the formatter.
                if let dot = raw.firstIndex(of: "."), let z = raw.lastIndex(of: "Z") {
                    let fraction = raw[raw.index(after: dot)..<z].prefix(3)
                    return iso.date(from: raw[..<dot] + "." + fraction + "Z")
                }
                return ISO8601DateFormatter().date(from: raw)
            }
            return ATIS(airport: airport, kind: Kind(rawValue: item["type"] as? String ?? "") ?? .combined,
                        code: item["code"] as? String ?? "", text: text, updated: updated)
        }
    }

    struct Runways: Equatable {
        var landing: [String] = []
        var departing: [String] = []
        var isEmpty: Bool { landing.isEmpty && departing.isEmpty }
    }

    /// Runways the broadcasts say are in use, matched against the airport's real runways.
    /// "RNAV X 33L, DEP 15R." gives landing 33L, departing 15R. Sentences about closures
    /// or equipment out of service are skipped.
    static func runways(in broadcasts: [ATIS], airport: Airport) -> Runways {
        var result = Runways()
        let known = Dictionary(airport.runways.map { (normalize($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
        let arrivalWords = ["LDG", "LNDG", "LANDING", "APCH", "APCHS", "APPROACH", "APPROACHES", "ILS", "RNAV", "VISUAL",
                            "VIS", "ARR", "ARRIVALS", "ARRIVING", "LOC", "RNP", "GPS"]
        let departureWords = ["DEP", "DEPG", "DEPS", "DEPARTING", "DEPARTURE", "DEPARTURES", "TKOF", "TAKEOFF"]
        let skipWords = ["CLSD", "CLOSED", "OTS", "U/S", "UNUSABLE", "NOTAM", "NOTAMS"]

        for broadcast in broadcasts {
            for sentence in broadcast.text.uppercased().components(separatedBy: ".") {
                let words = sentence.components(separatedBy: CharacterSet(charactersIn: " ,/;"))
                    .filter { !$0.isEmpty }
                if words.contains(where: skipWords.contains) { continue }
                // Walk the sentence: runway numbers belong to whichever keyword came last.
                var mode: Kind? = broadcast.kind == .arrival ? .arrival : (broadcast.kind == .departure ? .departure : nil)
                for word in words {
                    if departureWords.contains(word) { mode = .departure; continue }
                    if arrivalWords.contains(word) { mode = .arrival; continue }
                    guard let mode, let id = known[normalize(word)] else { continue }
                    if mode == .departure {
                        if !result.departing.contains(id) { result.departing.append(id) }
                    } else if !result.landing.contains(id) {
                        result.landing.append(id)
                    }
                }
            }
        }
        return result
    }

    /// "04R", "4R" and "RY4R" all become "4R".
    private static func normalize(_ token: String) -> String {
        var t = token
        for prefix in ["RWYS", "RWY", "RY"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        while t.hasPrefix("0") && t.count > 1 { t.removeFirst() }
        return t
    }
}

/// Fetches and caches ATIS broadcasts (5 minutes per airport). Not every airport has one.
@Observable
@MainActor
final class ATISStore {
    static let shared = ATISStore()

    private(set) var broadcasts: [String: [ATIS]] = [:]
    @ObservationIgnored private var fetched: [String: Date] = [:]

    func atis(_ icao: String) -> [ATIS] { broadcasts[icao] ?? [] }

    func refresh(_ icao: String) async {
        if let last = fetched[icao], Date().timeIntervalSince(last) < 300 { return }
        fetched[icao] = Date()
        guard let url = URL(string: "https://atis.info/api/\(icao)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = ATIS.parse(data).filter { $0.airport == icao }
            if parsed.isEmpty { dlog("weather", "\(icao): no ATIS (HTTP \(status))") }
            broadcasts[icao] = parsed
        } catch {
            fetched[icao] = nil
            dlog("weather", "\(icao) ATIS failed: \(error.localizedDescription)")
        }
    }
}
