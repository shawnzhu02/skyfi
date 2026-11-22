import Foundation
import Observation

enum FlightCategory: String, Equatable {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"

    /// FAA rules: ceiling (lowest broken/overcast layer) and visibility in statute miles.
    static func from(ceiling: Int?, visibility: Double?) -> FlightCategory {
        let ceiling = ceiling ?? .max
        let visibility = visibility ?? .infinity
        if ceiling < 500 || visibility < 1 { return .lifr }
        if ceiling < 1000 || visibility < 3 { return .ifr }
        if ceiling <= 3000 || visibility <= 5 { return .mvfr }
        return .vfr
    }
}

/// One airport weather report, from aviationweather.gov's free data API.
struct METAR: Equatable {
    let station: String
    let raw: String
    let observed: Date?
    /// True degrees; nil when calm or variable.
    let windDirection: Int?
    let windVariable: Bool
    let windSpeed: Int
    let gust: Int?
    let visibilityMiles: Double?
    /// "10+" style reports: at least that far.
    let visibilityPlus: Bool
    /// Lowest broken, overcast or obscured layer, in feet above ground.
    let ceilingFeet: Int?
    let temperatureC: Double?
    let dewpointC: Double?
    let altimeterInHg: Double?
    let weather: String?
    let category: FlightCategory

    var windText: String {
        if windSpeed == 0 { return "Calm" }
        var text = windVariable || windDirection == nil ? "Variable" : String(format: "%03d°", windDirection!)
        text += " \(windSpeed) kt"
        if let gust { text += " gusting \(gust)" }
        return text
    }

    var visibilityText: String? {
        guard let miles = visibilityMiles else { return nil }
        let number = miles < 1 ? String(format: "%.2g", miles) : String(format: "%g", miles)
        return "\(number)\(visibilityPlus ? "+" : "") mi"
    }

    var ceilingText: String {
        ceilingFeet.map { "Ceiling \($0.formatted()) ft" } ?? "No ceiling"
    }

    var temperatureText: String? {
        guard let temperatureC else { return nil }
        let f = Int((temperatureC * 9 / 5 + 32).rounded())
        return "\(Int(temperatureC.rounded()))°C / \(f)°F"
    }

    /// Parses the API's JSON array. Fields arrive as numbers or strings ("VRB", "10+").
    static func parse(_ data: Data) -> [METAR] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap(parse(item:))
    }

    static func parse(item: [String: Any]) -> METAR? {
        guard let station = item["icaoId"] as? String else { return nil }
        let raw = item["rawOb"] as? String ?? ""

        var windDirection: Int?
        var windVariable = false
        if let dir = item["wdir"] as? NSNumber {
            windDirection = dir.intValue
        } else if let dir = item["wdir"] as? String {
            windVariable = dir.uppercased() == "VRB"
            windDirection = Int(dir)
        }
        let windSpeed = (item["wspd"] as? NSNumber)?.intValue ?? 0
        if windSpeed == 0 { windDirection = nil }
        let gust = (item["wgst"] as? NSNumber)?.intValue

        var visibility: Double?
        var plus = false
        if let vis = item["visib"] as? NSNumber {
            visibility = vis.doubleValue
        } else if let vis = item["visib"] as? String {
            plus = vis.hasSuffix("+")
            visibility = Double(vis.trimmingCharacters(in: CharacterSet(charactersIn: "+")))
        }

        let layers = item["clouds"] as? [[String: Any]] ?? []
        let ceiling = layers
            .filter { ["BKN", "OVC", "OVX"].contains(($0["cover"] as? String)?.uppercased() ?? "") }
            .compactMap { ($0["base"] as? NSNumber)?.intValue }
            .min()

        var altimeter = (item["altim"] as? NSNumber)?.doubleValue
        // The API reports hectopascals; older feeds used inches.
        if let value = altimeter, value > 100 { altimeter = value * 0.0295300 }

        let observed = (item["obsTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let category = (item["fltCat"] as? String).flatMap(FlightCategory.init(rawValue:))
            ?? FlightCategory.from(ceiling: ceiling, visibility: visibility)

        return METAR(station: station, raw: raw, observed: observed,
                     windDirection: windDirection, windVariable: windVariable, windSpeed: windSpeed, gust: gust,
                     visibilityMiles: visibility, visibilityPlus: plus, ceilingFeet: ceiling,
                     temperatureC: (item["temp"] as? NSNumber)?.doubleValue,
                     dewpointC: (item["dewp"] as? NSNumber)?.doubleValue,
                     altimeterInHg: altimeter,
                     weather: (item["wxString"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                     category: category)
    }
}

/// Runway guesses: what recent takeoffs and landings used, else what the wind favors.
enum RunwayGuess {
    struct Result: Equatable {
        let runways: [String]
        let fromTraffic: Bool
    }

    static func guess(airport: Airport, events: [AirportEvent], metar: METAR?, now: Date = Date()) -> Result? {
        let recent = events.filter { $0.airport == airport.icao && now.timeIntervalSince($0.time) < 30 * 60 }
        let counts = Dictionary(grouping: recent.compactMap(\.runway), by: { $0 }).mapValues(\.count)
        if !counts.isEmpty {
            let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            return Result(runways: top.prefix(3).map(\.key), fromTraffic: true)
        }
        guard let metar, let direction = metar.windDirection, metar.windSpeed >= 5, !airport.runways.isEmpty else { return nil }
        // Into the wind: the runway end whose heading is closest to where the wind comes from.
        let best = airport.runways.min {
            Geo.angleDifference($0.hdg, Double(direction)) < Geo.angleDifference($1.hdg, Double(direction))
        }!
        let parallel = airport.runways
            .filter { Geo.angleDifference($0.hdg, best.hdg) < 10 }
            .map(\.id)
            .sorted()
        return Result(runways: parallel, fromTraffic: false)
    }
}

/// Fetches and caches METARs (10 minutes per airport).
@Observable
@MainActor
final class WeatherStore {
    static let shared = WeatherStore()

    private(set) var reports: [String: METAR] = [:]
    @ObservationIgnored private var fetched: [String: Date] = [:]

    func metar(_ icao: String) -> METAR? { reports[icao] }

    /// One request for several airports (the API takes a comma list), for lists of airports.
    func refresh(many icaos: [String]) async {
        // One request holds 30; the rest wait for the next refresh.
        let due = Array(icaos.filter { fetched[$0].map { Date().timeIntervalSince($0) >= 600 } ?? true }.prefix(30))
        guard !due.isEmpty else { return }
        for icao in due { fetched[icao] = Date() }
        let ids = due.joined(separator: ",")
        guard let url = URL(string: "https://aviationweather.gov/api/data/metar?ids=\(ids)&format=json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            for report in METAR.parse(data) where due.contains(report.station) {
                reports[report.station] = report
            }
        } catch {
            for icao in due { fetched[icao] = nil }
            dlog("weather", "batch failed: \(error.localizedDescription)")
        }
    }

    func refresh(_ icao: String) async {
        if let last = fetched[icao], Date().timeIntervalSince(last) < 600 { return }
        fetched[icao] = Date()
        guard let url = URL(string: "https://aviationweather.gov/api/data/metar?ids=\(icao)&format=json") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let report = METAR.parse(data).first(where: { $0.station == icao }) else {
                dlog("weather", "\(icao): no METAR (HTTP \(status), \(data.count) bytes)")
                return
            }
            reports[icao] = report
        } catch {
            fetched[icao] = nil
            dlog("weather", "\(icao) failed: \(error.localizedDescription)")
        }
    }
}
