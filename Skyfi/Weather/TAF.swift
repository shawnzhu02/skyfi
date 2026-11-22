import Foundation
import Observation

/// An airport's forecast (TAF), from aviationweather.gov: when the weather is expected to change.
struct TAF: Equatable {
    struct Period: Equatable {
        let from: Date
        let to: Date
        /// nil or "FM" for a new base period; "TEMPO", "BECMG" or "PROB" for a temporary or gradual change.
        let change: String?
        let probability: Int?
        /// The period's weather, decoded like a METAR (wind, visibility, ceiling, category).
        let weather: METAR

        var isTemporary: Bool { change == "TEMPO" || change == "PROB" }
        /// TEMPO and PROB lines often give only what changes, so their category means little alone.
        var hasCategoryFields: Bool { weather.visibilityMiles != nil || weather.ceilingFeet != nil }
    }

    let station: String
    let raw: String
    let periods: [Period]

    static func parse(_ data: Data) -> [TAF] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let station = item["icaoId"] as? String else { return nil }
            let periods = (item["fcsts"] as? [[String: Any]] ?? []).compactMap { fcst -> Period? in
                guard let from = (fcst["timeFrom"] as? NSNumber)?.doubleValue,
                      let to = (fcst["timeTo"] as? NSNumber)?.doubleValue else { return nil }
                var fields = fcst
                fields["icaoId"] = station
                fields["fltCat"] = nil
                guard let weather = METAR.parse(item: fields) else { return nil }
                return Period(from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to),
                              change: (fcst["fcstChange"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() },
                              probability: (fcst["probability"] as? NSNumber)?.intValue,
                              weather: weather)
            }
            return TAF(station: station, raw: item["rawTAF"] as? String ?? "", periods: periods)
        }
    }

    /// Periods that haven't ended, within the next `hours`.
    func upcoming(now: Date = Date(), hours: Double = 24) -> [Period] {
        periods.filter { $0.to > now && $0.from < now.addingTimeInterval(hours * 3600) }
    }
}

/// Fetches and caches forecasts (30 minutes per airport; TAFs are issued every 6 hours).
@Observable
@MainActor
final class TAFStore {
    static let shared = TAFStore()

    private(set) var forecasts: [String: TAF] = [:]
    @ObservationIgnored private var fetched: [String: Date] = [:]

    func taf(_ icao: String) -> TAF? { forecasts[icao] }

    func refresh(_ icao: String) async {
        if let last = fetched[icao], Date().timeIntervalSince(last) < 1800 { return }
        fetched[icao] = Date()
        guard let url = URL(string: "https://aviationweather.gov/api/data/taf?ids=\(icao)&format=json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            forecasts[icao] = TAF.parse(data).first { $0.station == icao }
        } catch {
            fetched[icao] = nil
            dlog("weather", "\(icao) TAF failed: \(error.localizedDescription)")
        }
    }
}
