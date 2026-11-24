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
        XCTAssertEqual(LiveATCBrowser.best(feeds)?.mount, "kbos_twr2")
    }

    func testTowerOnlyBeatsSharedGroundTower() {
        let feeds = [Listed(mount: "kjfk_gnd_twr", name: "JFK Ground/Tower", up: true),
                     Listed(mount: "kjfk_twr", name: "JFK Tower", up: true)]
        XCTAssertEqual(LiveATCBrowser.best(feeds)?.mount, "kjfk_twr")
        // Shared feed still beats approach when it is the only tower.
        let only = [Listed(mount: "kjfk_app", name: "NY Approach", up: true),
                    Listed(mount: "kjfk_gnd_twr", name: "JFK Ground/Tower", up: true)]
        XCTAssertEqual(LiveATCBrowser.best(only)?.mount, "kjfk_gnd_twr")
    }

    func testBestIsNilWhenAllDown() {
        XCTAssertNil(LiveATCBrowser.best([Listed(mount: "a_twr", name: "Tower", up: false)]))
    }

    func testRank() {
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kjfk_twr", name: "JFK Tower", up: true)), 0)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kjfk_gnd_twr", name: "JFK Ground/Tower", up: true)), 1)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kny_app", name: "NY Approach", up: true)), 2)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kny_dep", name: "NY Departure", up: true)), 3)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kzbw", name: "Boston Center", up: true)), 4)
        XCTAssertEqual(LiveATCBrowser.rank(Listed(mount: "kbos_atis", name: "KBOS ATIS", up: true)), 5)
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

/// Whatever gets pasted into the music box.
final class YouTubePasteTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    func testCommonForms() {
        for text in ["https://www.youtube.com/watch?v=\(id)", "youtube.com/watch?v=\(id)&list=PLx&t=30s",
                     "https://youtu.be/\(id)?si=abc", "https://m.youtube.com/watch?v=\(id)",
                     "https://music.youtube.com/watch?v=\(id)&si=x", "https://www.youtube.com/live/\(id)?feature=share",
                     "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)", id,
                     "  https://youtu.be/\(id)  \n"] {
            XCTAssertEqual(YouTubeLink.videoID(inPasted: text), id, text)
        }
    }

    func testShareTextAroundALink() {
        XCTAssertEqual(YouTubeLink.videoID(inPasted: "Check this out: https://youtu.be/\(id)?si=zz, so good"), id)
        XCTAssertEqual(YouTubeLink.videoID(inPasted: "<https://www.youtube.com/watch?v=\(id)>"), id)
    }

    func testNotVideos() {
        XCTAssertNil(YouTubeLink.videoID(inPasted: "https://www.youtube.com/playlist?list=PLabc"))
        XCTAssertNil(YouTubeLink.videoID(inPasted: "https://example.com/watch?v=\(id)"))
        XCTAssertNil(YouTubeLink.videoID(inPasted: "hello"))
    }

    func testBoardingPresetsExist() {
        let boarding = Catalog.presets.filter { $0.id.hasPrefix("board-") }
        XCTAssertGreaterThanOrEqual(boarding.count, 6)
        XCTAssertTrue(boarding.allSatisfy { YouTubeLink.videoID(from: $0.value) == $0.value })
    }
}

/// The station picker: every feed at an airport, grouped by kind.
final class StationGroupTests: XCTestCase {
    typealias Listed = LiveATCBrowser.ListedFeed

    func testGroupsEveryStationInOrder() {
        let feeds = [Listed(mount: "kjfk_app", name: "JFK Approach", up: true),
                     Listed(mount: "kjfk_twr", name: "JFK Tower #1", up: true),
                     Listed(mount: "kjfk_atis", name: "JFK ATIS", up: true),
                     Listed(mount: "kjfk_twr2", name: "JFK Tower #2", up: nil),
                     Listed(mount: "kjfk_gnd", name: "JFK Ground", up: true),
                     Listed(mount: "kjfk_dep", name: "JFK Departure", up: false),
                     Listed(mount: "kzny", name: "New York Center", up: true)]
        let groups = LiveATCBrowser.grouped(feeds)
        XCTAssertEqual(groups.map(\.title), ["Tower", "Ground and clearance", "ATIS", "Approach", "Departure", "Other"])
        XCTAssertEqual(groups[0].feeds.map(\.mount), ["kjfk_twr", "kjfk_twr2"])
        XCTAssertEqual(groups.flatMap(\.feeds).count, feeds.count)
    }

    func testEmptyGroupsAreLeftOut() {
        let groups = LiveATCBrowser.grouped([Listed(mount: "a_twr", name: "Tower", up: true)])
        XCTAssertEqual(groups.map(\.title), ["Tower"])
    }
}
