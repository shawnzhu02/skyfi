import Foundation

struct AirportEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case departure
        case arrival
    }

    let id = UUID()
    let kind: Kind
    let planeID: String
    let callsign: String
    let type: String?
    let airport: String
    let airportCode: String
    let runway: String?
    let time: Date

    var verb: String { kind == .departure ? "departed" : "landed" }

    var text: String {
        var line = "\(callsign) \(verb) \(airportCode)"
        if let runway { line += " \(runway)" }
        return line
    }
}

/// Turns a plane's ground/air change near an airport into a takeoff or landing.
enum EventDetector {
    static let airportRadiusNM = 4.0
    /// Ignore ground-flag flicker high above the field.
    static let maxHeightAboveField = 3000

    static func detect(previous: Plane, current: Plane, index: AirportIndex) -> AirportEvent? {
        guard previous.onGround != current.onGround else { return nil }
        let kind: AirportEvent.Kind = previous.onGround ? .departure : .arrival
        let airborne = kind == .departure ? current : previous

        guard let airport = index.nearest(lat: current.lat, lon: current.lon, withinNM: airportRadiusNM)
                ?? index.nearest(lat: previous.lat, lon: previous.lon, withinNM: airportRadiusNM) else { return nil }

        if let altitude = airborne.altitude, altitude - airport.elev > maxHeightAboveField { return nil }
        // Fast-moving only: taxiing planes and helicopters flicker the ground flag at low speed.
        guard (airborne.groundSpeed ?? 0) >= 50 else { return nil }

        let heading = airborne.track ?? current.track ?? previous.track
        let runway = heading.flatMap { AirportIndex.runwayEnd(at: airport, heading: $0)?.id }
        return AirportEvent(kind: kind, planeID: current.id, callsign: current.title, type: current.type,
                            airport: airport.icao, airportCode: airport.code, runway: runway, time: current.lastSeen)
    }

    /// Airborne, descending, within 30 nm and pointed at the airport.
    /// Rough minutes to touchdown for a plane on approach: straight-line distance over ground speed,
    /// plus a minute for the slowdown on final. nil when it isn't moving.
    static func minutesToLanding(_ plane: Plane, at airport: Airport) -> Int? {
        guard let speed = plane.groundSpeed, speed > 60 else { return nil }
        let distance = Geo.distanceNM(plane.lat, plane.lon, airport.lat, airport.lon)
        return max(1, Int((distance / speed * 60 + 1).rounded()))
    }

    static func isApproaching(_ plane: Plane, to airport: Airport) -> Bool {
        guard !plane.onGround, let altitude = plane.altitude, let track = plane.track else { return false }
        let distance = Geo.distanceNM(plane.lat, plane.lon, airport.lat, airport.lon)
        guard distance < 30, altitude - airport.elev < 9000, (plane.verticalRate ?? 0) < -250 else { return false }
        let toAirport = Geo.bearing(plane.lat, plane.lon, airport.lat, airport.lon)
        return Geo.angleDifference(track, toAirport) < 35
    }
}
