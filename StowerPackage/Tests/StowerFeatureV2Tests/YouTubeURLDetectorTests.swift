import Foundation
import StowerData
@testable import StowerFeature
import Testing

@Suite
struct YouTubeURLDetectorTests {
    private static let validID = "dQw4w9WgXcQ"

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", YouTubeURLDetector.Form.watch),
        ("https://youtube.com/watch?v=dQw4w9WgXcQ", .watch),
        ("https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share", .watch),
        ("https://www.youtube.com/watch?foo=bar&v=dQw4w9WgXcQ&t=10", .watch),
        ("https://youtu.be/dQw4w9WgXcQ?t=10", .youtuBe),
        ("https://youtu.be/dQw4w9WgXcQ", .youtuBe),
        ("https://www.youtube.com/shorts/dQw4w9WgXcQ", .shortsVertical),
        ("https://m.youtube.com/shorts/dQw4w9WgXcQ", .shortsVertical),
        ("https://www.youtube.com/embed/dQw4w9WgXcQ", .embed),
        ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", .embed),
        ("https://www.youtube.com/v/dQw4w9WgXcQ", .embed),
    ])
    func recognizesSupportedShapes(input: String, expectedForm: YouTubeURLDetector.Form) throws {
        let url = try #require(URL(string: input))
        let match = try #require(YouTubeURLDetector.match(url))
        #expect(match.videoID == Self.validID)
        #expect(match.form == expectedForm)
    }

    @Test(arguments: [
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=",
        "https://www.youtube.com/watch?v=toolong12345",    // 13 chars
        "https://www.youtube.com/watch?v=short",           // 5 chars
        "https://www.youtube.com/watch?v=bad!!!chars",     // invalid chars
        "https://youtu.be/",
        "https://www.youtube.com/shorts/",
        "https://www.youtube.com/embed/",
        "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",       // wrong scheme
        "https://fakeyoutube.com/watch?v=dQw4w9WgXcQ",     // lookalike host
    ])
    func rejectsUnsupportedOrMalformedInput(input: String) throws {
        let url = try #require(URL(string: input))
        #expect(YouTubeURLDetector.match(url) == nil)
    }

    @Test
    func canonicalWatchURLReturnsExpectedShape() {
        let url = YouTubeURLDetector.canonicalWatchURL(forID: Self.validID)
        #expect(url.absoluteString == "https://www.youtube.com/watch?v=\(Self.validID)")
    }

    @Test
    func embedURLUsesNoCookieHost() {
        let url = YouTubeURLDetector.embedURL(forID: Self.validID)
        #expect(url.absoluteString == "https://www.youtube-nocookie.com/embed/\(Self.validID)")
    }

    @Test
    func fallbackThumbnailURLUsesYtimgCDN() {
        let url = YouTubeURLDetector.fallbackThumbnailURL(forID: Self.validID)
        #expect(url.absoluteString == "https://i.ytimg.com/vi/\(Self.validID)/hqdefault.jpg")
    }

    @Test
    func isValidVideoIDRejectsWrongLengthAndInvalidCharacters() {
        #expect(YouTubeURLDetector.isValidVideoID("dQw4w9WgXcQ"))
        #expect(YouTubeURLDetector.isValidVideoID("A_b-C_d-E_f"))
        #expect(!YouTubeURLDetector.isValidVideoID(""))
        #expect(!YouTubeURLDetector.isValidVideoID("short"))
        #expect(!YouTubeURLDetector.isValidVideoID("dQw4w9WgXcQX"))
        #expect(!YouTubeURLDetector.isValidVideoID("bad!chars!!"))
    }

    @Test
    func videoIDConvenienceMatchesFullResult() throws {
        let url = try #require(URL(string: "https://youtu.be/\(Self.validID)"))
        #expect(YouTubeURLDetector.videoID(from: url) == Self.validID)
    }
}
