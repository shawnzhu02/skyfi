import Foundation

/// Which controller a plane near the connected airport is most likely talking to, the way a
/// listener would guess it: on the field = ground, low and close = tower, climbing out =
/// departure, otherwise approach, and high or far = center.
enum LikelyFacility: String, Equatable {
    case ground = "GND"
    case tower = "TWR"
    case departure = "DEP"
    case approach = "APP"
    case center = "CTR"

    var label: String {
        switch self {
        case .ground: return "Ground"
        case .tower: return "Tower"
        case .departure: return "Departure"
        case .approach: return "Approach"
        case .center: return "Center"
        }
    }

    static func guess(_ plane: Plane, airport: Airport) -> LikelyFacility? {
        let distance = Geo.distanceNM(plane.lat, plane.lon, airport.lat, airport.lon)
        if plane.onGround {
            return TrafficStore.onField(plane, airport) ? .ground : nil
        }
        let agl = (plane.altitude ?? airport.elev) - airport.elev
        if distance <= 8, agl <= 3000 { return .tower }
        if distance > 60 || agl > 18000 { return .center }
        let climbing = (plane.verticalRate ?? 0) > 300
        if climbing {
            // Climbing away from the field: departure. Climbing toward it (a go-around, a hop) stays approach.
            if let track = plane.track {
                let fromAirport = Geo.bearing(airport.lat, airport.lon, plane.lat, plane.lon)
                if Geo.angleDifference(track, fromAirport) < 90 { return .departure }
            } else {
                return .departure
            }
        }
        return .approach
    }
}
