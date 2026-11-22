import CoreLocation
import MapKit
import Foundation

struct RunwayEnd: Decodable, Hashable {
    let id: String
    let hdg: Double
}

/// A runway between its two thresholds, for drawing ("04R/22L", width in meters).
struct RunwayStrip: Decodable, Hashable {
    let a: [Double]
    let b: [Double]
    let ids: [String]
    let w: Double

    /// The four corners in map points, `w` meters wide.
    func corners() -> [MKMapPoint]? {
        guard a.count == 2, b.count == 2 else { return nil }
        let pa = MKMapPoint(CLLocationCoordinate2D(latitude: a[0], longitude: a[1]))
        let pb = MKMapPoint(CLLocationCoordinate2D(latitude: b[0], longitude: b[1]))
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return nil }
        let half = w / 2 * MKMapPointsPerMeterAtLatitude(a[0])
        let px = -dy / length * half, py = dx / length * half
        return [MKMapPoint(x: pa.x + px, y: pa.y + py), MKMapPoint(x: pb.x + px, y: pb.y + py),
                MKMapPoint(x: pb.x - px, y: pb.y - py), MKMapPoint(x: pa.x - px, y: pa.y - py)]
    }
}

struct Airport: Decodable, Identifiable, Hashable {
    let icao: String
    let iata: String?
    let name: String
    let city: String?
    let lat: Double
    let lon: Double
    let elev: Int
    let large: Bool
    let runways: [RunwayEnd]
    /// Missing when OurAirports has no threshold positions.
    let strips: [RunwayStrip]?

    var id: String { icao }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var code: String { iata ?? icao }
}

/// The bundled airports (built by scripts/build_airports.py), bucketed by 1° cells for fast lookups.
final class AirportIndex {
    static let shared = AirportIndex(bundle: .main)

    let all: [Airport]
    private let byICAO: [String: Airport]
    private let byIATA: [String: Airport]
    private var cells: [Int: [Airport]] = [:]

    init(airports: [Airport]) {
        all = airports
        byICAO = Dictionary(airports.map { ($0.icao, $0) }, uniquingKeysWith: { first, _ in first })
        // Large airports win a shared IATA code.
        byIATA = Dictionary(airports.compactMap { a in a.iata.map { ($0.uppercased(), a) } },
                            uniquingKeysWith: { first, second in first.large || !second.large ? first : second })
        for airport in airports {
            cells[Self.cell(airport.lat, airport.lon), default: []].append(airport)
        }
    }

    convenience init(bundle: Bundle) {
        var airports: [Airport] = []
        if let url = bundle.url(forResource: "airports", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            airports = (try? JSONDecoder().decode([Airport].self, from: data)) ?? []
        }
        self.init(airports: airports)
    }

    private static func cell(_ lat: Double, _ lon: Double) -> Int {
        let la = Int(floor(lat)) + 90
        let lo = Int(floor(lon)) + 180
        return la * 1000 + lo
    }

    func airport(icao: String) -> Airport? { byICAO[icao.uppercased()] }

    /// "BOS" or "KBOS".
    func airport(code: String) -> Airport? {
        let code = code.uppercased()
        return code.count == 3 ? byIATA[code] : byICAO[code]
    }

    /// Nearest airport within `withinNM`, searching the 3×3 cells around the point.
    func nearest(lat: Double, lon: Double, withinNM: Double) -> Airport? {
        var best: (Airport, Double)?
        let la = Int(floor(lat)), lo = Int(floor(lon))
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cell(Double(la + dLat), Double(lo + dLon))
                for airport in cells[key] ?? [] {
                    let d = Geo.distanceNM(lat, lon, airport.lat, airport.lon)
                    if d <= withinNM, d < (best?.1 ?? .infinity) {
                        best = (airport, d)
                    }
                }
            }
        }
        return best?.0
    }

    /// Airports inside a lat/lon box, large ones first.
    func airports(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, includeMedium: Bool, limit: Int) -> [Airport] {
        var result: [Airport] = []
        let wraps = minLon > maxLon
        for airport in all where includeMedium || airport.large {
            guard airport.lat >= minLat, airport.lat <= maxLat else { continue }
            let inLon = wraps ? (airport.lon >= minLon || airport.lon <= maxLon)
                              : (airport.lon >= minLon && airport.lon <= maxLon)
            if inLon {
                result.append(airport)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// The runway end whose heading best matches `heading`, if within `tolerance` degrees.
    static func runwayEnd(at airport: Airport, heading: Double, tolerance: Double = 25) -> RunwayEnd? {
        let best = airport.runways.min { Geo.angleDifference($0.hdg, heading) < Geo.angleDifference($1.hdg, heading) }
        guard let best, Geo.angleDifference(best.hdg, heading) <= tolerance else { return nil }
        return best
    }
}
