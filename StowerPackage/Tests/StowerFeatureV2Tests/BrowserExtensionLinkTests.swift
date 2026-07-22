import Foundation
@testable import StowerFeature
import Testing

@Suite
struct BrowserExtensionLinkTests {
    @Test
    func parsesEncodedArticleURL() throws {
        let incomingURL = try #require(URL(
            string: "stower://save?url=https%3A%2F%2Fexample.com%2Farticle%3Fpage%3D2%26mode%3Dreader%23notes"
        ))

        #expect(
            BrowserExtensionLink(incomingURL)
                == .save(try #require(URL(string: "https://example.com/article?page=2&mode=reader#notes")))
        )
    }

    @Test
    func acceptsDevelopmentScheme() throws {
        let incomingURL = try #require(URL(
            string: "stower-dev://save?url=https%3A%2F%2Fexample.com%2Farticle"
        ))

        #expect(
            BrowserExtensionLink(incomingURL)
                == .save(try #require(URL(string: "https://example.com/article")))
        )
    }

    @Test(arguments: [
        "stower://save",
        "stower://save?url=file%3A%2F%2F%2Ftmp%2Farticle",
        "stower://open?url=https%3A%2F%2Fexample.com",
        "other://save?url=https%3A%2F%2Fexample.com",
    ])
    func rejectsMalformedOrUnsupportedLinks(_ value: String) throws {
        #expect(BrowserExtensionLink(try #require(URL(string: value))) == nil)
    }
}
