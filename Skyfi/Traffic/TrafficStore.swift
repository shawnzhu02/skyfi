import CoreLocation
import Foundation
import Observation

/// The live traffic picture: polls the ADS-B feeds around the major airports in view
/// (not the whole map, to keep requests small), merges planes by ICAO hex, and turns
/// ground/air changes into airport events.
@Observable
@MainActor
final class TrafficStore {
    struct Tile: Hashable {
        let lat: Double
        let lon: Double
        let radiusNM: Int
    }

    private(set) var planes: [String: Plane] = [:]
    private(set) var events: [AirportEvent] = []
    private(set) var lastUpdate: Date?
    private(set) var provider: ADSBClient.Provider = .adsbLol
    private(set) var failing = false
    /// True when more major airports are in view than Skyfi polls at once.
    private(set) var limitedCoverage = false
    /// False when no major airport is in view, so no planes are shown.
    private(set) var watchingAirports = true

    @ObservationIgnored private var tiles: [Tile] = []
    @ObservationIgnored private var tileFetched: [Tile: Date] = [:]
    @ObservationIgnored private var nextTile = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var recentEventKeys: [String: Date] = [:]
    @ObservationIgnored private let client = ADSBClient()
    @ObservationIgnored private let index: AirportIndex
    @ObservationIgnored private var errorsInRow = 0

    /// Covers final approach, the initial climb and the 30 nm "approaching" window.
    nonisolated static let airportRadiusNM = 30
    /// Airports this close share one query circle (JFK, LGA and EWR are one).
    nonisolated static let mergeNM = 25.0
    nonisolated static let maxTiles = 8
    static let requestGap: Duration = .milliseconds(1200)
    static let minTileAge: TimeInterval = 5
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
            if let tile = dueTile() {
                await poll(tile)
                try? await Task.sleep(for: errorsInRow > 2 ? .seconds(5) : Self.requestGap)
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func dueTile() -> Tile? {
        guard !tiles.isEmpty else { return nil }
        let now = Date()
        for step in 0..<tiles.count {
            let i = (nextTile + step) % tiles.count
            if now.timeIntervalSince(tileFetched[tiles[i]] ?? .distantPast) >= Self.minTileAge {
                nextTile = (i + 1) % tiles.count
                return tiles[i]
            }
        }
        return nil
    }

    private func poll(_ tile: Tile) async {
        do {
            let aircraft = try await client.fetch(lat: tile.lat, lon: tile.lon, radiusNM: tile.radiusNM, provider: provider)
            guard tiles.contains(tile) else { return }
            tileFetched[tile] = Date()
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
        let (newTiles, limited) = Self.makeTiles(center: center, latDelta: latDelta, lonDelta: lonDelta, index: index)
        limitedCoverage = limited
        watchingAirports = !newTiles.isEmpty
        guard newTiles != tiles else { return }
        tiles = newTiles
        // Keep fetch times for airports still in view, so panning doesn't refetch them.
        tileFetched = tileFetched.filter { newTiles.contains($0.key) }
        nextTile = 0
        // Planes near airports that left the view go now, not after the 60 s stale timeout.
        planes = planes.filter { Self.covered(lat: $0.value.lat, lon: $0.value.lon, by: newTiles) }
    }

    nonisolated static func covered(lat: Double, lon: Double, by tiles: [Tile]) -> Bool {
        tiles.contains { Geo.distanceNM(lat, lon, $0.lat, $0.lon) <= Double($0.radiusNM) + 5 }
    }

    /// One 30 nm query circle per major airport in view, nearest the middle first; airports within
    /// 25 nm of one already chosen widen that circle instead. Beyond 8 circles the rest wait for a zoom.
    nonisolated static func makeTiles(center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double,
                                      index: AirportIndex) -> ([Tile], Bool) {
        let halfLat = min(latDelta, 170) / 2
        let lonSpan = min(lonDelta, 360)
        let wrap = { (lon: Double) in (lon + 540).truncatingRemainder(dividingBy: 360) - 180 }
        let minLon = lonSpan >= 359 ? -180 : wrap(center.longitude - lonSpan / 2)
        let maxLon = lonSpan >= 359 ? 180 : wrap(center.longitude + lonSpan / 2)
        let airports = index.airports(minLat: max(center.latitude - halfLat, -90), maxLat: min(center.latitude + halfLat, 90),
                                      minLon: minLon, maxLon: maxLon, includeMedium: false, limit: 5000)
            .map { ($0, Geo.distanceNM($0.lat, $0.lon, center.latitude, center.longitude)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        var tiles: [Tile] = []
        for airport in airports {
            if let i = tiles.firstIndex(where: { Geo.distanceNM($0.lat, $0.lon, airport.lat, airport.lon) <= mergeNM }) {
                let need = Int((Geo.distanceNM(tiles[i].lat, tiles[i].lon, airport.lat, airport.lon) + Double(airportRadiusNM)).rounded(.up))
                if need > tiles[i].radiusNM {
                    tiles[i] = Tile(lat: tiles[i].lat, lon: tiles[i].lon, radiusNM: min(need, 60))
                }
                continue
            }
            if tiles.count == maxTiles { return (tiles, true) }
            tiles.append(Tile(lat: airport.lat, lon: airport.lon, radiusNM: airportRadiusNM))
        }
        return (tiles, false)
    }

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
