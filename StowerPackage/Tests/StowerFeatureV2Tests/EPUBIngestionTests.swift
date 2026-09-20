import CustomDump
import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

struct EPUBPackageParserTests {
    @Test
    func packagePath_readsRootfile() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        #expect(try EPUBPackageParser.packagePath(containerXML: container) == "OEBPS/content.opf")
    }

    @Test
    func parse_readsMetadataSpineAndCover() throws {
        let package = try EPUBPackageParser.parse(opfXML: EPUBFixture.opf, opfPath: "OEBPS/content.opf")

        #expect(package.title == "The Test Book")
        #expect(package.author == "Ada Writer")
        #expect(package.publisher == "Fixture Press")
        #expect(package.publishedAt == Date(timeIntervalSince1970: 1_398_902_400))
        // The navigation document and the non-linear item stay out of the
        // reading order.
        expectNoDifference(
            package.spine.map(\.path),
            ["OEBPS/text/chapter1.xhtml", "OEBPS/text/chapter 2.xhtml"]
        )
        #expect(package.coverImagePath == "OEBPS/images/cover.jpg")
        #expect(package.navigationPath == "OEBPS/nav.xhtml")
        #expect(package.ncxPath == "OEBPS/toc.ncx")
    }

    @Test
    func parse_findsEPUB2CoverAndPrefixedTags() throws {
        let opf = """
        <opf:package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <opf:metadata>
            <dc:title>Prefixed</dc:title>
            <dc:date>1999</dc:date>
            <opf:meta name="cover" content="cover-img"/>
          </opf:metadata>
          <opf:manifest>
            <opf:item id="cover-img" href="cover.png" media-type="image/png"/>
            <opf:item id="c1" href="c1.html" media-type="application/xhtml+xml"/>
          </opf:manifest>
          <opf:spine><opf:itemref idref="c1"/></opf:spine>
        </opf:package>
        """
        let package = try EPUBPackageParser.parse(opfXML: opf, opfPath: "content.opf")

        #expect(package.title == "Prefixed")
        #expect(package.coverImagePath == "cover.png")
        #expect(package.spine.map(\.path) == ["c1.html"])
        #expect(package.publishedAt == Date(timeIntervalSince1970: 915_148_800))
    }

    @Test
    func navigationLabels_keepFirstLabelPerDocument() throws {
        let labels = try EPUBPackageParser.navigationLabels(
            navXHTML: EPUBFixture.nav,
            navPath: "OEBPS/nav.xhtml"
        )
        var expected = [String: String]()
        expected["OEBPS/text/chapter1.xhtml"] = "One: Arrival"
        expected["OEBPS/text/chapter 2.xhtml"] = "Two: Departure"
        expectNoDifference(labels, expected)
    }

    @Test
    func ncxLabels_readNavPoints() throws {
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="a"><navLabel><text>First</text></navLabel><content src="text/one.html#start"/></navPoint>
            <navPoint id="b"><navLabel><text>Second</text></navLabel><content src="text/two.html"/></navPoint>
          </navMap>
        </ncx>
        """
        let labels = try EPUBPackageParser.ncxLabels(ncxXML: ncx, ncxPath: "OEBPS/toc.ncx")
        expectNoDifference(labels, ["OEBPS/text/one.html": "First", "OEBPS/text/two.html": "Second"])
    }

    @Test
    func hasEncryptedContent_ignoresFontObfuscation() throws {
        let fonts = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
          </EncryptedData>
        </encryption>
        """
        let locked = fonts.replacingOccurrences(
            of: "http://www.idpf.org/2008/embedding",
            with: "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
        )
        #expect(try EPUBPackageParser.hasEncryptedContent(encryptionXML: fonts) == false)
        #expect(try EPUBPackageParser.hasEncryptedContent(encryptionXML: locked))
    }

    @Test(arguments: [
        ("chapter1.xhtml", "OEBPS/content.opf", "OEBPS/chapter1.xhtml"),
        ("../images/a%20b.png#frag", "OEBPS/text/c.xhtml", "OEBPS/images/a b.png"),
        ("./x/../y.css?v=2", "content.opf", "y.css"),
        ("/abs/z.html", "OEBPS/text/c.xhtml", "abs/z.html"),
    ])
    func resolve_normalizesHrefs(href: String, base: String, expected: String) {
        #expect(EPUBPath.resolve(href, relativeTo: base) == expected)
    }

    @Test(arguments: ["https://example.com/a.png", "data:image/png;base64,AAAA", "../../escape.png", "#top", ""])
    func resolve_rejectsHrefsOutsideTheArchive(href: String) {
        #expect(EPUBPath.resolve(href, relativeTo: "OEBPS/c.xhtml") == nil)
    }
}

