import CoreLocation
import XCTest
@testable import Skyfi

final class GeoTests: XCTestCase {
    func testDistanceBostonToJFK() {
        let d = Geo.distanceNM(42.3656, -71.0096, 40.6413, -73.7781)
        XCTAssertEqual(d, 162, accuracy: 3)
    }

    func testDestinationRoundTrip() {
        let start = (lat: 42.36, lon: -71.01)
        let end = Geo.destination(start.lat, start.lon, bearing: 45, distanceNM: 100)
        XCTAssertEqual(Geo.distanceNM(start.lat, start.lon, end.latitude, end.longitude), 100, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(start.lat, start.lon, end.latitude, end.longitude), 45, accuracy: 1)
    }

    func testAngleDifferenceWraps() {
        XCTAssertEqual(Geo.angleDifference(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Geo.angleDifference(10, 190), 180, accuracy: 0.001)
    }
}

final class ADSBDecodeTests: XCTestCase {
    let sample = """
    {"ac":[
      {"hex":"ab4f5d","flight":"JBU2119 ","r":"N828JB","t":"A320","alt_baro":"ground","gs":0.0,
       "true_heading":47.81,"lat":42.269339,"lon":-71.871169,"seen_pos":4.893,"seen":4.2},
      {"hex":"A38EF5","flight":"JBU697  ","t":"BCS3","desc":"AIRBUS A220-300","ownOp":"JETBLUE AIRWAYS CORP",
       "alt_baro":26150,"alt_geom":27125,"gs":407.5,"track":210.4,"baro_rate":-1088,"lat":41.9,"lon":-71.5},
      {"hex":"c0ffee","alt_baro":12000}
    ],"msg":"No error","now":1763700000000,"total":3}
    """

    func testDecodesGroundAndAirborne() throws {
        let aircraft = try JSONDecoder().decode(ADSBResponse.self, from: Data(sample.utf8)).all
        XCTAssertEqual(aircraft.count, 3)
        XCTAssertEqual(aircraft[0].altBaro, .ground)
        XCTAssertEqual(aircraft[1].altBaro, .feet(26150))

        let now = Date()
        let planes = aircraft.compactMap { Plane($0, now: now) }
        XCTAssertEqual(planes.count, 2, "The plane without a position is dropped")
        XCTAssertEqual(planes[0].callsign, "JBU2119")
        XCTAssertTrue(planes[0].onGround)
        XCTAssertEqual(planes[0].track ?? 0, 47.81, accuracy: 0.01, "Falls back to true heading")
        XCTAssertEqual(planes[1].id, "a38ef5")
        XCTAssertEqual(planes[1].verticalRate, -1088)
        XCTAssertFalse(planes[1].onGround)
    }

    func testDeadReckoningMovesAlongTrack() throws {
        let aircraft = try JSONDecoder().decode(ADSBResponse.self, from: Data(sample.utf8)).all
        let now = Date()
        let plane = try XCTUnwrap(Plane(aircraft[1], now: now))
        let later = plane.position(at: now.addingTimeInterval(10))
        let moved = Geo.distanceNM(plane.lat, plane.lon, later.latitude, later.longitude)
        XCTAssertEqual(moved, 407.5 * 10 / 3600, accuracy: 0.05)
        XCTAssertEqual(Geo.bearing(plane.lat, plane.lon, later.latitude, later.longitude), 210.4, accuracy: 1)

        let capped = plane.position(at: now.addingTimeInterval(300))
        XCTAssertEqual(Geo.distanceNM(plane.lat, plane.lon, capped.latitude, capped.longitude), 407.5 * 30 / 3600, accuracy: 0.05)

        let parked = try XCTUnwrap(Plane(aircraft[0], now: now))
        XCTAssertEqual(parked.position(at: now.addingTimeInterval(10)).latitude, parked.lat)
    }
}

final class AirportTests: XCTestCase {
    let index = AirportIndex.shared

    func testBundledAirportsLoad() throws {
        XCTAssertGreaterThan(index.all.count, 2000)
        let kbos = try XCTUnwrap(index.airport(icao: "KBOS"))
        XCTAssertEqual(kbos.iata, "BOS")
        XCTAssertTrue(kbos.runways.contains { $0.id == "22R" })
    }

