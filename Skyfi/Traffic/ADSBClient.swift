import Foundation

/// Fetches live aircraft around a point. adsb.lol first, adsb.fi as fallback.
/// Both are free community feeds for non-commercial use, with a 250 nm cap per query.
struct ADSBClient {
    enum Provider: String, CaseIterable {
        case adsbLol = "adsb.lol"
        case adsbFi = "adsb.fi"

        func url(lat: Double, lon: Double, radiusNM: Int) -> URL {
            let la = String(format: "%.4f", lat), lo = String(format: "%.4f", lon)
            switch self {
            case .adsbLol:
                return URL(string: "https://api.adsb.lol/v2/point/\(la)/\(lo)/\(radiusNM)")!
            case .adsbFi:
                return URL(string: "https://opendata.adsb.fi/api/v3/lat/\(la)/lon/\(lo)/dist/\(radiusNM)")!
            }
        }
    }

    enum FetchError: Error {
        case status(Int)
    }

    static let maxRadiusNM = 250

    var session: URLSession = .shared

    func fetch(lat: Double, lon: Double, radiusNM: Int, provider: Provider) async throws -> [ADSBAircraft] {
        let radius = min(max(radiusNM, 5), Self.maxRadiusNM)
        var request = URLRequest(url: provider.url(lat: lat, lon: lon, radiusNM: radius))
        request.timeoutInterval = 10
        request.setValue("Skyfi/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.status(http.statusCode)
        }
        return try JSONDecoder().decode(ADSBResponse.self, from: data).all
    }
}

/// Best-effort origin/destination lookup through adsb.lol's route set API.
actor RouteLookup {
    static let shared = RouteLookup()

    private var cache: [String: String?] = [:]

    func route(callsign: String, lat: Double, lon: Double) async -> String? {
        if let cached = cache[callsign] { return cached }
        var request = URLRequest(url: URL(string: "https://api.adsb.lol/api/0/routeset")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["planes": [["callsign": callsign, "lat": lat, "lng": lon]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var result: String?
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = list.first {
            let codes = (first["_airport_codes_iata"] as? String) ?? (first["airport_codes"] as? String)
            if let codes, !codes.isEmpty, codes.lowercased() != "unknown" {
                result = codes.replacingOccurrences(of: "-", with: " → ")
            }
        }
        cache[callsign] = result
        return result
    }
}
