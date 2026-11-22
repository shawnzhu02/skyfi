import Foundation

/// How far along its route a plane is: "BOS → LAX", 38% flown, 1,620 nm to go.
struct FlightProgress: Equatable {
    let from: Airport
    let to: Airport
    /// 0...1 of the great-circle leg.
    let fraction: Double
    let remainingNM: Double

    /// `route` is RouteLookup's "BOS → ORD → LAX". For a multi-leg route, the leg the plane is
    /// closest to flying (smallest detour from the straight line) wins.
    static func from(route: String, plane: Plane, index: AirportIndex = .shared) -> FlightProgress? {
        // Every stop must be known: dropping one would invent a leg that isn't flown.
        let resolved = route.components(separatedBy: "→")
            .map { index.airport(code: $0.trimmingCharacters(in: .whitespaces)) }
        guard resolved.count >= 2, !resolved.contains(where: { $0 == nil }) else { return nil }
        let stops = resolved.compactMap { $0 }
        var best: (from: Airport, to: Airport, detour: Double)?
        for (a, b) in zip(stops, stops.dropFirst()) {
            let leg = Geo.distanceNM(a.lat, a.lon, b.lat, b.lon)
            guard leg > 1 else { continue }
            let detour = Geo.distanceNM(a.lat, a.lon, plane.lat, plane.lon)
                + Geo.distanceNM(plane.lat, plane.lon, b.lat, b.lon) - leg
            if detour < (best?.detour ?? .infinity) { best = (a, b, detour) }
        }
        guard let best else { return nil }
        let flown = Geo.distanceNM(best.from.lat, best.from.lon, plane.lat, plane.lon)
        let remaining = Geo.distanceNM(plane.lat, plane.lon, best.to.lat, best.to.lon)
        guard flown + remaining > 0 else { return nil }
        return FlightProgress(from: best.from, to: best.to,
                              fraction: min(1, max(0, flown / (flown + remaining))),
                              remainingNM: remaining)
    }
}