    func testNearestAirport() {
        XCTAssertEqual(index.nearest(lat: 42.37, lon: -71.02, withinNM: 4)?.icao, "KBOS")
        XCTAssertNil(index.nearest(lat: 43.5, lon: -69.0, withinNM: 4), "Open ocean has no airport")
    }

    /// OurAirports headings are true, like ADS-B tracks (Boston is about 15° west of magnetic).
    func testRunwayMatch() throws {
        let kbos = try XCTUnwrap(index.airport(icao: "KBOS"))
        XCTAssertTrue(AirportIndex.runwayEnd(at: kbos, heading: 203)?.id.hasPrefix("22") ?? false)
        XCTAssertTrue(AirportIndex.runwayEnd(at: kbos, heading: 22)?.id.hasPrefix("04") ?? false)
        XCTAssertEqual(AirportIndex.runwayEnd(at: kbos, heading: 79)?.id, "09")
    }

    func testFeedsPointAtBundledAirports() {
        XCTAssertFalse(Catalog.feeds.isEmpty)
        for feed in Catalog.feeds {
            XCTAssertNotNil(index.airport(icao: feed.airport), "\(feed.mount) has no airport")
        }
        XCTAssertFalse(Catalog.presets.isEmpty)
        let mounts = Catalog.feeds.map(\.mount)
        XCTAssertEqual(mounts.count, Set(mounts).count, "Mounts are unique")
        XCTAssertEqual(Catalog.feeds(at: "KBOS").map(\.kind), [.tower, .approach, .departure])
        XCTAssertEqual(Catalog.feed(at: "KBOS")?.kind, .tower)
    }

    func testFortyMajorUSAirports() {
        let us = Catalog.connectable.filter { $0.hasPrefix("K") || $0.hasPrefix("PH") }
        XCTAssertGreaterThanOrEqual(us.count, 40)
        for icao in Catalog.connectable {
            XCTAssertEqual(index.airport(icao: icao)?.large, true, "\(icao) is a major airport")
        }
        let nearBoston = Catalog.airports(near: .init(latitude: 42.36, longitude: -71.0))
        XCTAssertEqual(nearBoston.first?.airport.icao, "KBOS")
    }
}

final class EventTests: XCTestCase {
    let index = AirportIndex.shared

    private func plane(ground: Bool, lat: Double = 42.36, lon: Double = -71.02, alt: Int? = nil,
                       speed: Double = 150, track: Double = 201, rate: Double? = nil) -> Plane {
        var json: [String: Any] = ["hex": "abc123", "flight": "DAL234", "t": "A321", "lat": lat, "lon": lon,
                                   "gs": speed, "track": track]
        json["alt_baro"] = ground ? "ground" as Any : (alt ?? 600) as Any
        if let rate { json["baro_rate"] = rate }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let a = try! JSONDecoder().decode(ADSBAircraft.self, from: data)
        return Plane(a, now: Date())!
    }

    func testTakeoffAtBoston() throws {
        let event = try XCTUnwrap(EventDetector.detect(previous: plane(ground: true), current: plane(ground: false), index: index))
        XCTAssertEqual(event.kind, .departure)
        XCTAssertEqual(event.airport, "KBOS")
        XCTAssertTrue(event.runway?.hasPrefix("22") ?? false)
        XCTAssertTrue(event.text.hasPrefix("DAL234 departed BOS 22"))
    }

    func testLandingAtBoston() throws {
        let event = try XCTUnwrap(EventDetector.detect(previous: plane(ground: false, track: 21), current: plane(ground: true, track: 21), index: index))
        XCTAssertEqual(event.kind, .arrival)
        XCTAssertTrue(event.runway?.hasPrefix("04") ?? false)
    }

    func testIgnoresTaxiFlicker() {
        XCTAssertNil(EventDetector.detect(previous: plane(ground: true, speed: 15), current: plane(ground: false, speed: 15), index: index))
        XCTAssertNil(EventDetector.detect(previous: plane(ground: true), current: plane(ground: true), index: index))
    }

    func testIgnoresFarFromAirports() {
        XCTAssertNil(EventDetector.detect(previous: plane(ground: true, lat: 43.5, lon: -69),
                                          current: plane(ground: false, lat: 43.5, lon: -69), index: index))
    }