struct EPUBIngestionTests {
    @Test
    func ingest_joinsChaptersAndArchivesImages() async throws {
        let url = try EPUBFixture.write(EPUBFixture.bookEntries())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await EPUBIngestor.ingest(url: url)
        let itemID = StowerRepository.stableItemID(from: result.canonicalURL)
        defer { AssetArchiver.deleteArchive(for: itemID) }

        #expect(result.title == "The Test Book")
        #expect(result.author == "Ada Writer")
        #expect(result.siteName == "Fixture Press")
        #expect(result.sourceURL == nil)
        #expect(result.canonicalURL?.hasPrefix(SavedItem.importedBookURLPrefix) == true)
        #expect(result.renderFormat == .structuredV1)
        #expect(result.rawSourceMode == .markdown)
        #expect(result.rawSourceText?.contains("Second chapter text.") == true)
        #expect(result.heroImageURL == "\(WebsiteArchiveUnpacker.heroArchiveURLScheme):epub-img-cover.jpg")

        let marker = EPUBBookArchiver.markerURL(filename: "epub-img-0.png")
        let imagePath = EPUBBookArchiver.imageURL(for: itemID, filename: "epub-img-0.png").path
        expectNoDifference(
            result.document.blocks,
            [
                .heading(level: 1, inlines: [.text("Arrival")]),
                .paragraph([.text("First chapter text.")]),
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: marker,
                    localURL: imagePath,
                    mimeType: "image/png",
                    caption: "A map",
                    altText: "A map"
                )),
                // Chapter two has no heading of its own, so it takes the
                // table of contents label.
                .heading(level: 2, inlines: [.text("Two: Departure")]),
                .paragraph([.text("Second chapter text.")]),
                // The SVG-wrapped image is lifted out, and the zip image it
                // shares with chapter one is archived once.
                .figure(media: MediaDescriptor(
                    kind: .image,
                    sourceURL: marker,
                    localURL: imagePath,
                    mimeType: "image/png"
                )),
            ]
        )
        #expect(result.media.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: imagePath)) == EPUBFixture.pngBytes)
        #expect(
            EPUBBookArchiver.imageURLs(for: itemID).map(\.lastPathComponent).sorted()
                == ["epub-img-0.png", "epub-img-cover.jpg"]
        )
    }

    @Test
    func ingest_sameFileYieldsSameItem() async throws {
        let first = try EPUBFixture.write(EPUBFixture.bookEntries())
        let second = try EPUBFixture.write(EPUBFixture.bookEntries())
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let firstResult = try await EPUBIngestor.ingest(url: first)
        let secondResult = try await EPUBIngestor.ingest(url: second)
        defer { AssetArchiver.deleteArchive(for: StowerRepository.stableItemID(from: firstResult.canonicalURL)) }

        #expect(firstResult.canonicalURL == secondResult.canonicalURL)
    }

    @Test
    func ingest_usesFilenameWhenPackageHasNoTitle() async throws {
        var entries = EPUBFixture.bookEntries()
        entries["OEBPS/content.opf"] = Data(
            EPUBFixture.opf.replacingOccurrences(of: "<dc:title>The Test Book</dc:title>", with: "").utf8
        )
        let url = try EPUBFixture.write(entries, filename: "My Novel.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await EPUBIngestor.ingest(url: url)
        defer { AssetArchiver.deleteArchive(for: StowerRepository.stableItemID(from: result.canonicalURL)) }

        #expect(result.title == "My Novel")
    }

    @Test
    func ingest_dropsATitlePageHeadingThatRepeatsTheTitle() async throws {
        var entries = EPUBFixture.bookEntries()
        entries["OEBPS/text/chapter1.xhtml"] = Data(
            EPUBFixture.chapter("<h1>the test book</h1><p>First chapter text.</p>").utf8
        )
        let url = try EPUBFixture.write(entries)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await EPUBIngestor.ingest(url: url)
        defer { AssetArchiver.deleteArchive(for: StowerRepository.stableItemID(from: result.canonicalURL)) }

        #expect(result.document.blocks.first == .paragraph([.text("First chapter text.")]))
    }

    @Test
    func ingest_rejectsProtectedBooks() async throws {
        var entries = EPUBFixture.bookEntries()
        entries["META-INF/encryption.xml"] = Data("""
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
          </EncryptedData>
        </encryption>
        """.utf8)
        let url = try EPUBFixture.write(entries)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await #expect(throws: EPUBIngestionError.protectedContent) {
            try await EPUBIngestor.ingest(url: url)
        }
    }

    @Test
    func ingest_rejectsFilesThatAreNotEPUBs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notZip = directory.appendingPathComponent("fake.epub")
        try Data("plain text".utf8).write(to: notZip)

        await #expect(throws: EPUBIngestionError.unreadable) {
            try await EPUBIngestor.ingest(url: notZip)
        }

        let noPackage = try EPUBFixture.write(["mimetype": Data("application/epub+zip".utf8)])
        defer { try? FileManager.default.removeItem(at: noPackage.deletingLastPathComponent()) }
        await #expect(throws: EPUBIngestionError.missingPackage) {
            try await EPUBIngestor.ingest(url: noPackage)
        }
    }

    @Test
    func ingest_readsBooksStowerExported() async throws {
        let item = SavedItem(
            title: "Round Trip",
            content: "",
            sourceURL: "https://example.com/post",
            renderFormat: .structuredV1,
            author: "Sam Author"
        )
        let document = ReaderDocument(
            title: "Round Trip",
            blocks: [
                .heading(level: 2, inlines: [.text("Section")]),
                .paragraph([.text("Exported body text.")]),
            ],
            version: 1,
            sourceURL: item.sourceURL,
            canonicalURL: nil
        )
        let package = EPUBBuilder.makePackage(
            item: item,
            document: document,
            images: [:],
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("round-trip.epub")
        try EPUBBuilder.write(package, to: url)

        let result = try await EPUBIngestor.ingest(url: url)
        defer { AssetArchiver.deleteArchive(for: StowerRepository.stableItemID(from: result.canonicalURL)) }

        #expect(result.title == "Round Trip")
        #expect(result.author == "Sam Author")
        #expect(result.plainText.contains("Exported body text."))
    }
}

