import CoreLocation
import Foundation
import Observation

/// The live traffic picture: polls the ADS-B feeds for the visible map area,
/// merges planes by ICAO hex, and turns ground/air changes into airport events.
@Observable
@MainActor
final class TrafficStore {
    struct Tile: Equatable {
        let lat: Double
        let lon: Double
        let radiusNM: Int
    }

    private(set) var planes: [String: Plane] = [:]
    private(set) var events: [AirportEvent] = []
    private(set) var lastUpdate: Date?
    private(set) var provider: ADSBClient.Provider = .adsbLol
    private(set) var failing = false
    /// True when the visible area is bigger than the tiles Skyfi polls.
    private(set) var limitedCoverage = false

    @ObservationIgnored private var tiles: [Tile] = []
    @ObservationIgnored private var visibleTiles: [Tile] = []
    @ObservationIgnored private var pinnedTile: Tile?
    @ObservationIgnored private var tileFetched: [Int: Date] = [:]
    @ObservationIgnored private var nextTile = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var recentEventKeys: [String: Date] = [:]
    @ObservationIgnored private let client = ADSBClient()
    @ObservationIgnored private let index: AirportIndex
    @ObservationIgnored private var errorsInRow = 0

    nonisolated static let tileSpacingNM = 350.0
    nonisolated static let maxTiles = 9
    static let requestGap: Duration = .milliseconds(1200)
    static let minTileAge: TimeInterval = 4
    static let staleAfter: TimeInterval = 60

    init(index: AirportIndex = .shared) {
        self.index = index
    }

    // MARK: Polling

