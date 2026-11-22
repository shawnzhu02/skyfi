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
            Mixer.shared.connect(match)
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

struct SkyfiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectAirportIntent(),
                    phrases: ["Connect to \(\.$airport) in \(.applicationName)",
                              "Listen to \(\.$airport) in \(.applicationName)"],
                    shortTitle: "Connect to airport",
                    systemImageName: "antenna.radiowaves.left.and.right")
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
