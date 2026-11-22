import CoreLocation
import Foundation
import Observation

/// The live traffic picture for the airport you're connected to: polls one 60 nm circle
/// around it, keeps the planes its tower, approach or departure could be talking to,
/// and turns ground/air changes into takeoff and landing events. Nothing is polled
/// until you connect.
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
    /// The airport whose planes are shown, or nil (no planes, no requests).
    private(set) var connected: Airport?
    /// Where each plane has been since it showed up (newest last), for the selected plane's trail.
    @ObservationIgnored private(set) var trails: [String: [CLLocationCoordinate2D]] = [:]
    static let maxTrailPoints = 240
    @ObservationIgnored private var trailTimes: [String: Date] = [:]

    /// The squawking plane to show, worst first (hijack, then emergency, then radio failure), steady across updates.
    var emergencyPlane: Plane? {
        let rank = ["7500": 0, "7700": 1, "7600": 2]
        return planes.values
            .filter { $0.emergency != nil }
            .min { (rank[$0.squawk ?? ""] ?? 9, $0.id) < (rank[$1.squawk ?? ""] ?? 9, $1.id) }
    }

    func trail(_ planeID: String?) -> [CLLocationCoordinate2D] {
        planeID.flatMap { trails[$0] } ?? []
    }

    @ObservationIgnored private var tiles: [Tile] = []
    @ObservationIgnored private var tileFetched: [Tile: Date] = [:]
    @ObservationIgnored private var nextTile = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var recentEventKeys: [String: Date] = [:]
    @ObservationIgnored private let client = ADSBClient()
    @ObservationIgnored private let index: AirportIndex
    @ObservationIgnored private var errorsInRow = 0

    /// Roughly where an airport's approach and departure controllers work.
    nonisolated static let rangeNM = 60
    /// Above this the plane is with Center, not the airport's controllers.
    nonisolated static let maxAGL = 18_000
    /// Big fields (Denver's runways end 3.5 nm out) need room; `onField` then checks it's this airport.
    nonisolated static let groundNM = 5.0
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
            if errorsInRow <= 2 || errorsInRow % 10 == 0 {
                dlog("adsb", "\(provider) poll failed (\(errorsInRow) in a row): \(error)")
            }
            if errorsInRow >= 2 {
                // Switch provider after two failures in a row.
                let all = ADSBClient.Provider.allCases
                provider = all[(all.firstIndex(of: provider)! + 1) % all.count]
                failing = errorsInRow >= 4
            }
        }
    }

    /// Connects to an airport (or disconnects with nil). Only this airport is polled.
    func connect(_ airport: Airport?) {
        guard airport?.icao != connected?.icao else { return }
        connected = airport
        tiles = airport.map { [Tile(lat: $0.lat, lon: $0.lon, radiusNM: Self.rangeNM)] } ?? []
        tileFetched = [:]
        nextTile = 0
        planes = [:]
        trails = [:]
        trailTimes = [:]
        errorsInRow = 0
        failing = false
    }

    /// Planes the airport's tower, approach or departure could be talking to: on the ground at the
    /// airport, or in the air within 60 nm and below 18,000 ft above it. Unknown altitude is kept.
    nonisolated static func inRange(_ plane: Plane, of airport: Airport) -> Bool {
        let distance = Geo.distanceNM(plane.lat, plane.lon, airport.lat, airport.lon)
        if plane.onGround { return onField(plane, airport) }
        guard distance <= Double(rangeNM) else { return false }
        guard let altitude = plane.altitude else { return true }
        return altitude - airport.elev <= maxAGL
    }

    /// On the ground at this airport rather than at a neighbouring field: within 5 nm and
    /// this is the nearest airport (small fields included).
    nonisolated static func onField(_ plane: Plane, _ airport: Airport, index: AirportIndex = .shared) -> Bool {
        guard plane.onGround, Geo.distanceNM(plane.lat, plane.lon, airport.lat, airport.lon) <= groundNM else { return false }
        return index.nearest(lat: plane.lat, lon: plane.lon, withinNM: groundNM)?.icao == airport.icao
    }

    // MARK: Merge

    func merge(_ aircraft: [ADSBAircraft], now: Date) {
        var updated = planes
        for a in aircraft {
            guard var plane = Plane(a, now: now) else { continue }
            if let connected, !Self.inRange(plane, of: connected) {
                // Left the airport's airspace (or never in it): drop it from the picture.
                updated[plane.id] = nil
                continue
            }
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
            addTrailPoint(plane)
        }
        updated = updated.filter { now.timeIntervalSince($0.value.lastSeen) < Self.staleAfter }
        if trails.count > updated.count {
            trails = trails.filter { updated[$0.key] != nil }
            trailTimes = trailTimes.filter { updated[$0.key] != nil }
        }
        planes = updated
        lastUpdate = now
    }

    private func addTrailPoint(_ plane: Plane) {
        // Lost for a while (out of range, no reports): start over rather than draw a line across the gap.
        // Compared with the last report, not the last point, so a plane parked for a while keeps its trail.
        if let last = trailTimes[plane.id], plane.fixTime.timeIntervalSince(last) > 60 { trails[plane.id] = nil }
        trailTimes[plane.id] = plane.fixTime
        if let last = trails[plane.id]?.last,
           Geo.distanceNM(last.latitude, last.longitude, plane.lat, plane.lon) < 0.05 { return }
        // Appends in place (no copy of the array per point).
        trails[plane.id, default: []].append(CLLocationCoordinate2D(latitude: plane.lat, longitude: plane.lon))
        if let count = trails[plane.id]?.count, count > Self.maxTrailPoints {
            trails[plane.id]?.removeFirst(count - Self.maxTrailPoints)
        }
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
