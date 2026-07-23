//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumOPDS
import ReadiumShared
import XCTest

class readium_opds2_0_test: XCTestCase {
    var feed: Feed?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        guard let fileURL = Bundle.module.url(forResource: "Samples/opds_2_0", withExtension: "json") else {
            XCTFail("Unable to locate test file")
            return
        }

        do {
            let opdsData = try Data(contentsOf: fileURL)
            feed = try OPDS2Parser.parse(jsonData: opdsData, url: URL(string: "http://test.com")!, response: HTTPURLResponse()).feed
            XCTAssert(feed != nil)
        } catch {
            XCTFail(error.localizedDescription)
        }

        continueAfterFailure = true
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }

    func testMetadata() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssert(feed?.metadata.numberOfItem == 5)
    }

    /// A zero-result OPDS 2.0 feed omits the `publications`/`navigation`/`groups`/
    /// `facets` collections entirely — the shape servers such as Komga
    /// (`@JsonInclude(NON_EMPTY)`) emit for an empty search, leaving just
    /// `metadata` + `links`. Because the response declares the `application/opds+json`
    /// media type (the spec's authoritative feed identifier), it must parse as an
    /// empty feed, not be misread as a publication.
    func testEmptyFeedWithOPDSMediaTypeParsesAsFeed() throws {
        guard let fileURL = Bundle.module.url(forResource: "Samples/opds_2_0_empty_feed", withExtension: "json") else {
            XCTFail("Unable to locate empty-feed test file")
            return
        }
        let url = URL(string: "http://test.com/opds/search?q=nomatch")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/opds+json"]
        )!
        let data = try Data(contentsOf: fileURL)
        let parsed = try OPDS2Parser.parse(jsonData: data, url: url, response: response)

        XCTAssertNotNil(parsed.feed, "empty opds+json document must parse as a feed")
        XCTAssertNil(parsed.publication, "empty feed must not be misread as a publication")
        XCTAssertEqual(parsed.feed?.publications.count, 0)
        XCTAssertEqual(parsed.feed?.navigation.count, 0)
        XCTAssertEqual(parsed.feed?.metadata.title, "Search: nomatch")
    }
}
