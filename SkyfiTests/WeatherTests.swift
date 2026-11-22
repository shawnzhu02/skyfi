import MapKit
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

    func testAltitudeColorsBlendBetweenStops() {
        func hue(_ feet: Int?) -> CGFloat {
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            PlaneAnnotationView.altitudeColor(feet).getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            return h
        }
        // Low is warm, high is cool: hue climbs from orange toward blue.
        XCTAssertLessThan(hue(500), hue(10000))
        XCTAssertLessThan(hue(10000), hue(25000))
        XCTAssertEqual(PlaneAnnotationView.altitudeColor(nil), Theme.uiAmber)
        XCTAssertEqual(PlaneAnnotationView.altitudeColor(60000), PlaneAnnotationView.altitudeColor(45000))
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

    func testWeatherNumbersInArrivalBroadcastAreNotRunways() throws {
        // Logan has runway 22 and 9: "TEMP 22/09" and "VIS 9" must not count.
        let broadcasts = [ATIS(airport: "KBOS", kind: .arrival, code: "K",
                               text: "BOS ARR INFO K. TEMP 22/09. VIS 9. ILS RWY 22L APCH. RWY 27 U/S.", updated: nil)]
        XCTAssertEqual(ATIS.runways(in: broadcasts, airport: boston), ATIS.Runways(landing: ["22L"], departing: []))
    }

    func testDates() {
        XCTAssertNotNil(ATIS.parseDate("2026-11-22T08:32:25.2719594Z"))
        XCTAssertNotNil(ATIS.parseDate("2026-11-22T08:32:25.271Z"))
        XCTAssertNotNil(ATIS.parseDate("2026-11-22T08:32:25Z"))
        XCTAssertNotNil(ATIS.parseDate("2026-11-22T08:32:25.2719594+00:00"))
        XCTAssertNil(ATIS.parseDate("yesterday"))
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

final class LinkTests: XCTestCase {
    func testSkyfiLinks() throws {
        XCTAssertEqual(SkyfiLink.airport(from: try XCTUnwrap(URL(string: "skyfi://connect/KBOS")))?.icao, "KBOS")
        XCTAssertEqual(SkyfiLink.airport(from: try XCTUnwrap(URL(string: "skyfi://connect/jfk")))?.icao, "KJFK")
        XCTAssertNil(SkyfiLink.airport(from: try XCTUnwrap(URL(string: "https://connect/KBOS"))))
        XCTAssertNil(SkyfiLink.airport(from: try XCTUnwrap(URL(string: "skyfi://other/KBOS"))))
    }
}

final class ClockTests: XCTestCase {
    func testZulu() {
        XCTAssertEqual(AirportClock.zulu(Date(timeIntervalSince1970: 1795334040)), "0754Z")
    }
}

final class AirportFrequencyTests: XCTestCase {
    func testParseAndText() throws {
        let json = #"{"KBOS":[["TWR","Boston Tower West",128.8],["TWR","Boston Tower East",132.225],["GND","Ground",121.9],["bad"]]}"#
        let index = FrequencyIndex(FrequencyIndex.parse(Data(json.utf8)))
        XCTAssertEqual(index.frequencies("KBOS").map(\.mhzText), ["128.8", "132.225", "121.9"])
        XCTAssertNil(index.single("KBOS", kind: "TWR"))
        XCTAssertEqual(index.single("KBOS", kind: "GND")?.mhzText, "121.9")
        XCTAssertEqual(Frequency(kind: "ATIS", name: "ATIS", mhz: 135).mhzText, "135.0")
    }

    func testBundledDataLoads() {
        XCTAssertFalse(FrequencyIndex.shared.frequencies("KBOS").isEmpty)
    }
}

final class ProgressTests: XCTestCase {
    private func plane(lat: Double, lon: Double) -> Plane {
        let json: [String: Any] = ["hex": "abc999", "flight": "UAL1", "lat": lat, "lon": lon, "gs": 450, "alt_baro": 35000, "track": 270]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
    }

    func testHalfwayBostonToChicago() throws {
        let bos = try XCTUnwrap(AirportIndex.shared.airport(code: "BOS"))
        let ord = try XCTUnwrap(AirportIndex.shared.airport(code: "ORD"))
        let mid = plane(lat: (bos.lat + ord.lat) / 2, lon: (bos.lon + ord.lon) / 2)
        let progress = try XCTUnwrap(FlightProgress.from(route: "BOS → ORD", plane: mid))
        XCTAssertEqual(progress.to.icao, "KORD")
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.05)
    }

    func testPicksTheLegBeingFlown() throws {
        let ord = try XCTUnwrap(AirportIndex.shared.airport(code: "ORD"))
        let lax = try XCTUnwrap(AirportIndex.shared.airport(code: "LAX"))
        let west = plane(lat: (ord.lat + lax.lat) / 2, lon: (ord.lon + lax.lon) / 2)
        let progress = try XCTUnwrap(FlightProgress.from(route: "BOS → ORD → LAX", plane: west))
        XCTAssertEqual(progress.from.icao, "KORD")
        XCTAssertEqual(progress.to.icao, "KLAX")
    }

    func testUnknownCodes() {
        XCTAssertNil(FlightProgress.from(route: "ZZZ → QQQ", plane: plane(lat: 40, lon: -80)))
    }
}

final class RunwayStripTests: XCTestCase {
    func testBostonHasDrawableStrips() throws {
        let bos = try XCTUnwrap(AirportIndex.shared.airport(icao: "KBOS"))
        let strip = try XCTUnwrap(bos.strips?.first { $0.ids.contains("04R") })
        let corners = try XCTUnwrap(strip.corners())
        XCTAssertEqual(corners.count, 4)
        // Width across the threshold matches the strip's meters.
        let across = corners[0].distance(to: corners[3])
        XCTAssertEqual(across, strip.w, accuracy: 2)
    }

    func testDegenerateStrip() {
        XCTAssertNil(RunwayStrip(a: [42, -71], b: [42, -71], ids: ["1"], w: 45).corners())
        XCTAssertNil(RunwayStrip(a: [42], b: [42, -71], ids: ["1"], w: 45).corners())
    }
}

final class TAFTests: XCTestCase {
    func testParsesPeriodsAndCategories() throws {
        let json = #"""
        [{"icaoId":"KBOS","rawTAF":"TAF KBOS ...","fcsts":[
          {"timeFrom":1795327200,"timeTo":1795341600,"fcstChange":null,"wdir":190,"wspd":5,"visib":"6+","clouds":[{"cover":"BKN","base":25000}]},
          {"timeFrom":1795341600,"timeTo":1795356000,"fcstChange":"FM","wdir":180,"wspd":4,"visib":6,"wxString":"BR","clouds":[{"cover":"OVC","base":700}]},
          {"timeFrom":1795341600,"timeTo":1795345200,"fcstChange":"TEMPO","wdir":null,"wspd":0,"visib":2,"clouds":[]}
        ]}]
        """#
        let taf = try XCTUnwrap(TAF.parse(Data(json.utf8)).first)
        XCTAssertEqual(taf.periods.count, 3)
        XCTAssertEqual(taf.periods[0].weather.category, .vfr)
        XCTAssertEqual(taf.periods[1].weather.category, .ifr)
        XCTAssertEqual(taf.periods[1].change, "FM")
        XCTAssertTrue(taf.periods[2].isTemporary)
        let now = Date(timeIntervalSince1970: 1795342000)
        XCTAssertEqual(taf.upcoming(now: now).count, 2)
    }
}

final class ProgressUnknownStopTests: XCTestCase {
    func testUnknownMiddleStopGivesNoBar() {
        let json: [String: Any] = ["hex": "abc998", "flight": "UAL2", "lat": 41, "lon": -80, "gs": 450, "alt_baro": 35000, "track": 270]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let plane = Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
        XCTAssertNil(FlightProgress.from(route: "BOS → QQQ → LAX", plane: plane))
    }
}

final class ApproachLineTests: XCTestCase {
    func testCenterlineIsTenMilesOutFromTheThreshold() throws {
        let bos = try XCTUnwrap(AirportIndex.shared.airport(icao: "KBOS"))
        let strip = try XCTUnwrap(bos.strips?.first { $0.ids.contains("04R") })
        let line = try XCTUnwrap(strip.approachLine(for: "04R"))
        XCTAssertEqual(line[0].distance(to: line[1]), 18520, accuracy: 50)
        // Landing 04R comes from the southwest: the far end is south of the threshold.
        XCTAssertLessThan(line[1].coordinate.latitude, line[0].coordinate.latitude)
        XCTAssertNil(strip.approachLine(for: "09"))
    }
}

final class LookupTests: XCTestCase {
    func testQueryKinds() {
        XCTAssertEqual(ADSBClient.Lookup.from("dal234"), [.callsign("DAL234")])
        XCTAssertEqual(ADSBClient.Lookup.from("G-EUPT"), [.registration("G-EUPT")])
        XCTAssertEqual(ADSBClient.Lookup.from("N123AB"), [.registration("N123AB"), .callsign("N123AB")])
        XCTAssertEqual(ADSBClient.Lookup.from("4068f5"), [.hex("4068f5"), .callsign("4068F5")])
        XCTAssertEqual(ADSBClient.Lookup.from("ab"), [])
        XCTAssertEqual(ADSBClient.Lookup.from("DAL 234/"), [])
    }
}

final class CompassTests: XCTestCase {
    func testPoints() {
        XCTAssertEqual(PlaneCard.compass(0), "N")
        XCTAssertEqual(PlaneCard.compass(359), "N")
        XCTAssertEqual(PlaneCard.compass(44), "NE")
        XCTAssertEqual(PlaneCard.compass(225), "SW")
        XCTAssertEqual(PlaneCard.compass(-90), "W")
    }
}

final class NotableTests: XCTestCase {
    private func plane(type: String?, flags: Int? = nil, squawk: String? = nil) -> Plane {
        var json: [String: Any] = ["hex": "ae1234", "flight": "RCH123", "lat": 42, "lon": -71, "alt_baro": 20000]
        if let type { json["t"] = type }
        if let flags { json["dbFlags"] = flags }
        if let squawk { json["squawk"] = squawk }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
    }

    func testNotable() {
        XCTAssertEqual(plane(type: "A388").notable, "A380")
        XCTAssertEqual(plane(type: "C17", flags: 1).notable, "Military")
        XCTAssertEqual(plane(type: "B738", squawk: "7700").notable, "Squawking emergency")
        XCTAssertNil(plane(type: "B738").notable)
        XCTAssertNil(plane(type: nil, flags: 0).notable)
    }
}

final class NearbyTowersTests: XCTestCase {
    func testNearbyIsSortedAndExcludesItself() throws {
        // Worcester (KORH) is near Boston and Providence.
        let orh = try XCTUnwrap(AirportIndex.shared.airport(icao: "KORH") ?? AirportIndex.shared.airport(icao: "KMHT"))
        let nearby = NearbyTowersSection.nearby(orh)
        XCTAssertFalse(nearby.contains { $0.0.icao == orh.icao })
        XCTAssertEqual(nearby.map(\.1), nearby.map(\.1).sorted())
        XCTAssertLessThanOrEqual(nearby.count, 3)
    }
}

final class WeatherIntentTests: XCTestCase {
    func testSummary() throws {
        let json = #"[{"icaoId":"KBOS","rawOb":"KBOS 220854Z 19005KT 10SM FEW250 08/03 A3012","wdir":190,"wspd":5,"visib":"10+","clouds":[{"cover":"FEW","base":25000}],"temp":8,"dewp":3,"altim":1019.6,"fltCat":"VFR"}]"#
        let metar = try XCTUnwrap(METAR.parse(Data(json.utf8)).first)
        let text = AirportWeatherIntent.summary(code: "BOS", name: "Logan", metar: metar, atis: "K")
        XCTAssertTrue(text.hasPrefix("Logan: VFR. Wind 190° 5 kt."), text)
        XCTAssertTrue(text.hasSuffix("Information K."), text)
        XCTAssertEqual(AirportWeatherIntent.summary(code: "BOS", name: "Logan", metar: nil, atis: nil), "No current weather report for BOS.")
    }
}

final class DataBlockTests: XCTestCase {
    private func plane(alt: Any, gs: Double?) -> Plane {
        var json: [String: Any] = ["hex": "abc777", "flight": "DAL234", "lat": 42, "lon": -71, "alt_baro": alt]
        if let gs { json["gs"] = gs }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
    }

    func testDataBlock() {
        XCTAssertEqual(PlaneAnnotationView.dataBlock(plane(alt: 12000, gs: 254)), "DAL234\n120 25")
        XCTAssertEqual(PlaneAnnotationView.dataBlock(plane(alt: 900, gs: 140)), "DAL234\n009 14")
        XCTAssertEqual(PlaneAnnotationView.dataBlock(plane(alt: "ground", gs: 12)), "DAL234\nGND")
    }
}
