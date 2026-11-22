import CoreLocation
import Foundation

/// One aircraft as the readsb-style APIs (adsb.lol, adsb.fi) return it.
struct ADSBAircraft: Decodable, Equatable {
    enum Altitude: Decodable, Equatable {
        case ground
        case feet(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if text.lowercased() == "ground" {
                    self = .ground
                } else if let value = Double(text) {
                    self = .feet(Int(value))
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown altitude \(text)")
                }
            } else {
                self = .feet(Int(try container.decode(Double.self)))
            }
        }
    }

    let hex: String
    let flight: String?
    let registration: String?
    let type: String?
    let typeName: String?
    let operatorName: String?
    let lat: Double?
    let lon: Double?
    let altBaro: Altitude?
    let altGeom: Double?
    let groundSpeed: Double?
    let track: Double?
    let trueHeading: Double?
    let baroRate: Double?
    let geomRate: Double?
    let squawk: String?
    let category: String?
    let seenPos: Double?
    let seen: Double?

    enum CodingKeys: String, CodingKey {
        case hex, flight, lat, lon, track, squawk, category, seen
        case registration = "r"
        case type = "t"
        case typeName = "desc"
        case operatorName = "ownOp"
        case altBaro = "alt_baro"
        case altGeom = "alt_geom"
        case groundSpeed = "gs"
        case trueHeading = "true_heading"
        case baroRate = "baro_rate"
        case geomRate = "geom_rate"
        case seenPos = "seen_pos"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hex = try c.decode(String.self, forKey: .hex)
        flight = try? c.decodeIfPresent(String.self, forKey: .flight)
        registration = try? c.decodeIfPresent(String.self, forKey: .registration)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        typeName = try? c.decodeIfPresent(String.self, forKey: .typeName)
        operatorName = try? c.decodeIfPresent(String.self, forKey: .operatorName)
        lat = try? c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try? c.decodeIfPresent(Double.self, forKey: .lon)
        altBaro = try? c.decodeIfPresent(Altitude.self, forKey: .altBaro)
        altGeom = try? c.decodeIfPresent(Double.self, forKey: .altGeom)
        groundSpeed = try? c.decodeIfPresent(Double.self, forKey: .groundSpeed)
        track = try? c.decodeIfPresent(Double.self, forKey: .track)
        trueHeading = try? c.decodeIfPresent(Double.self, forKey: .trueHeading)
        baroRate = try? c.decodeIfPresent(Double.self, forKey: .baroRate)
        geomRate = try? c.decodeIfPresent(Double.self, forKey: .geomRate)
        squawk = try? c.decodeIfPresent(String.self, forKey: .squawk)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        seenPos = try? c.decodeIfPresent(Double.self, forKey: .seenPos)
        seen = try? c.decodeIfPresent(Double.self, forKey: .seen)
    }
}

struct ADSBResponse: Decodable {
    let ac: [ADSBAircraft]?
    let aircraft: [ADSBAircraft]?

    var all: [ADSBAircraft] { ac ?? aircraft ?? [] }
}

/// A plane as Skyfi tracks it between polls.
struct Plane: Identifiable, Equatable {
    let id: String
    var callsign: String?
    var registration: String?
    var type: String?
    var typeName: String?
    var operatorName: String?
    var lat: Double
    var lon: Double
    var altitude: Int?
    var onGround: Bool
    var groundSpeed: Double?
    var track: Double?
    var verticalRate: Double?
    var squawk: String?
    /// When the reported position was measured.
    var fixTime: Date
    var lastSeen: Date

    init?(_ a: ADSBAircraft, now: Date) {
        guard let lat = a.lat, let lon = a.lon else { return nil }
        id = a.hex.lowercased()
        let trimmed = a.flight?.trimmingCharacters(in: .whitespaces)
        callsign = (trimmed?.isEmpty ?? true) ? nil : trimmed
        registration = a.registration
        type = a.type
        typeName = a.typeName
        operatorName = a.operatorName
        self.lat = lat
        self.lon = lon
        switch a.altBaro {
        case .ground:
            altitude = 0
            onGround = true
        case .feet(let feet):
            altitude = feet
            onGround = false
        case nil:
            altitude = a.altGeom.map { Int($0) }
            onGround = false
        }
        groundSpeed = a.groundSpeed
        track = a.track ?? a.trueHeading
        verticalRate = a.baroRate ?? a.geomRate
        squawk = a.squawk
        fixTime = now.addingTimeInterval(-(a.seenPos ?? 0))
        lastSeen = now
    }

    var title: String { callsign ?? registration ?? id.uppercased() }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// Dead-reckoned position: last fix moved along track at ground speed, capped at 30 s.
    func position(at date: Date) -> CLLocationCoordinate2D {
        guard !onGround || (groundSpeed ?? 0) > 3,
              let speed = groundSpeed, speed > 0, let track else { return coordinate }
        let elapsed = min(max(date.timeIntervalSince(fixTime), 0), 30)
        return Geo.destination(lat, lon, bearing: track, distanceNM: speed * elapsed / 3600)
    }
}
