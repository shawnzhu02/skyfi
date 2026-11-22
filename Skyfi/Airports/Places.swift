import Foundation
import Observation

/// Your starred airports and the last ones you connected to, kept on the phone.
@Observable
@MainActor
final class Places {
    static let shared = Places()
    static let maxRecents = 5

    private(set) var favorites: [String]
    private(set) var recents: [String]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = defaults.stringArray(forKey: "favoriteAirports") ?? []
        recents = defaults.stringArray(forKey: "recentAirports") ?? []
    }

    func isFavorite(_ icao: String) -> Bool { favorites.contains(icao) }

    func toggleFavorite(_ icao: String) {
        if let index = favorites.firstIndex(of: icao) {
            favorites.remove(at: index)
        } else {
            favorites.append(icao)
        }
        defaults.set(favorites, forKey: "favoriteAirports")
    }

    func noteConnected(_ icao: String) {
        recents.removeAll { $0 == icao }
        recents.insert(icao, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        defaults.set(recents, forKey: "recentAirports")
    }
}

extension Catalog {
    /// Connectable airports matching a search: code matches first, then name and city.
    static func search(_ query: String, index: AirportIndex = .shared) -> [Airport] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let airports = connectable.compactMap { index.airport(icao: $0) }
        func rank(_ airport: Airport) -> Int? {
            let codes = [airport.icao.lowercased(), airport.iata?.lowercased()].compactMap { $0 }
            if codes.contains(q) { return 0 }
            if codes.contains(where: { $0.hasPrefix(q) }) { return 1 }
            let words = [airport.name, airport.city ?? ""].joined(separator: " ").lowercased()
            if words.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
            if words.contains(q) { return 3 }
            return nil
        }
        return airports
            .compactMap { airport in rank(airport).map { (airport, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.icao < $1.0.icao }
            .map(\.0)
    }
}
