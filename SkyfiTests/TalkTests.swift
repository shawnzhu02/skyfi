import XCTest
@testable import Skyfi

final class PhraseologyTests: XCTestCase {
    func testNumberGroupings() {
        XCTAssertEqual(Phraseology.tokens("Delta two three four"), ["delta", "234"])
        XCTAssertEqual(Phraseology.tokens("delta two thirty four"), ["delta", "234"])
        XCTAssertEqual(Phraseology.tokens("brickyard forty five twenty two"), ["brickyard", "4522"])
        XCTAssertEqual(Phraseology.tokens("American eleven forty two"), ["american", "1142"])
        XCTAssertEqual(Phraseology.tokens("one niner tree fife"), ["1935"])
        XCTAssertEqual(Phraseology.tokens("five zero one"), ["501"])
        XCTAssertTrue(Phraseology.tokens("climb and maintain three thousand five hundred").contains("3500"))
        XCTAssertEqual(Phraseology.tokens("Speedbird 213 heavy, uh, contact departure"), ["speedbird", "213", "contact", "departure"])
    }

    func testRepeatedHundredsDoNotCrash() {
        // Whisper sometimes loops on one word.
        _ = Phraseology.tokens(String(repeating: "hundred ", count: 40))
        _ = Phraseology.tokens("nine " + String(repeating: "hundred ", count: 12) + "thousand thousand thousand")
    }

    func testAlphanumericSplit() {
        XCTAssertEqual(Phraseology.tokens("runway 22L"), ["runway", "22", "lima"])
        XCTAssertEqual(Phraseology.tokens("N123AB"), ["november", "123", "alpha", "bravo"])
    }

    func testRunwayAndInstruction() {
        XCTAssertEqual(Phraseology.runway(Phraseology.tokens("cleared to land runway two two left")), "22L")
        XCTAssertEqual(Phraseology.runway(Phraseology.tokens("runway 9")), "09")
        XCTAssertEqual(Phraseology.instruction(Phraseology.tokens("Delta 234 runway 4R cleared to land")), .landing)
        XCTAssertEqual(Phraseology.instruction(Phraseology.tokens("runway 22R cleared for takeoff")), .takeoff)
        XCTAssertEqual(Phraseology.instruction(Phraseology.tokens("hold short of runway 27")), .holdShort)
        XCTAssertEqual(Phraseology.instruction(Phraseology.tokens("climb and maintain five thousand")), .altitude)
        XCTAssertEqual(Phraseology.instruction(Phraseology.tokens("contact departure one three three point zero")), .frequencyChange)
    }
}

final class TelephonyTests: XCTestCase {
    func testKnownAirlines() {
        XCTAssertEqual(Telephony.table["DAL"], "delta")
        XCTAssertEqual(Telephony.table["BAW"], "speedbird")
        XCTAssertEqual(Telephony.table["RPA"], "brickyard")
        XCTAssertEqual(Telephony.table["JBU"], "jetblue")
        XCTAssertGreaterThan(Telephony.table.count, 1000)
    }
}

final class MatcherTests: XCTestCase {
    let matcher = CallsignMatcher()

    private func plane(_ id: String, callsign: String? = nil, reg: String? = nil, type: String? = nil,
                       ground: Bool = false, approaching: Bool = false, track: Double? = nil) -> Candidate {
        Candidate(id: id, callsign: callsign, registration: reg, type: type, onGround: ground, approaching: approaching, track: track)
    }

    private lazy var boston: [Candidate] = [
        plane("dal234", callsign: "DAL234", approaching: true, track: 40),
        plane("dal243", callsign: "DAL243", ground: true),
        plane("jbu697", callsign: "JBU697", ground: true),
        plane("baw213", callsign: "BAW213"),
        plane("rpa4522", callsign: "RPA4522"),
        plane("aal1142", callsign: "AAL1142"),
        plane("swa12k", callsign: "SWA12K"),
        plane("n123ab", callsign: "N123AB", reg: "N123AB", type: "C172", ground: true),
        plane("geupt", callsign: "GEUPT", reg: "G-EUPT", type: "A320"),
    ]

    private func check(_ text: String, _ expected: String?, speaker: CallsignMatcher.Speaker? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        let result = matcher.match(tokens: Phraseology.tokens(text), candidates: boston)
        XCTAssertEqual(result.accepted?.candidateID, expected, "\"\(text)\" best: \(String(describing: result.best))", file: file, line: line)
        if let speaker {
            XCTAssertEqual(result.accepted?.speaker, speaker, text, file: file, line: line)
        }
    }

