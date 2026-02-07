import Foundation
import Testing
@testable import StowerFeature

@Suite
struct AddItemExtractorTests {
    @Test
    func extractionPipelineBuildsStructuredDocumentWithMedia() async throws {
        let html = """
        <html>
          <head>
            <title>Phantom Obligation | Terry Godier</title>
            <meta property="og:title" content="Phantom Obligation" />
            <meta property="og:site_name" content="Terry Godier" />
            <meta property="article:published_time" content="2026-01-26T00:00:00.000Z" />
          </head>
          <body>
            <article>
              <h1>Phantom Obligation</h1>
              <p>There is no behind. Nobody is waiting.</p>
              <img src="https://example.com/image.jpg" alt="A calm library" />
              <p>Watch this talk:</p>
              <iframe src="https://www.youtube.com/embed/abc"></iframe>
            </article>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/post")!
        )

        #expect(result.title == "Phantom Obligation")
        #expect(result.siteName == "Terry Godier")
        #expect(result.processingState == .ready || result.processingState == .partial)
        #expect(result.document.blocks.count >= 3)
        #expect(result.media.contains(where: { $0.kind == .image }))
        #expect(result.embeds.contains(where: { $0.provider == "Youtube" || $0.provider == "YouTube" }))
    }

    @Test
    func extractionFallbackBuildsMultipleParagraphBlocks() async throws {
        let html = """
        <html>
          <head><title>Fallback Article</title></head>
          <body>
            <div class="sidebar">All Items 47 Daring Fireball 12 Pixel Envy 8</div>
            <div class="article-content">
              <div>First sentence of the story. Second sentence keeps reading natural.</div>
              <div>Another paragraph with enough text to verify paragraph splitting works and does not collapse all content into one giant block.</div>
              <img src="https://example.com/cover.jpg" alt="Cover image" />
            </div>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/fallback")!
        )

        let paragraphCount = result.document.blocks.reduce(into: 0) { count, block in
            if case .paragraph = block { count += 1 }
        }

        #expect(paragraphCount >= 2)
        #expect(result.media.contains(where: { $0.kind == .image }))
        #expect(!result.plainText.contains("All Items 47 Daring Fireball"))
    }

    @Test
    func extractionSanitizerRemovesDenseNavigationNoiseAndUnescapesEntities() async throws {
        let html = """
        <html>
          <head><title>Noise Cleanup</title></head>
          <body>
            <main>
              <div>All Items47Daring Fireball12Pixel Envy8Kottke15Stratechery4 47 unread items Updated 5 min ago</div>
              <p>There&#x27;s a particular kind of guilt that visits me when I open my feed reader.</p>
              <p>You can put these down.</p>
            </main>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/noise-cleanup")!
        )

        #expect(!result.plainText.lowercased().contains("all items47daring fireball12pixel envy"))
        #expect(result.plainText.contains("There's a particular kind of guilt"))
        #expect(result.plainText.contains("You can put these down."))
    }

    @Test
    func extractionPrefersContentImagesAndCapturesFigureCaption() async throws {
        let html = """
        <html>
          <head><title>Image Priority</title></head>
          <body>
            <article>
              <img src="https://example.com/author-avatar.jpg" width="48" height="48" alt="Author photo" class="author-avatar"/>
              <figure>
                <img data-src="https://example.com/hero.webp" alt="Main chart" />
                <figcaption>Revenue trend, 2020-2026</figcaption>
              </figure>
            </article>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/images")!
        )

        #expect(!result.media.contains(where: { $0.sourceURL.contains("avatar") }))
        #expect(result.media.contains(where: { $0.sourceURL.contains("hero.webp") }))
        #expect(result.media.contains(where: { $0.caption == "Revenue trend, 2020-2026" }))
    }

    @Test
    func extractionReadsImageInsideNoscriptFallback() async throws {
        let html = """
        <html>
          <body>
            <article>
              <noscript>
                <img src="https://example.com/fallback-image.jpg" alt="Fallback image"/>
              </noscript>
            </article>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/noscript")!
        )

        #expect(result.media.contains(where: { $0.sourceURL.contains("fallback-image.jpg") }))
    }

    @Test
    func extractionKeepsSubstackImageLinksNestedInParagraphs() async throws {
        let html = """
        <html>
          <body>
            <article>
              <p>
                <a href="https://substackcdn.com/image/fetch/$s_!6M7R!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fec5279eb-e12f-408f-8727-ffcc7b1f3ba7_2816x1536.jpeg" class="image-link image2">
                  <picture>
                    <source type="image/webp" srcset="https://substackcdn.com/image/fetch/$s_!6M7R!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fec5279eb-e12f-408f-8727-ffcc7b1f3ba7_2816x1536.jpeg 1456w" />
                    <img src="https://substackcdn.com/image/fetch/$s_!6M7R!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fec5279eb-e12f-408f-8727-ffcc7b1f3ba7_2816x1536.jpeg" />
                  </picture>
                </a>
              </p>
            </article>
          </body>
        </html>
        """

        let result = try await ExtractionPipelineClient.live.extract(
            html,
            URL(string: "https://example.com/substack-image-links")!
        )

        #expect(result.media.contains(where: { $0.sourceURL.contains("ec5279eb-e12f-408f-8727-ffcc7b1f3ba7") }))
        #expect(result.document.blocks.contains { block in
            if case .figure = block { return true }
            return false
        })
    }
}
