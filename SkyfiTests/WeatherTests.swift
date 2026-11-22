import XCTest
@testable import Skyfi

final class WeatherTests: XCTestCase {
    /// Real aviationweather.gov output (2026-11-22): calm Boston, foggy JFK.
    private let sample = #"""
    [{"icaoId":"KBOS","obsTime":1795334040,"temp":8.3,"dewp":7.2,"wdir":0,"wspd":0,"visib":7,"altim":1025.5,"wxString":"BCFG",
      "rawOb":"METAR KBOS 220754Z 00000KT 7SM BCFG BKN250 08/07 A3028","clouds":[{"cover":"BKN","base":25000}],"fltCat":"VFR"},
     {"icaoId":"KJFK","obsTime":1795333860,"temp":11.7,"dewp":11.7,"wdir":40,"wspd":5,"visib":0.25,"altim":1024.1,"wxString":"FG",
      "rawOb":"SPECI KJFK 220751Z 04005KT 1/4SM FG VV002 12/12 A3024","clouds":[{"cover":"OVX","base":200}],"fltCat":"LIFR"},
     {"icaoId":"KXYZ","wdir":"VRB","wspd":3,"visib":"10+","clouds":[{"cover":"FEW","base":4000},{"cover":"OVC","base":2500}]}]
    """#

    func testParsesRealReports() throws {
        let reports = METAR.parse(Data(sample.utf8))
        XCTAssertEqual(reports.count, 3)

        let bos = reports[0]
        XCTAssertEqual(bos.station, "KBOS")
        XCTAssertEqual(bos.windText, "Calm")
        XCTAssertNil(bos.windDirection)
        XCTAssertEqual(bos.ceilingFeet, 25000)
        XCTAssertEqual(bos.category, .vfr)
        XCTAssertEqual(try XCTUnwrap(bos.altimeterInHg), 30.28, accuracy: 0.01)
        XCTAssertEqual(bos.weather, "BCFG")

        let jfk = reports[1]
        XCTAssertEqual(jfk.windDirection, 40)
        XCTAssertEqual(jfk.windText, "040° 5 kt")
        XCTAssertEqual(jfk.ceilingFeet, 200)
        XCTAssertEqual(jfk.category, .lifr)
        XCTAssertEqual(jfk.visibilityText, "0.25 mi")

        let xyz = reports[2]
        XCTAssertTrue(xyz.windVariable)
        XCTAssertEqual(xyz.windText, "Variable 3 kt")
        XCTAssertEqual(xyz.visibilityMiles, 10)
        XCTAssertTrue(xyz.visibilityPlus)
        XCTAssertEqual(xyz.ceilingFeet, 2500)
        XCTAssertEqual(xyz.category, .mvfr, "no fltCat: worked out from the 2,500 ft ceiling")
    }

    func testFlightCategoryRules() {
        XCTAssertEqual(FlightCategory.from(ceiling: nil, visibility: 10), .vfr)
        XCTAssertEqual(FlightCategory.from(ceiling: 3000, visibility: 10), .mvfr)
        XCTAssertEqual(FlightCategory.from(ceiling: 900, visibility: 10), .ifr)
        XCTAssertEqual(FlightCategory.from(ceiling: nil, visibility: 2), .ifr)
        XCTAssertEqual(FlightCategory.from(ceiling: 400, visibility: 10), .lifr)
        XCTAssertEqual(FlightCategory.from(ceiling: nil, visibility: 0.5), .lifr)
    }

    func testBadJSONGivesNothing() {
        XCTAssertTrue(METAR.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(METAR.parse(Data("{}".utf8)).isEmpty)
    }

    // MARK: Runway guess

    private var boston: Airport { AirportIndex.shared.airport(icao: "KBOS")! }

    private func metar(wind: Int?, speed: Int) -> METAR {
        METAR(station: "KBOS", raw: "", observed: nil, windDirection: wind, windVariable: false, windSpeed: speed, gust: nil,
              visibilityMiles: 10, visibilityPlus: false, ceilingFeet: nil, temperatureC: nil, dewpointC: nil,
              altimeterInHg: nil, weather: nil, category: .vfr)
    }

    private func event(_ runway: String?, minutesAgo: Double, now: Date) -> AirportEvent {
        AirportEvent(kind: .arrival, planeID: UUID().uuidString, callsign: "DAL1", type: nil, airport: "KBOS",
                     airportCode: "BOS", runway: runway, time: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testRecentTrafficBeatsWind() {
        let now = Date()
        let events = [event("27", minutesAgo: 3, now: now), event("27", minutesAgo: 8, now: now),
                      event("22L", minutesAgo: 5, now: now), event("04R", minutesAgo: 90, now: now)]
        let guess = RunwayGuess.guess(airport: boston, events: events, metar: metar(wind: 40, speed: 15), now: now)
        XCTAssertEqual(guess, RunwayGuess.Result(runways: ["27", "22L"], fromTraffic: true))
    }

    func testWindPicksParallelRunwaysIntoTheWind() {
        // Wind from 210 at 14: the 22s (true heading 200) are the best into-wind ends.
        let guess = RunwayGuess.guess(airport: boston, events: [], metar: metar(wind: 210, speed: 14))
        XCTAssertEqual(guess, RunwayGuess.Result(runways: ["22L", "22R"], fromTraffic: false))
    }

    func testLightWindGivesNoGuess() {
        XCTAssertNil(RunwayGuess.guess(airport: boston, events: [], metar: metar(wind: 210, speed: 3)))
        XCTAssertNil(RunwayGuess.guess(airport: boston, events: [], metar: nil))
    }
}

@MainActor
final class PlacesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "skyfi-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFavoritesToggleAndPersist() {
        let defaults = freshDefaults()
        let places = Places(defaults: defaults)
        places.toggleFavorite("KBOS")
        places.toggleFavorite("KJFK")
        XCTAssertTrue(places.isFavorite("KBOS"))
        places.toggleFavorite("KBOS")
        XCTAssertFalse(places.isFavorite("KBOS"))
        XCTAssertEqual(Places(defaults: defaults).favorites, ["KJFK"])
    }

    func testRecentsNewestFirstNoDuplicatesCapped() {
        let places = Places(defaults: freshDefaults())
        for icao in ["KBOS", "KJFK", "KLGA", "KBOS", "KORD", "KATL", "KDFW", "KSEA"] {
            places.noteConnected(icao)
        }
        XCTAssertEqual(places.recents, ["KSEA", "KDFW", "KATL", "KORD", "KBOS"])
        places.toggleFavorite("KBOS")
        places.clearAll()
        XCTAssertTrue(places.favorites.isEmpty && places.recents.isEmpty)
    }

    func testSearchRanksCodesFirst() {
        XCTAssertEqual(Catalog.search("bos").first?.icao, "KBOS")
        XCTAssertEqual(Catalog.search("KJFK").first?.icao, "KJFK")
        XCTAssertTrue(Catalog.search("boston").contains { $0.icao == "KBOS" })
        XCTAssertTrue(Catalog.search("  ").isEmpty)
        XCTAssertTrue(Catalog.search("zzzzqq").isEmpty)
    }
}

final class FacilityTests: XCTestCase {
    private var boston: Airport { AirportIndex.shared.airport(icao: "KBOS")! }

    private func plane(lat: Double, lon: Double, alt: Int?, ground: Bool = false, track: Double = 40, rate: Double? = nil) -> Plane {
        var json: [String: Any] = ["hex": "abc123", "flight": "DAL234", "lat": lat, "lon": lon, "gs": 150, "track": track]
        if ground { json["alt_baro"] = "ground" } else if let alt { json["alt_baro"] = alt }
        if let rate { json["baro_rate"] = rate }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
    }

    func testGuesses() {
        // Taxiing at Logan.
        XCTAssertEqual(LikelyFacility.guess(plane(lat: 42.364, lon: -71.005, alt: nil, ground: true), airport: boston), .ground)
        // On the ground at another field (Hanscom, ~14 nm): not Logan's.
        XCTAssertNil(LikelyFacility.guess(plane(lat: 42.47, lon: -71.29, alt: nil, ground: true), airport: boston))
        // Short final, 4 nm out at 1,200 ft.
        XCTAssertEqual(LikelyFacility.guess(plane(lat: 42.31, lon: -70.98, alt: 1200, rate: -700), airport: boston), .tower)
        // 20 nm north-east, climbing away at 9,000 ft (track 45 = away from Logan).
        XCTAssertEqual(LikelyFacility.guess(plane(lat: 42.60, lon: -70.70, alt: 9000, track: 45, rate: 2000), airport: boston), .departure)
        // 20 nm out, descending toward Logan.
        XCTAssertEqual(LikelyFacility.guess(plane(lat: 42.60, lon: -70.70, alt: 9000, track: 225, rate: -1200), airport: boston), .approach)
        // Cruising overhead.
        XCTAssertEqual(LikelyFacility.guess(plane(lat: 42.40, lon: -71.00, alt: 35000), airport: boston), .center)
    }
}

final class ETATests: XCTestCase {
    func testMinutesToLanding() throws {
        let boston = try XCTUnwrap(AirportIndex.shared.airport(icao: "KBOS"))
        func plane(speed: Double?) -> Plane {
            var json: [String: Any] = ["hex": "abc123", "flight": "DAL234", "lat": 42.53, "lon": -71.0, "alt_baro": 5000, "track": 180]
            if let speed { json["gs"] = speed }
            let data = try! JSONSerialization.data(withJSONObject: json)
            return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
        }
        // ~10 nm out at 200 kt: 3 min flying plus 1 for the slowdown.
        XCTAssertEqual(EventDetector.minutesToLanding(plane(speed: 200), at: boston), 4)
        XCTAssertNil(EventDetector.minutesToLanding(plane(speed: 20), at: boston))
        XCTAssertNil(EventDetector.minutesToLanding(plane(speed: nil), at: boston))
    }
}

final class PlaneSizeTests: XCTestCase {
    func testSizesByType() {
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "B77W"), 1.3)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "a359"), 1.3)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "A321"), 1)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "E75L"), 1)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "C172"), 0.72)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "C17"), 1.3)
        XCTAssertEqual(PlaneAnnotationView.scale(forType: "C560"), 1, "a Citation jet, not a C-5")
        XCTAssertEqual(PlaneAnnotationView.scale(forType: nil), 1)
    }
}

final class EmergencyTests: XCTestCase {
    func testEmergencySquawks() {
        func plane(_ squawk: String?) -> Plane {
            var json: [String: Any] = ["hex": "abc123", "flight": "DAL234", "lat": 42.4, "lon": -71.0, "alt_baro": 5000]
            if let squawk { json["squawk"] = squawk }
            let data = try! JSONSerialization.data(withJSONObject: json)
            return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
        }
        XCTAssertEqual(plane("7700").emergency, "emergency")
        XCTAssertEqual(plane("7600").emergency, "radio failure")
        XCTAssertEqual(plane("7500").emergency, "hijack")
        XCTAssertNil(plane("1200").emergency)
        XCTAssertNil(plane(nil).emergency)
    }
}

final class ATISTests: XCTestCase {
    private var boston: Airport { AirportIndex.shared.airport(icao: "KBOS")! }

    /// Real atis.info output for Boston (2026-11-22).
    private let sample = #"""
    [{"airport":"KBOS","type":"combined","code":"O","datis":"BOS ATIS INFO O 0754Z. 00000KT 7SM BCFG BKN250 08/07 A3028 (THREE ZERO TWO EIGHT). RNAV X 33L, DEP 15R. RY 33L ILS OTS. READBACK ALL HOLD SHORT INSTRCNS AND ASSIGNED ALTITUDES. INCREASED BIRD ACTIVITY IN THE VICINITY OF LOGAN AIRPORT. ...ADVS YOU HAVE INFO O.","time":"0754","updatedAt":"2026-11-22T08:32:25.2719594Z"}]
    """#

    func testParsesAndFindsRunways() throws {
        let broadcasts = ATIS.parse(Data(sample.utf8))
        XCTAssertEqual(broadcasts.count, 1)
        let atis = try XCTUnwrap(broadcasts.first)
        XCTAssertEqual(atis.code, "O")
        XCTAssertEqual(atis.kind, .combined)
        XCTAssertNotNil(atis.updated)
        XCTAssertEqual(ATIS.runways(in: broadcasts, airport: boston), ATIS.Runways(landing: ["33L"], departing: ["15R"]))
    }

    func testSplitArrivalAndDepartureBroadcasts() {
        let broadcasts = [
            ATIS(airport: "KBOS", kind: .arrival, code: "K", text: "BOS ARR INFO K. ILS RY 4R APCH IN USE, VISUAL APCH RWY 4L. RWY 9 CLSD.", updated: nil),
            ATIS(airport: "KBOS", kind: .departure, code: "L", text: "BOS DEP INFO L. DEPG RWYS 4R, 9. TEMP 08/07.", updated: nil),
        ]
        let runways = ATIS.runways(in: broadcasts, airport: boston)
        XCTAssertEqual(runways.landing, ["04R", "04L"])
        XCTAssertEqual(runways.departing, ["04R", "09"])
    }

    func testNoRunwaysFromWeatherNumbers() {
        let broadcasts = [ATIS(airport: "KBOS", kind: .combined, code: "A", text: "BOS ATIS INFO A. 27012KT 10SM FEW040 22/04 A3001.", updated: nil)]
        XCTAssertTrue(ATIS.runways(in: broadcasts, airport: boston).isEmpty)
    }
}

final class LandingRunwayTests: XCTestCase {
    func testLinedUpRunway() throws {
        let boston = try XCTUnwrap(AirportIndex.shared.airport(icao: "KBOS"))
        func plane(track: Double) -> Plane {
            let json: [String: Any] = ["hex": "abc123", "flight": "DAL234", "lat": 42.30, "lon": -71.05, "alt_baro": 2000, "gs": 150, "track": track]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
        }
        // Logan's 33s have a true heading of 315.
        XCTAssertTrue(["33L", "33R"].contains(EventDetector.landingRunway(plane(track: 318), at: boston) ?? ""))
        XCTAssertNil(EventDetector.landingRunway(plane(track: 270 - 40), at: boston), "230° matches nothing within 15°")
    }
}
