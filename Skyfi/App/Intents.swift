import AppIntents
import Foundation

/// An airport with a live feed, for Siri and Shortcuts ("Connect to BOS in Skyfi").
struct AirportEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Airport"
    static var defaultQuery = AirportQuery()

    /// ICAO code.
    let id: String
    let code: String
    let name: String

    init(_ airport: Airport) {
        id = airport.icao
        code = airport.code
        name = airport.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(code)", subtitle: "\(name)")
    }
}

struct AirportQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AirportEntity] {
        identifiers.compactMap { AirportIndex.shared.airport(icao: $0) }.map(AirportEntity.init)
    }

    func entities(matching string: String) async throws -> [AirportEntity] {
        Catalog.search(string).prefix(20).map(AirportEntity.init)
    }

    /// Your starred and recent airports first, then every airport with a feed.
    func suggestedEntities() async throws -> [AirportEntity] {
        let yours = await MainActor.run { Places.shared.favorites + Places.shared.recents }
        var seen = Set<String>()
        let icaos = (yours + Catalog.connectable.sorted()).filter { seen.insert($0).inserted }
        return icaos.compactMap { AirportIndex.shared.airport(icao: $0) }
            .filter { Catalog.connectable.contains($0.icao) }
            .map(AirportEntity.init)
    }
}

struct ConnectAirportIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect to an airport"
    static var description = IntentDescription("Shows the airport's planes and opens its tower in LiveATC's player.")
    static var openAppWhenRun = true

    @Parameter(title: "Airport")
    var airport: AirportEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let match = AirportIndex.shared.airport(icao: airport.id) {
            dlog("app", "shortcut: connect \(match.icao)")
            Mixer.shared.connectViaLiveATC(match)
        }
        return .result()
    }
}

struct PauseSkyfiIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Skyfi"
    static var description = IntentDescription("Pauses the music and the tower.")

    @MainActor
    func perform() async throws -> some IntentResult {
        Mixer.shared.pause()
        return .result()
    }
}

struct AirportWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Airport weather"
    static var description = IntentDescription("Reads the airport's latest weather report (METAR) and ATIS letter.")

    @Parameter(title: "Airport")
    var airport: AirportEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let icao = airport.id
        await WeatherStore.shared.refresh(icao)
        await ATISStore.shared.refresh(icao)
        let text = Self.summary(code: airport.code, name: airport.name,
                                metar: WeatherStore.shared.metar(icao),
                                atis: ATISStore.shared.atis(icao).first?.code)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// "Boston Logan: VFR. Wind 190° 5 kt. Visibility 10+ mi. No ceiling. 8°C / 46°F. Information Kilo."
    static func summary(code: String, name: String, metar: METAR?, atis: String?) -> String {
        guard let metar else { return "No current weather report for \(code)." }
        var parts = ["\(name): \(metar.category.rawValue)", "Wind \(metar.windText)"]
        if let visibility = metar.visibilityText { parts.append("Visibility \(visibility)") }
        parts.append(metar.ceilingText)
        if let weather = metar.weather { parts.append(weather) }
        if let temperature = metar.temperatureText { parts.append(temperature) }
        if let atis, !atis.isEmpty { parts.append("Information \(atis)") }
        return parts.joined(separator: ". ") + "."
    }
}

struct SkyfiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectAirportIntent(),
                    phrases: ["Connect to \(\.$airport) in \(.applicationName)",
                              "Listen to \(\.$airport) in \(.applicationName)"],
                    shortTitle: "Connect to airport",
                    systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: AirportWeatherIntent(),
                    phrases: ["Weather at \(\.$airport) in \(.applicationName)",
                              "\(.applicationName) weather at \(\.$airport)"],
                    shortTitle: "Airport weather",
                    systemImageName: "cloud.sun")
        AppShortcut(intent: PauseSkyfiIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause",
                    systemImageName: "pause.fill")
    }
}

/// skyfi://connect/KBOS (or BOS) connects to that airport.
enum SkyfiLink {
    static func airport(from url: URL) -> Airport? {
        guard url.scheme == "skyfi", url.host == "connect" else { return nil }
        let code = url.lastPathComponent.uppercased()
        let index = AirportIndex.shared
        return index.airport(icao: code)
            ?? Catalog.search(code).first(where: { $0.iata?.uppercased() == code || $0.icao == code })
    }
}
