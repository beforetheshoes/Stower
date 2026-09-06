import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing
import ZIPFoundation

struct EPUBBuilderTests {
    // MARK: - Fixtures

    private static let modified = Date(timeIntervalSince1970: 1_700_000_000)
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])

    private func makeItem(
        title: String = "A Test <Article> & More",
        heroImageURL: String? = "https://example.com/hero.jpg"
    ) -> SavedItem {
        SavedItem(
            title: title,
            content: "Body",
            id: UUID(uuidString: "0B8A2B4E-4C12-4E4F-9C3D-1234567890AB")!,
            sourceURL: "https://example.com/post?a=1&b=2",
            canonicalURL: "https://example.com/post",
            renderFormat: .structuredV1,
            heroImageURL: heroImageURL,
            author: "Jane \"Q\" Doe",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000),
            siteName: "Example & Sons",
            createdAt: Self.modified
        )
    }

    private func makeDocument() -> ReaderDocument {
        ReaderDocument(
            title: "A Test <Article> & More",
            blocks: [
                .heading(level: 1, inlines: [.text("Intro & Basics")]),
                .paragraph([
                    .text("Hello "),
                    .strong("bold"),
                    .text(" "),
                    .emphasis("em"),
                    .lineBreak,
                    .code("x < y"),
                    .text(" "),
                    .strikethrough("gone"),
                    .text(" "),
                    .link(label: "safe", url: "https://example.com/a?b=1&c=2"),
                    .text(" "),
                    .link(label: "unsafe", url: "javascript:alert(1)"),
                ]),
                .list(ordered: true, items: [[.text("one")], [.text("two")]]),
                .list(ordered: false, items: [[.text("bullet")]]),
                .blockquote([.text("quoted")]),
                .code(language: "swift", code: "let a = 1 < 2 && true"),
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: "https://example.com/pic.png",
                    caption: "Caption here",
                    altText: "A picture"
                )),
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: "https://example.com/pic.png",
                    altText: "Same picture again"
                )),
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: "https://example.com/missing.png",
                    altText: "Missing alt"
                )),
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: "stower://pdf-page/1",
                    localURL: "/tmp/does-not-matter/pdf-page-1.jpg"
                )),
                .video(media: MediaDescriptor(
                    kind: .video,
                    sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    posterURL: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
                    caption: "A video",
                    providerName: "YouTube",
                    providerVideoID: "dQw4w9WgXcQ"
                )),
                .video(media: MediaDescriptor(
                    kind: .video,
                    sourceURL: "https://example.com/clip.mp4",
                    caption: "Clip"
                )),
                .embed(EmbedDescriptor(provider: "Twitter", embedURL: "https://twitter.com/x/status/1")),
                .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 & 3 |"),
                .horizontalRule,
                .callout(title: "Note", inlines: [.text("Careful")]),
                .heading(level: 2, inlines: [.text("Second"), .text(" section")]),
                .heading(level: 3, inlines: [.text("Too deep for the TOC")]),
                .paragraph([.text("Control\u{0000}char\u{0007}here")]),
            ]
        )
    }

    private func makeImages() -> [String: EPUBImage] {
        var images = [String: EPUBImage]()
        images["https://example.com/hero.jpg"] = EPUBImage(data: Self.jpegBytes, format: .jpeg)
        images["https://example.com/pic.png"] = EPUBImage(data: Self.pngBytes, format: .png)
        images["stower://pdf-page/1"] = EPUBImage(data: Self.jpegBytes, format: .jpeg)
        images["https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"] = EPUBImage(data: Self.jpegBytes, format: .jpeg)
        return images
    }

    private func makePackage() -> EPUBPackage {
        EPUBBuilder.makePackage(
            item: makeItem(),
            document: makeDocument(),
            images: makeImages(),
            modified: Self.modified
        )
    }

    private func entries(in data: Data) throws -> [(path: String, isCompressed: Bool, data: Data)] {
        let archive = try Archive(data: data, accessMode: .read)
        return try archive.map { entry in
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            return (entry.path, entry.isCompressed, bytes)
        }
    }

    // MARK: - Container rules

    @Test
    func mimetypeIsFirstStoredEntryWithExactContent() throws {
        let data = try EPUBBuilder.data(for: makePackage())
        let entries = try entries(in: data)
        let first = try #require(entries.first)
        #expect(first.path == "mimetype")
        #expect(!first.isCompressed)
        #expect(String(bytes: first.data, encoding: .utf8) == "application/epub+zip")
        #expect(entries.dropFirst().allSatisfy { $0.isCompressed })
    }

    @Test
    func packageContainsRequiredFiles() throws {
        let package = makePackage()
        let paths = package.entries.map(\.path)
        #expect(paths.contains("META-INF/container.xml"))
        #expect(paths.contains("OEBPS/content.opf"))
        #expect(paths.contains("OEBPS/nav.xhtml"))
        #expect(paths.contains("OEBPS/chapter.xhtml"))
        #expect(paths.contains("OEBPS/style.css"))
        #expect(paths.contains("OEBPS/images/cover.jpg"))
        #expect(paths.contains("OEBPS/images/img-1.png"))
        #expect(paths.contains("OEBPS/images/img-2.jpg"))
        #expect(paths.contains("OEBPS/images/img-3.jpg"))
        #expect(!paths.contains("OEBPS/images/img-4.jpg"))
        let container = try #require(package.string(at: "META-INF/container.xml"))
        #expect(container.contains("full-path=\"OEBPS/content.opf\""))
    }

    @Test
    func opfCarriesMetadataManifestAndSpine() throws {
        let opf = try #require(makePackage().string(at: "OEBPS/content.opf"))
        #expect(opf.contains("<dc:identifier id=\"pub-id\">urn:uuid:0b8a2b4e-4c12-4e4f-9c3d-1234567890ab</dc:identifier>"))
        #expect(opf.contains("<dc:title>A Test &lt;Article&gt; &amp; More</dc:title>"))
        #expect(opf.contains("<dc:creator>Jane &quot;Q&quot; Doe</dc:creator>"))
        #expect(opf.contains("<dc:publisher>Example &amp; Sons</dc:publisher>"))
        #expect(opf.contains("<dc:source>https://example.com/post</dc:source>"))
        #expect(opf.contains("<dc:date>2020-09-13T12:26:40Z</dc:date>"))
        #expect(opf.contains("<meta property=\"dcterms:modified\">2023-11-14T22:13:20Z</meta>"))
        #expect(opf.contains("properties=\"nav\""))
        #expect(opf.contains("id=\"cover-image\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\""))
        #expect(opf.contains("id=\"img-1\" href=\"images/img-1.png\" media-type=\"image/png\""))
        #expect(opf.contains("<itemref idref=\"chapter\"/>"))
    }

    @Test
    func everyXMLEntryIsWellFormed() throws {
        let package = makePackage()
        for path in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml"] {
            let data = try #require(package[path])
            let checker = WellFormednessChecker()
            let parser = XMLParser(data: data)
            parser.delegate = checker
            let parsed = parser.parse()
            #expect(parsed, "\(path) failed to parse: \(checker.error?.localizedDescription ?? "unknown")")
            #expect(checker.error == nil, "\(path): \(checker.error?.localizedDescription ?? "")")
        }
    }

    // MARK: - Chapter content

    @Test
    func chapterRendersBlocksAsXHTML() throws {
        let chapter = try #require(makePackage().string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<h1 id=\"block-0\">Intro &amp; Basics</h1>"))
        #expect(chapter.contains("<strong>bold</strong> <em>em</em><br/><code>x &lt; y</code> <s>gone</s>"))
        #expect(chapter.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">safe</a>"))
        #expect(chapter.contains(" unsafe</p>"))
        #expect(!chapter.contains("javascript:"))
        #expect(chapter.contains("<ol id=\"block-2\"><li>one</li><li>two</li></ol>"))
        #expect(chapter.contains("<ul id=\"block-3\"><li>bullet</li></ul>"))
        #expect(chapter.contains("<blockquote id=\"block-4\"><p>quoted</p></blockquote>"))
        #expect(chapter.contains("<pre id=\"block-5\"><code class=\"language-swift\">let a = 1 &lt; 2 &amp;&amp; true</code></pre>"))
        #expect(chapter.contains("<hr id=\"block-14\"/>"))
        #expect(chapter.contains("<aside class=\"callout\" id=\"block-15\"><h4>Note</h4><p>Careful</p></aside>"))
        #expect(chapter.contains("<th>A</th><th>B</th>"))
        #expect(chapter.contains("<td>2 &amp; 3</td>"))
        #expect(chapter.contains("<aside class=\"embed\" id=\"block-12\"><p>Twitter: <a href=\"https://twitter.com/x/status/1\">"))
        #expect(!chapter.contains("target="))
    }

    @Test
    func chapterHeaderIncludesMetadataAndCover() throws {
        let chapter = try #require(makePackage().string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<h1>A Test &lt;Article&gt; &amp; More</h1>"))
        #expect(chapter.contains("<p class=\"byline\">by Jane &quot;Q&quot; Doe</p>"))
        #expect(chapter.contains("<a href=\"https://example.com/post?a=1&amp;b=2\">Example &amp; Sons</a>"))
        #expect(chapter.contains("<p class=\"date\">Published "))
        #expect(chapter.contains("<figure class=\"hero\"><img src=\"images/cover.jpg\" alt=\"\"/></figure>"))
    }

    @Test
    func imagesAreEmbeddedDedupedAndFallBackToAltText() throws {
        let chapter = try #require(makePackage().string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<figure class=\"figure\" id=\"block-6\"><img src=\"images/img-1.png\" alt=\"A picture\"/><figcaption>Caption here</figcaption></figure>"))
        #expect(chapter.contains("<figure class=\"figure\" id=\"block-7\"><img src=\"images/img-1.png\" alt=\"Same picture again\"/></figure>"))
        #expect(chapter.contains("<p class=\"missing-image\" id=\"block-8\"><em>[Image: Missing alt]</em></p>"))
        #expect(chapter.contains("<figure class=\"pdf-page\" id=\"block-9\"><img src=\"images/img-2.jpg\" alt=\"\"/></figure>"))
    }

    @Test
    func videosRenderAsLinks() throws {
        let chapter = try #require(makePackage().string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<figure class=\"video\" id=\"block-10\"><a href=\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"><img src=\"images/img-3.jpg\" alt=\"A video\"/></a>"))
        #expect(chapter.contains("<p class=\"video-link\" id=\"block-11\"><a href=\"https://example.com/clip.mp4\">Watch video: Clip</a></p>"))
    }

    @Test
    func youTubeVideoWithoutPosterRendersPlainLink() throws {
        let document = ReaderDocument(title: "T", blocks: [
            .video(media: MediaDescriptor(
                kind: .video,
                sourceURL: "https://youtu.be/dQw4w9WgXcQ",
                providerName: "YouTube",
                providerVideoID: "dQw4w9WgXcQ"
            )),
        ])
        let package = EPUBBuilder.makePackage(item: makeItem(), document: document, images: [:], modified: Self.modified)
        let chapter = try #require(package.string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<p class=\"video-link\" id=\"block-0\"><a href=\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\">Watch on YouTube</a></p>"))
        // A YouTube-first document suppresses the hero, mirroring the reader.
        #expect(!package.entries.contains { $0.path.hasPrefix("OEBPS/images/cover") })
    }

    @Test
    func controlCharactersAreStripped() throws {
        let chapter = try #require(makePackage().string(at: "OEBPS/chapter.xhtml"))
        #expect(chapter.contains("<p id=\"block-18\">Controlcharhere</p>"))
        #expect(EPUBBuilder.xmlSafe("a\tb\nc\u{0001}d\u{FFFE}e") == "a\tb\ncde")
    }

    @Test
    func navigationListsChapterAndTopLevelHeadings() throws {
        let nav = try #require(makePackage().string(at: "OEBPS/nav.xhtml"))
        #expect(nav.contains("<nav epub:type=\"toc\""))
        #expect(nav.contains("<a href=\"chapter.xhtml\">A Test &lt;Article&gt; &amp; More</a>"))
        #expect(nav.contains("<a href=\"chapter.xhtml#block-0\">Intro &amp; Basics</a>"))
        #expect(nav.contains("<a href=\"chapter.xhtml#block-16\">Second section</a>"))
        #expect(!nav.contains("Too deep"))
    }

    @Test
    func navigationWithoutHeadingsHasNoNestedList() throws {
        let document = ReaderDocument(title: "T", blocks: [.paragraph([.text("only")])])
        let package = EPUBBuilder.makePackage(item: makeItem(heroImageURL: nil), document: document, images: [:], modified: Self.modified)
        let nav = try #require(package.string(at: "OEBPS/nav.xhtml"))
        #expect(nav.contains("<li><a href=\"chapter.xhtml\">A Test &lt;Article&gt; &amp; More</a></li>"))
        #expect(nav.components(separatedBy: "<ol>").count == 2)
    }

    // MARK: - Images and filenames

    @Test
    func detectFormatSniffsMagicBytesThenDeclaredType() {
        #expect(EPUBImage.detectFormat(data: Self.pngBytes, declaredMIMEType: nil) == .png)
        #expect(EPUBImage.detectFormat(data: Self.jpegBytes, declaredMIMEType: "image/png") == .jpeg)
        #expect(EPUBImage.detectFormat(data: Data("GIF89a".utf8), declaredMIMEType: nil) == .gif)
        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0, 0, 0, 0])
        webp.append(contentsOf: "WEBP".utf8)
        #expect(EPUBImage.detectFormat(data: webp, declaredMIMEType: nil) == .webp)
        #expect(EPUBImage.detectFormat(data: Data("  <?xml?><svg xmlns=\"x\"/>".utf8), declaredMIMEType: nil) == .svg)
        #expect(EPUBImage.detectFormat(data: Data([1, 2, 3]), declaredMIMEType: "image/jpeg") == .jpeg)
        #expect(EPUBImage.detectFormat(data: Data([1, 2, 3]), declaredMIMEType: "text/html") == nil)
        #expect(EPUBImage.detectFormat(data: Data(), declaredMIMEType: nil) == nil)
    }

    @Test
    func suggestedFilenameIsSafeAndBounded() {
        #expect(EPUBBuilder.suggestedFilename(for: "  Hello / World: Part\\2 ") == "Hello - World- Part-2")
        #expect(EPUBBuilder.suggestedFilename(for: "...hidden") == "hidden")
        #expect(EPUBBuilder.suggestedFilename(for: "   ") == "Article")
        #expect(EPUBBuilder.suggestedFilename(for: "a\u{0001}b\nc") == "a b c")
        let long = String(repeating: "x", count: 200)
        #expect(EPUBBuilder.suggestedFilename(for: long).count == 80)
        #expect(makePackage().suggestedFilename == "A Test <Article> & More")
    }

    @Test
    func writeProducesReadableArchiveOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.epub")
        try EPUBBuilder.write(makePackage(), to: url)
        let entries = try entries(in: Data(contentsOf: url))
        #expect(entries.first?.path == "mimetype")
        #expect(entries.count == makePackage().entries.count)
    }
}

private final class WellFormednessChecker: NSObject, XMLParserDelegate {
    var error: Error?

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