/// Opt-in check against real books: set `STOWER_EPUB_SAMPLE_PATHS` to one or
/// more `.epub` paths separated by `:`.
struct EPUBSampleIngestionTests {
    static var samplePaths: [String] {
        (ProcessInfo.processInfo.environment["STOWER_EPUB_SAMPLE_PATHS"] ?? "")
            .split(separator: ":")
            .map(String.init)
    }

    @Test(.enabled(if: !samplePaths.isEmpty), arguments: samplePaths)
    func ingest_realBook(path: String) async throws {
        let result = try await EPUBIngestor.ingest(url: URL(fileURLWithPath: path))
        let itemID = StowerRepository.stableItemID(from: result.canonicalURL)
        defer { AssetArchiver.deleteArchive(for: itemID) }

        let headings = result.document.blocks.filter {
            if case .heading = $0 {
                return true
            }
            return false
        }
        print(
            """
            EPUB sample: \(result.title) — \(result.author ?? "no author")
              blocks=\(result.document.blocks.count) headings=\(headings.count) \
            images=\(result.media.count) words=\(result.plainText.split(separator: " ").count) \
            cover=\(result.heroImageURL ?? "none") syncBytes=\(result.rawSourceText?.utf8.count ?? 0)
            """
        )
        #expect(!result.document.blocks.isEmpty)
        #expect(!result.plainText.isEmpty)

        // With `STOWER_EPUB_SAMPLE_OUTPUT` set, also write the reader page and
        // its images there so the rendering can be looked at in a browser.
        if let output = ProcessInfo.processInfo.environment["STOWER_EPUB_SAMPLE_OUTPUT"] {
            let directory = URL(fileURLWithPath: output).appendingPathComponent(itemID.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let item = SavedItem(
                title: result.title,
                content: "",
                canonicalURL: result.canonicalURL,
                renderFormat: result.renderFormat,
                author: result.author,
                siteName: result.siteName
            )
            let html = ReaderDocumentHTMLBuilder.buildReaderHTML(
                item: item,
                document: result.document,
                appearance: ReaderAppearanceSettings(),
                pageWidth: 700
            )
            try Data(html.utf8).write(to: directory.appendingPathComponent("index.html"))
            for image in EPUBBookArchiver.imageURLs(for: itemID) {
                let copy = directory.appendingPathComponent(image.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: image, to: copy)
            }
        }
    }
}

struct EPUBBookArchiverTests {
    @Test(arguments: [
        ("stower://epub-image/epub-img-3.png", "epub-img-3.png"),
        ("stower://epub-image/epub-img-cover.jpg", "epub-img-cover.jpg"),
    ])
    func imageFilename_acceptsMarkers(marker: String, expected: String) {
        #expect(EPUBBookArchiver.imageFilename(fromMarker: marker) == expected)
    }

