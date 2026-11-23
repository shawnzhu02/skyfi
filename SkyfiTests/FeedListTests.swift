import XCTest
@testable import Skyfi

/// LiveATC's airport-page feed list: parsing what the page script posts and picking a feed.
final class FeedListTests: XCTestCase {
    typealias Listed = LiveATCBrowser.ListedFeed

    func testParsesFeedsAndStatus() {
        let json = #"[{"mount":"kbos_twr","name":"KBOS Tower","status":"DOWN"},{"mount":"kbos_app","name":"Boston Approach","status":"UP"},{"mount":"kbos_gnd","name":"","status":""}]"#
        let feeds = LiveATCBrowser.parseListed(json)
        XCTAssertEqual(feeds, [
            Listed(mount: "kbos_twr", name: "KBOS Tower", up: false),
            Listed(mount: "kbos_app", name: "Boston Approach", up: true),
            Listed(mount: "kbos_gnd", name: "kbos_gnd", up: nil),
        ])
    }

    func testDropsBadMountsAndDuplicates() {
        let json = #"[{"mount":"kbos_twr","name":"A"},{"mount":"kbos_twr","name":"B"},{"mount":"x/../y","name":"C"},{"name":"no mount"}]"#
        XCTAssertEqual(LiveATCBrowser.parseListed(json).map(\.mount), ["kbos_twr"])
        XCTAssertEqual(LiveATCBrowser.parseListed("not json"), [])
    }

    func testBestSkipsDownTowerForLiveApproach() {
        let feeds = [Listed(mount: "kbos_twr", name: "KBOS Tower", up: false),
                     Listed(mount: "kbos_app", name: "Boston Approach", up: true),
                     Listed(mount: "kbos_gnd", name: "KBOS Ground", up: true)]
        XCTAssertEqual(LiveATCBrowser.best(feeds)?.mount, "kbos_app")
    }

    func testBestPrefersLiveTowerAndKnownUpOverUnknown() {
        let feeds = [Listed(mount: "kbos_atis", name: "KBOS ATIS", up: true),
                     Listed(mount: "kbos_twr2", name: "KBOS Tower", up: nil),
                     Listed(mount: "kbos_twr", name: "KBOS Del/Gnd/Twr", up: true)]
        XCTAssertEqual(LiveATCBrowser.best(feeds)?.mount, "kbos_twr")
    }

    func testBestIsNilWhenAllDown() {
        XCTAssertNil(LiveATCBrowser.best([Listed(mount: "a_twr", name: "Tower", up: false)]))
    }

    func testRank() {
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kjfk_twr", name: "JFK Tower", up: true)), 0)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kny_app", name: "NY Approach", up: true)), 1)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kny_dep", name: "NY Departure", up: true)), 2)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kzbw", name: "Boston Center", up: true)), 3)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kbos_atis", name: "KBOS ATIS", up: true)), 4)
    }

    func testFeedFromListing() {
        let feed = LiveATCBrowser.atcFeed(Listed(mount: "zz_app", name: "Somewhere Approach", up: true), icao: "kzzz")
        XCTAssertEqual(feed.airport, "KZZZ")
        XCTAssertEqual(feed.kind, .approach)
        XCTAssertEqual(feed.name, "Somewhere Approach")
    }
}

/// Subtitles: the matched callsign is split out so it can be drawn orange.
final class SubtitleTests: XCTestCase {
    private func line(_ tokens: [String], _ range: Range<Int>?) -> TalkStore.Line {
        TalkStore.Line(text: tokens.joined(separator: " "), planeID: range == nil ? nil : "a1b2c3", label: "DAL5614",
                       speaker: .controller, score: 0.9, runnerUp: nil, candidateCount: 3, time: Date(),
                       duration: 2, seconds: 1, tokens: tokens, callsignRange: range)
    }

    func testSplitsCallsignOut() {
        let parts = SubtitleLine.parts(line(["delta", "5614", "cleared", "to", "land"], 0..<2))
        XCTAssertEqual(parts?.before, "")
        XCTAssertEqual(parts?.callsign, "delta 5614")
        XCTAssertEqual(parts?.after, "cleared to land")
    }

    func testCallsignInTheMiddle() {
        let parts = SubtitleLine.parts(line(["boston", "tower", "jetblue", "12", "with", "you"], 2..<4))
        XCTAssertEqual(parts?.before, "boston tower")
        XCTAssertEqual(parts?.callsign, "jetblue 12")
        XCTAssertEqual(parts?.after, "with you")
    }

    func testNoMatchOrBadRangeIsPlain() {
        XCTAssertNil(SubtitleLine.parts(line(["say", "again"], nil)))
        XCTAssertNil(SubtitleLine.parts(line(["say", "again"], 1..<5)))
    }
}