    func testApproach() throws {
        let kbos = try XCTUnwrap(index.airport(icao: "KBOS"))
        // 10 nm southwest of Logan, heading northeast and descending.
        let spot = Geo.destination(kbos.lat, kbos.lon, bearing: 225, distanceNM: 10)
        let approaching = plane(ground: false, lat: spot.latitude, lon: spot.longitude, alt: 3000, track: 45, rate: -800)
        XCTAssertTrue(EventDetector.isApproaching(approaching, to: kbos))
        let leaving = plane(ground: false, lat: spot.latitude, lon: spot.longitude, alt: 3000, track: 225, rate: 1500)
        XCTAssertFalse(EventDetector.isApproaching(leaving, to: kbos))
    }

    @MainActor
    func testStoreRecordsEventOnce() {
        let store = TrafficStore(index: index)
        let before = try! JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"abc123","flight":"DAL234","lat":42.36,"lon":-71.02,"alt_baro":"ground","gs":140,"track":201}
        """.utf8))
        let after = try! JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"abc123","flight":"DAL234","lat":42.355,"lon":-71.025,"alt_baro":500,"gs":160,"track":201}
        """.utf8))
        store.merge([before], now: Date())
        store.merge([after], now: Date().addingTimeInterval(5))
        store.merge([after], now: Date().addingTimeInterval(10))
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.planes.count, 1)
        // The trail keeps both positions, not the repeat.
        XCTAssertEqual(store.trail("abc123").count, 2)
        XCTAssertTrue(store.trail(nil).isEmpty)
        store.connect(AirportIndex.shared.airport(icao: "KBOS"))
        XCTAssertTrue(store.trail("abc123").isEmpty, "connecting starts the picture over")
    }
}

final class ConnectTests: XCTestCase {
    let kbos = AirportIndex.shared.airport(icao: "KBOS")!

    private func plane(lat: Double, lon: Double, alt: Int?, ground: Bool = false, hex: String = "abc123") -> Plane {
        var json: [String: Any] = ["hex": hex, "flight": "DAL234", "lat": lat, "lon": lon, "gs": 150, "track": 40]
        if ground { json["alt_baro"] = "ground" } else if let alt { json["alt_baro"] = alt }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return Plane(try! JSONDecoder().decode(ADSBAircraft.self, from: data), now: Date())!
    }

    func testRange() {
        // On the ground at Logan.
        XCTAssertTrue(TrafficStore.inRange(plane(lat: kbos.lat + 0.01, lon: kbos.lon, alt: nil, ground: true), of: kbos))
        // On the ground at Providence (about 40 nm away): another airport's ramp.
        XCTAssertFalse(TrafficStore.inRange(plane(lat: 41.72, lon: -71.43, alt: nil, ground: true), of: kbos))
        // Final approach, 2,000 ft.
        XCTAssertTrue(TrafficStore.inRange(plane(lat: kbos.lat - 0.1, lon: kbos.lon - 0.1, alt: 2000), of: kbos))
        // Cruising overhead with Center.
        XCTAssertFalse(TrafficStore.inRange(plane(lat: kbos.lat, lon: kbos.lon + 0.2, alt: 35000), of: kbos))
        // 70 nm out.
        XCTAssertFalse(TrafficStore.inRange(plane(lat: kbos.lat + 70.0 / 60, lon: kbos.lon, alt: 8000), of: kbos))
        // No altitude reported: keep it.
        XCTAssertTrue(TrafficStore.inRange(plane(lat: kbos.lat + 0.3, lon: kbos.lon, alt: nil), of: kbos))
    }

    @MainActor
    func testConnectFiltersAndDisconnectClears() {
        let store = TrafficStore()
        store.merge([], now: Date())
        store.connect(kbos)
        XCTAssertEqual(store.connected?.icao, "KBOS")
        let close = try! JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"aaa111","flight":"JBU697","lat":42.30,"lon":-71.05,"alt_baro":3000,"gs":180,"track":40}
        """.utf8))
        let cruising = try! JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"bbb222","flight":"UAL1","lat":42.40,"lon":-71.30,"alt_baro":37000,"gs":480,"track":250}
        """.utf8))
        store.merge([close, cruising], now: Date())
        XCTAssertEqual(Set(store.planes.keys), ["aaa111"])
        store.connect(nil)
        XCTAssertNil(store.connected)
        XCTAssertTrue(store.planes.isEmpty)
    }
}