    @Test(arguments: [
        "https://example.com/epub-img-0.png",
        "stower://epub-image/../document.pdf",
        "stower://epub-image/epub-img-0/../../x",
        "stower://epub-image/index.html",
        "stower://pdf-page/0",
    ])
    func imageFilename_rejectsEverythingElse(marker: String) {
        #expect(EPUBBookArchiver.imageFilename(fromMarker: marker) == nil)
    }

    @Test
    func symlinkImages_linksOnlyChapterImages() throws {
        let itemID = UUID()
        defer { AssetArchiver.deleteArchive(for: itemID) }
        try EPUBBookArchiver.archiveImage(EPUBFixture.pngBytes, filename: "epub-img-0.png", itemID: itemID)
        try Data("other".utf8).write(
            to: AssetArchiver.archiveDirectory(for: itemID).appendingPathComponent("notes.txt")
        )
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }

        #expect(EPUBBookArchiver.symlinkImages(for: itemID, into: target) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["epub-img-0.png"])
        #expect(try Data(contentsOf: target.appendingPathComponent("epub-img-0.png")) == EPUBFixture.pngBytes)
    }
}

// MARK: - Fixture

enum EPUBFixture {
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])

    static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    static let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:fixture</dc:identifier>
        <dc:title>The Test Book</dc:title>
        <dc:creator>Ada Writer</dc:creator>
        <dc:publisher>Fixture Press</dc:publisher>
        <dc:date>2014-05-01</dc:date>
        <dc:language>en</dc:language>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="c1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/chapter%202.xhtml" media-type="application/xhtml+xml"/>
        <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
        <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        <item id="map" href="images/map.png" media-type="image/png"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="nav"/>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
        <itemref idref="notes" linear="no"/>
      </spine>
    </package>
    """

    static let nav = """
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <body>
        <nav epub:type="toc">
          <ol>
            <li><a href="text/chapter1.xhtml">One: Arrival</a>
              <ol><li><a href="text/chapter1.xhtml#part2">A sub-section</a></li></ol>
            </li>
            <li><a href="text/chapter%202.xhtml">Two: Departure</a></li>
          </ol>
        </nav>
      </body>
    </html>
    """

    static func chapter(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head><body>\(body)</body></html>
        """
    }

    static func bookEntries() -> [String: Data] {
        var entries = [String: Data]()
        entries["mimetype"] = Data("application/epub+zip".utf8)
        entries["META-INF/container.xml"] = Data(container.utf8)
        entries["OEBPS/content.opf"] = Data(opf.utf8)
        entries["OEBPS/nav.xhtml"] = Data(nav.utf8)
        entries["OEBPS/text/chapter1.xhtml"] = Data(chapter("""
        <h1>Arrival</h1><p>First chapter text.</p>
        <img src="../images/map.png" alt="A map"/>
        <img src="https://example.com/remote.png" alt="Remote"/>
        """).utf8)
        entries["OEBPS/text/chapter 2.xhtml"] = Data(chapter("""
        <p>Second chapter text.</p>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
          <image xlink:href="../images/map.png"/>
        </svg>
        """).utf8)
        entries["OEBPS/text/notes.xhtml"] = Data(chapter("<p>Non-linear notes.</p>").utf8)
        entries["OEBPS/images/cover.jpg"] = jpegBytes
        entries["OEBPS/images/map.png"] = pngBytes
        return entries
    }

    /// Writes `entries` as a zip inside a fresh temporary directory and
    /// returns the file URL. Entries are written in sorted order with a
    /// fixed date so identical input produces identical bytes.
    static func write(_ entries: [String: Data], filename: String = "fixture.epub") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let package = EPUBPackage(
            entries: entries.keys.sorted().map { EPUBEntry(path: $0, data: entries[$0]!, compress: true) },
            suggestedFilename: filename,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try EPUBBuilder.write(package, to: url)
        return url
    }
}
