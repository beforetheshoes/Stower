import Foundation
@testable import StowerData
@testable import StowerFeature
import SwiftSoup
import Testing

@Suite
struct HTMLMediaExtractorTests {
    private func element(_ html: String, _ selector: String, base: String = "https://example.com/post/") throws -> Element {
        let document = try SwiftSoup.parse(html, base)
        return try #require(try document.select(selector).first())
    }

    // MARK: - Image source selection

    @Test
    func srcIsPreferredAndResolvedAgainstThePage() throws {
        let img = try element(#"<img src="/images/a.jpg" data-src="/lazy/b.jpg">"#, "img")
        #expect(bestImageSource(img) == "https://example.com/images/a.jpg")
    }

    @Test
    func lazyLoadedImagesFallBackThroughTheirDataAttributes() throws {
        #expect(bestImageSource(try element(#"<img data-src="/lazy/b.jpg">"#, "img")) == "https://example.com/lazy/b.jpg")
        #expect(bestImageSource(try element(#"<img data-original="c.png">"#, "img")) == "https://example.com/post/c.png")
        #expect(bestImageSource(try element(#"<img data-lazy-src="/d.webp">"#, "img")) == "https://example.com/d.webp")
        #expect(bestImageSource(try element(#"<img alt="nothing">"#, "img")) == nil)
    }

    @Test
    func theWidestSrcsetCandidateWins() throws {
        let img = try element(
            #"<img srcset="https://cdn.example.com/s.jpg 400w, https://cdn.example.com/l.jpg 1600w, https://cdn.example.com/m.jpg 800w">"#,
            "img"
        )
        #expect(bestSourceFromSrcSet(img) == "https://cdn.example.com/l.jpg")
    }

    @Test
    func densityDescriptorsRankAboveBareCandidates() throws {
        let img = try element(
            #"<img srcset="https://cdn.example.com/1x.jpg, https://cdn.example.com/2x.jpg 2x">"#,
            "img"
        )
        #expect(bestSourceFromSrcSet(img) == "https://cdn.example.com/2x.jpg")
    }

    @Test
    func anImageWithOnlyASrcsetGetsAUsableAbsoluteURL() throws {
        // Relative candidates, and no `src` at all.
        let img = try element(#"<img srcset="/img/s.jpg 400w, /img/l.jpg 1600w" alt="Photo">"#, "img")

        #expect(bestImageSource(img) == "https://example.com/img/l.jpg")
        #expect(try imageDescriptor(img, captionHint: nil)?.sourceURL == "https://example.com/img/l.jpg")
    }

    @Test
    func lazySrcsetIsReadToo() throws {
        let img = try element(#"<img data-srcset="a.jpg 1x, b.jpg 2x">"#, "img")
        #expect(bestSourceFromSrcSet(img) == "https://example.com/post/b.jpg")
    }

    // MARK: - Descriptors

    @Test
    func anImageBecomesADescriptorWithItsSizeAndAltText() throws {
        let img = try element(#"<img src="/a.png" width="1200" height="630" alt="A chart">"#, "img")
        let descriptor = try #require(try imageDescriptor(img, captionHint: nil))

        #expect(descriptor.kind == .image)
        #expect(descriptor.sourceURL == "https://example.com/a.png")
        #expect(descriptor.mimeType == "image/png")
        #expect(descriptor.width == 1200)
        #expect(descriptor.height == 630)
        #expect(descriptor.altText == "A chart")
        // With no figure caption, the alt text stands in.
        #expect(descriptor.caption == "A chart")
    }

    @Test
    func aFigureCaptionTakesPrecedenceOverAltText() throws {
        let img = try element(#"<img src="/a.png" alt="A chart">"#, "img")
        #expect(try imageDescriptor(img, captionHint: "Figure 1")?.caption == "Figure 1")
    }

    @Test
    func inlineDataImagesAreNotArticleMedia() throws {
        let img = try element(#"<img src="data:image/png;base64,AAAA">"#, "img")
        #expect(try imageDescriptor(img, captionHint: nil) == nil)
    }

    @Test
    func avatarsAndTinyImagesAreLeftOut() throws {
        #expect(try imageDescriptor(try element(#"<img src="/a.jpg" class="author-avatar">"#, "img"), captionHint: nil) == nil)
        #expect(try imageDescriptor(try element(#"<img src="/gravatar/x.jpg">"#, "img"), captionHint: nil) == nil)
        #expect(try imageDescriptor(try element(#"<img src="/a.jpg" width="40" height="400">"#, "img"), captionHint: nil) == nil)
        #expect(try imageDescriptor(try element(#"<img src="/a.jpg" width="64" height="64">"#, "img"), captionHint: nil) == nil)
        #expect(try imageDescriptor(try element(#"<img src="/a.jpg" width="65" height="65">"#, "img"), captionHint: nil) != nil)
    }

    @Test
    func avatarDetectionReadsTokensAndSizes() {
        #expect(isLikelyAvatarImage(combined: "https://x/headshot.jpg", width: nil, height: nil))
        #expect(isLikelyAvatarImage(combined: "photo", width: 48, height: nil))
        #expect(isLikelyAvatarImage(combined: "photo", width: nil, height: 48))
        #expect(!isLikelyAvatarImage(combined: "photo", width: 800, height: 600))
        #expect(!isLikelyAvatarImage(combined: "photo", width: nil, height: nil))
    }

    // MARK: - Small helpers

    @Test(arguments: [
        ("https://x/a.JPG", "image/jpeg"),
        ("https://x/a.jpeg", "image/jpeg"),
        ("https://x/a.png", "image/png"),
        ("https://x/a.gif", "image/gif"),
        ("https://x/a.webp", "image/webp"),
        ("https://x/a.mp4", "video/mp4"),
        ("https://x/a.m3u8", "application/x-mpegURL"),
    ])
    func mimeTypeIsGuessedFromTheExtension(url: String, expected: String) {
        #expect(guessMimeType(url) == expected)
    }

    @Test
    func unknownExtensionsHaveNoMimeType() {
        #expect(guessMimeType("https://x/a.jpg?w=100") == nil)
        #expect(guessMimeType("https://x/a") == nil)
    }

    @Test
    func providerNameIsTheRegistrableLabel() {
        #expect(providerName("https://www.youtube.com/embed/abc") == "Youtube")
        #expect(providerName("https://player.vimeo.com/video/1") == "Vimeo")
        #expect(providerName("https://localhost/x") == "Localhost")
        #expect(providerName("not a url") == "Embed")
    }
}