    func setActive(_ active: Bool) {
        if active {
            guard loop == nil else { return }
            loop = Task { [weak self] in await self?.run() }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    private func run() async {
        while !Task.isCancelled {
            if let due = dueTile() {
                await poll(due.tile, index: due.index)
                try? await Task.sleep(for: errorsInRow > 2 ? .seconds(5) : Self.requestGap)
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func dueTile() -> (index: Int, tile: Tile)? {
        guard !tiles.isEmpty else { return nil }
        let now = Date()
        for step in 0..<tiles.count {
            let i = (nextTile + step) % tiles.count
            if now.timeIntervalSince(tileFetched[i] ?? .distantPast) >= Self.minTileAge {
                nextTile = (i + 1) % tiles.count
                return (i, tiles[i])
            }
        }
        return nil
    }

    private func poll(_ tile: Tile, index i: Int) async {
        do {
            let aircraft = try await client.fetch(lat: tile.lat, lon: tile.lon, radiusNM: tile.radiusNM, provider: provider)
            tileFetched[i] = Date()
            errorsInRow = 0
            failing = false
            merge(aircraft, now: Date())
        } catch {
            errorsInRow += 1
            if errorsInRow >= 2 {
                // Switch provider after two failures in a row.
                let all = ADSBClient.Provider.allCases
                provider = all[(all.firstIndex(of: provider)! + 1) % all.count]
                failing = errorsInRow >= 4
            }
        }
    }

    /// Called by the globe whenever the visible region settles.
    func setVisibleRegion(center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double) {
        let (newTiles, limited) = Self.makeTiles(center: center, latDelta: latDelta, lonDelta: lonDelta)
        limitedCoverage = limited
        visibleTiles = newTiles
        rebuildTiles()
    }

    /// Keeps polling around the tuned tower's airport, so "who's talking" has its planes
    /// even when the map is looking somewhere else.
    func setPinned(_ airport: Airport?) {
        pinnedTile = airport.map { Tile(lat: $0.lat, lon: $0.lon, radiusNM: 60) }
        rebuildTiles()
    }

    private func rebuildTiles() {
        var newTiles = visibleTiles
        if let pinned = pinnedTile, !newTiles.contains(where: {
            Geo.distanceNM($0.lat, $0.lon, pinned.lat, pinned.lon) + Double(pinned.radiusNM) <= Double($0.radiusNM)
        }) {
            newTiles.append(pinned)
        }
        guard newTiles != tiles else { return }
        tiles = newTiles
        tileFetched = [:]
        nextTile = 0
    }

    /// Splits the visible area into ≤250 nm query circles. Beyond 9 circles only the middle ones are polled.
    nonisolated static func makeTiles(center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double) -> ([Tile], Bool) {
        let heightNM = min(latDelta, 170) * 60
        let widthNM = min(lonDelta, 360) * 60 * max(cos(center.latitude * .pi / 180), 0.1)
        let halfDiagonal = sqrt(heightNM * heightNM + widthNM * widthNM) / 2
        if halfDiagonal <= Double(ADSBClient.maxRadiusNM) {
            let radius = Int(max(halfDiagonal, 20).rounded(.up))
            return ([Tile(lat: rounded(center.latitude), lon: rounded(center.longitude), radiusNM: radius)], false)
        }
        var rows = Int((heightNM / tileSpacingNM).rounded(.up))
        var cols = Int((widthNM / tileSpacingNM).rounded(.up))
        let limited = rows * cols > maxTiles
        rows = min(rows, 3)
        cols = min(cols, 3)
        var result: [Tile] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let north = (Double(r) - Double(rows - 1) / 2) * tileSpacingNM
                let east = (Double(c) - Double(cols - 1) / 2) * tileSpacingNM
                let lat = max(min(center.latitude + north / 60, 85), -85)
                let lon = center.longitude + east / (60 * max(cos(lat * .pi / 180), 0.1))
                let wrapped = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
                result.append(Tile(lat: rounded(lat), lon: rounded(wrapped), radiusNM: ADSBClient.maxRadiusNM))
            }
        }
        // Poll the middle first.
        result.sort {
            Geo.distanceNM($0.lat, $0.lon, center.latitude, center.longitude)
                < Geo.distanceNM($1.lat, $1.lon, center.latitude, center.longitude)
        }
        return (result, limited)
    }

    /// Rounding keeps tiles stable while the map moves a little.
    nonisolated private static func rounded(_ value: Double) -> Double { (value * 4).rounded() / 4 }

    // MARK: Merge

    func merge(_ aircraft: [ADSBAircraft], now: Date) {
        var updated = planes
        for a in aircraft {
            guard var plane = Plane(a, now: now) else { continue }
            if let previous = updated[plane.id] {
                // Keep fields a partial report leaves out.
                plane.callsign = plane.callsign ?? previous.callsign
                plane.type = plane.type ?? previous.type
                plane.typeName = plane.typeName ?? previous.typeName
                plane.operatorName = plane.operatorName ?? previous.operatorName
                plane.registration = plane.registration ?? previous.registration
                if plane.fixTime < previous.fixTime { continue }
                if let event = EventDetector.detect(previous: previous, current: plane, index: index) {
                    record(event)
                }
            }
            updated[plane.id] = plane
        }
        updated = updated.filter { now.timeIntervalSince($0.value.lastSeen) < Self.staleAfter }
        planes = updated
        lastUpdate = now
    }

    private func record(_ event: AirportEvent) {
        let key = "\(event.planeID)-\(event.kind)"
        if let last = recentEventKeys[key], event.time.timeIntervalSince(last) < 300 { return }
        recentEventKeys[key] = event.time
        events.insert(event, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
        if recentEventKeys.count > 2000 {
            recentEventKeys = recentEventKeys.filter { event.time.timeIntervalSince($0.value) < 300 }
        }
    }

    // MARK: Queries

    func events(at airport: Airport) -> [AirportEvent] {
        events.filter { $0.airport == airport.icao }
    }

    func approaching(_ airport: Airport) -> [Plane] {
        planes.values.filter { EventDetector.isApproaching($0, to: airport) }
            .sorted { Geo.distanceNM($0.lat, $0.lon, airport.lat, airport.lon) < Geo.distanceNM($1.lat, $1.lon, airport.lat, airport.lon) }
    }

    func onGround(at airport: Airport) -> [Plane] {
        planes.values.filter { $0.onGround && Geo.distanceNM($0.lat, $0.lon, airport.lat, airport.lon) < 3 }
    }
}
