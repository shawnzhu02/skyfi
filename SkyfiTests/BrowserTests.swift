import XCTest
@testable import Skyfi

@MainActor
final class BrowserTests: XCTestCase {
    func testPlayerURLRoundTrips() throws {
        let feed = try XCTUnwrap(Catalog.feed(at: "KBOS"))
        let url = LiveATCBrowser.playerURL(for: feed)
        XCTAssertEqual(url.host, "www.liveatc.net")
        XCTAssertEqual(url.path, "/hlisten.php")
        XCTAssertEqual(LiveATCBrowser.feed(fromPlayerURL: url)?.mount, feed.mount)
    }

    func testUnknownMountFromPage() throws {
        let url = try XCTUnwrap(URL(string: "https://www.liveatc.net/hlisten.php?mount=kbos_gnd_x&icao=kbos"))
        let feed = try XCTUnwrap(LiveATCBrowser.feed(fromPlayerURL: url))
        XCTAssertEqual(feed.mount, "kbos_gnd_x")
        XCTAssertEqual(feed.airport, "KBOS")
        XCTAssertEqual(feed.kind, .tower)
    }

    func testNonPlayerPagesAreIgnored() throws {
        XCTAssertNil(LiveATCBrowser.feed(fromPlayerURL: try XCTUnwrap(URL(string: "https://www.liveatc.net/search/?icao=kbos"))))
        XCTAssertNil(LiveATCBrowser.feed(fromPlayerURL: try XCTUnwrap(URL(string: "https://example.com/hlisten.php?mount=kbos_twr"))))
    }
}