    func testControllerToAirline() {
        check("delta two three four runway four right cleared to land", "dal234", speaker: .controller)
        check("Delta 234, runway 4R, cleared to land.", "dal234", speaker: .controller)
        check("speedbird two one three heavy contact boston departure one three three point zero", "baw213", speaker: .controller)
        check("brickyard forty five twenty two climb and maintain five thousand", "rpa4522", speaker: .controller)
        check("american eleven forty two turn left heading two seven zero", "aal1142", speaker: .controller)
        check("southwest twelve kilo taxi to runway two seven via bravo", "swa12k", speaker: .controller)
    }

    func testPilotReadbacks() {
        check("cleared to land four right delta two three four", "dal234", speaker: .pilot)
        check("boston tower jetblue six ninety seven holding short two two right", "jbu697", speaker: .pilot)
        check("Boston ground, Delta 243, ready to taxi", "dal243", speaker: .pilot)
    }

    func testSplitAndSlightlyWrongWords() {
        check("jet blue six nine seven runway two two right line up and wait", "jbu697")
        check("speed bird two one three contact departure", "baw213")
    }

    func testGeneralAviation() {
        check("november one two three alpha bravo taxi to runway four left via alpha", "n123ab", speaker: .controller)
        check("cessna three alpha bravo hold short runway four left", "n123ab")
        check("three alpha bravo hold short runway four left", "n123ab")
        check("golf echo uniform papa tango contact approach", "geupt")
    }

    func testSimilarCallsignsStayApart() {
        check("delta two four three taxi to runway two two right", "dal243")
        check("delta two three four cleared to land", "dal234")
    }

    func testAbstainsWhenUnsure() {
        // Two Deltas fit "two three" equally: say nothing rather than pick one.
        check("delta two three", nil)
        check("wind two seven zero at one five gusts two five", nil)
        check("traffic twelve o'clock five miles", nil)
        check("united five five five cleared to land", nil)
    }

    func testHintText() {
        let hint = matcher.hint(for: [plane("a", callsign: "DAL234"), plane("b", callsign: "N123AB", reg: "N123AB")])
        XCTAssertEqual(hint, "Delta 234, November 123 Alpha Bravo")
    }
}

final class SquelchTests: XCTestCase {
    private func noise(_ seconds: Double, amplitude: Float = 0.003) -> [Float] {
        var seed: UInt32 = 12345
        return (0..<Int(seconds * Squelch.sampleRate)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Squelch.sampleRate)).map { i in amplitude * sin(Float(i) * 2 * .pi * 440 / Float(Squelch.sampleRate)) }
    }

    func testFindsTwoTransmissions() {
        let squelch = Squelch()
        let audio = noise(1) + tone(1.5) + noise(1) + tone(0.8) + noise(1.2)
        var transmissions: [Transmission] = []
        var opens = 0
        // Feed in 100 ms chunks like the tap does.
        stride(from: 0, to: audio.count, by: 1600).forEach { start in
            for event in squelch.process(Array(audio[start..<min(start + 1600, audio.count)])) {
                switch event {
                case .opened: opens += 1
                case .closed(let t): if let t { transmissions.append(t) }
                }
            }
        }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(transmissions.count, 2)
        XCTAssertEqual(transmissions[0].duration, 1.5, accuracy: 0.45)
        XCTAssertEqual(transmissions[1].duration, 0.8, accuracy: 0.45)
    }

    func testIgnoresClicks() {
        let squelch = Squelch()
        let audio = noise(1) + tone(0.12) + noise(1.5)
        var kept = 0
        for event in squelch.process(audio) {
            if case .closed(let t) = event, t != nil { kept += 1 }
        }
        XCTAssertEqual(kept, 0)
    }

    func testCutsLongTransmissions() {
        let squelch = Squelch()
        let events = squelch.process(noise(1) + tone(20))
        let closed = events.filter { if case .closed = $0 { return true } else { return false } }
        XCTAssertEqual(closed.count, 1, "Forced cut at 15 s")
    }

    func testResamplerLength() {
        var resampler = Resampler(inputRate: 44_100)
        var total = 0
        for _ in 0..<10 { total += resampler.process([Float](repeating: 0.1, count: 4410)).count }
        XCTAssertEqual(Double(total), 16_000, accuracy: 20)
    }
}

