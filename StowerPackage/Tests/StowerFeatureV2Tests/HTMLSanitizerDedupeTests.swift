import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct HTMLSanitizerDedupeTests {
    private func figure(_ url: String) -> ReaderBlock {
        .figure(media: MediaDescriptor(kind: .image, sourceURL: url))
    }

    @Test
    func mediaIdentityIgnoresResizeParametersAndHostCase() {
        #expect(
            mediaIdentity("https://CDN.example.com/photos/a.jpg?w=750")
                == mediaIdentity("https://cdn.example.com/photos/a.jpg?w=1736&fm=webp")
        )
        #expect(mediaIdentity("https://cdn.example.com/a.jpg") != mediaIdentity("https://cdn.example.com/b.jpg"))
        #expect(mediaIdentity("https://one.example.com/a.jpg") != mediaIdentity("https://two.example.com/a.jpg"))
    }

    @Test
    func mediaIdentityFallsBackToTheWholeStringWhenThereIsNoHostOrPath() {
        #expect(mediaIdentity("not a url") == "not a url")
        #expect(mediaIdentity("https://example.com") == "https://example.com")
    }

    @Test
    func theSamePhotoAtTwoSizesIsKeptOnce() {
        let blocks = dedupeBlocks([
            figure("https://cdn.example.com/a.jpg?w=1736"),
            .paragraph([.text("Caption")]),
            figure("https://cdn.example.com/a.jpg?w=750"),
            figure("https://cdn.example.com/b.jpg"),
        ])

        #expect(blocks == [
            figure("https://cdn.example.com/a.jpg?w=1736"),
            .paragraph([.text("Caption")]),
            figure("https://cdn.example.com/b.jpg"),
        ])
    }

    @Test
    func repeatedProseIsOnlyCollapsedWhenConsecutive() {
        let yes = ReaderBlock.paragraph([.text("Yes.")])
        let question = ReaderBlock.paragraph([.text("Is it?")])

        // Back-to-back duplicates are a parsing artifact…
        #expect(dedupeBlocks([yes, yes, question]) == [yes, question])
        // …but a refrain that recurs later is the author's.
        #expect(dedupeBlocks([yes, question, yes]) == [yes, question, yes])
    }

    @Test
    func mediaAndEmbedListsKeepTheFirstOfEachIdentity() {
        let media = dedupeMedia([
            MediaDescriptor(kind: .image, sourceURL: "https://cdn.example.com/a.jpg?w=1"),
            MediaDescriptor(kind: .image, sourceURL: "https://cdn.example.com/a.jpg?w=2"),
            MediaDescriptor(kind: .image, sourceURL: "https://cdn.example.com/b.jpg"),
        ])
        #expect(media.map(\.sourceURL) == [
            "https://cdn.example.com/a.jpg?w=1",
            "https://cdn.example.com/b.jpg",
        ])

        let embeds = dedupeEmbeds([
            EmbedDescriptor(provider: "YouTube", embedURL: "https://youtube.com/embed/1"),
            EmbedDescriptor(provider: "YouTube", embedURL: "https://youtube.com/embed/1"),
            EmbedDescriptor(provider: "Vimeo", embedURL: "https://vimeo.com/2"),
        ])
        #expect(embeds.map(\.embedURL) == ["https://youtube.com/embed/1", "https://vimeo.com/2"])
    }
}