final class FeedChainTests: XCTestCase {
    private var chain: FeedChain { FeedChain(airport: "KBOS", candidates: Catalog.feeds(at: "KBOS")) }

    func testOfflineTowerFallsBackToApproachThenDeparture() {
        var c = chain
        XCTAssertEqual(c.current?.kind, .tower)
        XCTAssertEqual(c.failed(), .next)
        XCTAssertEqual(c.current?.kind, .approach)
        XCTAssertEqual(c.failed(), .next)
        XCTAssertEqual(c.current?.kind, .departure)
        XCTAssertEqual(c.failed(), .exhausted)
        XCTAssertEqual(c.current?.kind, .tower, "Starts over from the tower")
    }

    func testDropAfterPlayingRetriesSameFeed() {
        var c = chain
        c.markPlayed()
        XCTAssertEqual(c.failed(), .retrySame)
        XCTAssertEqual(c.current?.kind, .tower)
    }

    func testSingleFeedAirport() {
        var c = FeedChain(airport: "EGLL", candidates: Catalog.feeds(at: "EGLL"))
        XCTAssertEqual(c.candidates.count, 1)
        XCTAssertEqual(c.failed(), .exhausted)
        XCTAssertEqual(c.current?.mount, "egll_twr")
    }
}

final class YouTubeLinkTests: XCTestCase {
    func testParsesCommonLinks() {
        let id = "jfKfPfyJRdk"
        for input in [id, "https://www.youtube.com/watch?v=\(id)", "youtube.com/watch?v=\(id)&t=10",
                      "https://youtu.be/\(id)?si=abc", "https://m.youtube.com/live/\(id)", "https://www.youtube.com/shorts/\(id)",
                      "  https://youtube.com/embed/\(id)  "] {
            XCTAssertEqual(YouTubeLink.videoID(from: input), id, input)
        }
    }

    func testRejectsOthers() {
        XCTAssertNil(YouTubeLink.videoID(from: "https://vimeo.com/123456"))
        XCTAssertNil(YouTubeLink.videoID(from: "hello"))
        XCTAssertNil(YouTubeLink.videoID(from: "https://www.youtube.com/@LofiGirl"))
    }
}

@MainActor
final class PinnedPlaneTests: XCTestCase {
    private func aircraft(_ hex: String, lat: Double, lon: Double) -> ADSBAircraft {
        let json: [String: Any] = ["hex": hex, "flight": "BAW1", "lat": lat, "lon": lon, "alt_baro": 37000, "gs": 480, "track": 270]
        return try! JSONDecoder().decode(ADSBAircraft.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPinnedPlaneSurvivesOutsideTheAirspace() throws {
        let store = TrafficStore()
        let bos = try XCTUnwrap(AirportIndex.shared.airport(icao: "KBOS"))
        store.connect(bos)
        // Over the Atlantic, far outside Boston's 60 nm.
        let far = try XCTUnwrap(Plane(aircraft("400abc", lat: 52, lon: -30), now: Date()))
        store.pin(far)
        XCTAssertEqual(store.pinnedID, "400abc")
        store.merge([aircraft("400abc", lat: 52.1, lon: -30.5)], now: Date())
        XCTAssertNotNil(store.planes["400abc"])
        // Another plane out there is still dropped.
        store.merge([aircraft("400def", lat: 52, lon: -30)], now: Date())
        XCTAssertNil(store.planes["400def"])
        store.unpin()
        XCTAssertNil(store.pinnedID)
        XCTAssertNil(store.planes["400abc"])
    }

    func testPinKeepsThroughAirportSwitch() throws {
        let store = TrafficStore()
        let far = try XCTUnwrap(Plane(aircraft("400abc", lat: 52, lon: -30), now: Date()))
        store.pin(far)
        store.connect(try XCTUnwrap(AirportIndex.shared.airport(icao: "KJFK")))
        XCTAssertNotNil(store.planes["400abc"])
    }
}