final class FrequencyTests: XCTestCase {
    private func plane(lat: Double, lon: Double, altitude: Int?, ground: Bool) -> Plane {
        let alt = ground ? "\"ground\"" : String(altitude ?? 0)
        let json = """
        {"hex":"abc123","flight":"DAL234","lat":\(lat),"lon":\(lon),"alt_baro":\(alt),"gs":140,"track":40}
        """
        let ac = try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8))
        return Plane(ac, now: Date())!
    }

    func testTowerTakesFieldAndFinalOnly() {
        let kbos = AirportIndex.shared.airport(icao: "KBOS")!
        let onField = plane(lat: kbos.lat + 0.01, lon: kbos.lon, altitude: nil, ground: true)
        let onFinal = plane(lat: kbos.lat - 0.08, lon: kbos.lon - 0.08, altitude: 1500, ground: false)
        let cruising = plane(lat: kbos.lat - 0.1, lon: kbos.lon, altitude: 33000, ground: false)
        let far = plane(lat: kbos.lat + 0.6, lon: kbos.lon, altitude: 3000, ground: false)
        func on(_ p: Plane, _ kind: ATCFeed.Kind) -> Bool {
            TalkStore.onFrequency(p, distanceNM: Geo.distanceNM(p.lat, p.lon, kbos.lat, kbos.lon), airport: kbos, kind: kind)
        }
        XCTAssertTrue(on(onField, .tower))
        XCTAssertTrue(on(onFinal, .tower))
        XCTAssertFalse(on(cruising, .tower))
        XCTAssertFalse(on(far, .tower))
        XCTAssertFalse(on(onField, .approach))
        XCTAssertTrue(on(far, .approach))
    }
}

/// End to end without the speech model: transcript text in, glowing plane out.
@MainActor
final class HighlightTests: XCTestCase {
    let kbos = AirportIndex.shared.airport(icao: "KBOS")!

    private func aircraft(_ hex: String, _ flight: String, lat: Double, lon: Double, alt: String) -> ADSBAircraft {
        try! JSONDecoder().decode(ADSBAircraft.self, from: Data("""
        {"hex":"\(hex)","flight":"\(flight)","lat":\(lat),"lon":\(lon),"alt_baro":\(alt),"gs":140,"track":40}
        """.utf8))
    }

    private func connectedStore() -> TrafficStore {
        let traffic = TrafficStore()
        traffic.connect(kbos)
        traffic.merge([
            aircraft("a1b2c3", "DAL234", lat: 42.30, lon: -71.08, alt: "1800"),
            aircraft("d4e5f6", "N123AB", lat: 42.365, lon: -71.01, alt: "\"ground\""),
            aircraft("abcdef", "DAL243", lat: 42.37, lon: -71.02, alt: "\"ground\""),
        ], now: Date())
        TalkStore.shared.connect(traffic: traffic)
        // Start clean: the store is shared between tests.
        TalkStore.shared.feedChanged(item: nil, feed: nil)
        TalkStore.shared.feedChanged(item: nil, feed: Catalog.feed(at: "KBOS"))
        return traffic
    }

    func testTowerCallLightsUpTheRightPlane() {
        let traffic = connectedStore()
        XCTAssertEqual(traffic.planes.count, 3)
        let line = TalkStore.shared.ingest(text: "delta two three four runway four right cleared to land")
        XCTAssertEqual(line.planeID, "a1b2c3")
        XCTAssertEqual(line.speaker, .controller)
        let talk = try! XCTUnwrap(TalkStore.shared.talking["a1b2c3"])
        XCTAssertTrue(talk.isFresh)
        XCTAssertNil(TalkStore.shared.talking["abcdef"], "Delta 243 must not glow")
    }

    func testPilotReadbackAndGarbleDoesNotGlow() {
        _ = connectedStore()
        let pilot = TalkStore.shared.ingest(text: "Boston ground, Delta 243, ready to taxi")
        XCTAssertEqual(pilot.planeID, "abcdef")
        XCTAssertEqual(pilot.speaker, .pilot)
        let garbled = TalkStore.shared.ingest(text: "wind two seven zero at one five")
        XCTAssertNil(garbled.planeID)
    }

    func testDebugButtonHighlightsNearestPlane() {
        _ = connectedStore()
        XCTAssertTrue(TalkStore.shared.testHighlight())
        XCTAssertNotNil(TalkStore.shared.latestTalker)
    }

    func testAnnotationGlowAndExpiry() {
        let traffic = connectedStore()
        let plane = try! XCTUnwrap(traffic.planes["a1b2c3"])
        let view = PlaneAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(plane: plane, style: .approach, showLabel: true, mapHeading: 0)
        XCTAssertEqual(view.zPriority, .defaultSelected)
        view.setTalk(TalkStore.Talk(time: Date(), speaker: .controller, text: "Delta 234 cleared to land"))
        XCTAssertTrue(view.isTalking)
        XCTAssertEqual(view.zPriority, .max)
        XCTAssertNotNil(view.bubbleText)
        view.setTalk(TalkStore.Talk(time: Date().addingTimeInterval(-30), speaker: .controller, text: "old"))
        XCTAssertFalse(view.isTalking)
        XCTAssertNil(view.bubbleText)
        XCTAssertEqual(view.zPriority, .defaultSelected, "Back to the approach style's order")
    }
}
