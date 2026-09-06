import Foundation
import StowerData
import ZIPFoundation

/// Bytes for one image that ships inside the EPUB.
struct EPUBImage: Equatable, Sendable {
    enum Format: String, Equatable, Sendable {
        case jpeg = "jpeg"
        case png = "png"
        case gif = "gif"
        case svg = "svg"
        case webp = "webp"

        var mediaType: String {
            switch self {
            case .jpeg:
                "image/jpeg"
            case .png:
                "image/png"
            case .gif:
                "image/gif"
            case .svg:
                "image/svg+xml"
            case .webp:
                "image/webp"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg:
                "jpg"
            case .png:
                "png"
            case .gif:
                "gif"
            case .svg:
                "svg"
            case .webp:
                "webp"
            }
        }
    }

    let data: Data
    let format: Format

    /// Sniffs the leading bytes, then falls back to the MIME type ingestion
    /// recorded. Returns nil for anything that is not a supported raster or
    /// SVG image so the caller can drop it instead of shipping junk.
    static func detectFormat(data: Data, declaredMIMEType: String?) -> Format? {
        if let sniffed = sniff(data) {
            return sniffed
        }
        switch declaredMIMEType?.lowercased() {
        case "image/jpeg", "image/jpg":
            return .jpeg
        case "image/png":
            return .png
        case "image/gif":
            return .gif
        case "image/svg+xml":
            return .svg
        case "image/webp":
            return .webp
        default:
            return nil
        }
    }

    private static func sniff(_ data: Data) -> Format? {
        let head = [UInt8](data.prefix(16))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return .png
        }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return .gif
        }
        if head.count >= 12,
           head.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return .webp
        }
        if let text = String(data: data.prefix(512), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<"), trimmed.lowercased().contains("<svg") {
                return .svg
            }
        }
        return nil
    }
}

struct EPUBEntry: Equatable, Sendable {
    let path: String
    let data: Data
    /// False only for the `mimetype` entry, which the EPUB container spec
    /// requires to be stored verbatim as the first file in the zip.
    let compress: Bool
}

struct EPUBPackage: Equatable, Sendable {
    /// `mimetype` is always first.
    let entries: [EPUBEntry]
    /// Base name without extension, safe for the file system.
    let suggestedFilename: String
    let modified: Date

    subscript(path: String) -> Data? {
        entries.first { $0.path == path }?.data
    }

    func string(at path: String) -> String? {
        self[path].flatMap { String(bytes: $0, encoding: .utf8) }
    }
}

enum EPUBBuilderError: Error, Equatable {
    case archiveUnavailable
}

/// Pure EPUB 3 packager. Takes an article, its block document, and whatever
/// images the caller managed to resolve, and produces the container entries.
/// No file system or network access except in `write(_:to:)`.
enum EPUBBuilder {
    static let mimetype = "application/epub+zip"
    static let containerPath = "META-INF/container.xml"
    static let opfPath = "OEBPS/content.opf"
    static let navPath = "OEBPS/nav.xhtml"
    static let chapterPath = "OEBPS/chapter.xhtml"
    static let stylesheetPath = "OEBPS/style.css"
    static let imagesDirectory = "OEBPS/images"

    // MARK: - Package

    static func makePackage(
        item: SavedItem,
        document: ReaderDocument,
        images: [String: EPUBImage],
        modified: Date
    ) -> EPUBPackage {
        let placed = placeImages(item: item, document: document, images: images)
        let renderer = ChapterRenderer(item: item, document: document, images: placed)

        var entries = [EPUBEntry]()
        entries.append(EPUBEntry(path: "mimetype", data: Data(mimetype.utf8), compress: false))
        entries.append(EPUBEntry(path: containerPath, data: Data(containerXML.utf8), compress: true))
        entries.append(
            EPUBEntry(
                path: opfPath,
                data: Data(opf(item: item, document: document, images: placed, modified: modified).utf8),
                compress: true
            )
        )
        entries.append(EPUBEntry(path: navPath, data: Data(renderer.navigationDocument().utf8), compress: true))
        entries.append(EPUBEntry(path: chapterPath, data: Data(renderer.chapterDocument().utf8), compress: true))
        entries.append(EPUBEntry(path: stylesheetPath, data: Data(stylesheet.utf8), compress: true))
        for image in placed.ordered {
            entries.append(EPUBEntry(path: "\(imagesDirectory)/\(image.filename)", data: image.image.data, compress: true))
        }

        return EPUBPackage(
            entries: entries,
            suggestedFilename: suggestedFilename(for: item.title),
            modified: modified
        )
    }

    /// Writes the package as a zip at `url`, honoring the EPUB ordering and
    /// compression rules.
    static func write(_ package: EPUBPackage, to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        try addEntries(of: package, to: archive)
    }

    /// In-memory variant used by tests.
    static func data(for package: EPUBPackage) throws -> Data {
        let archive = try Archive(accessMode: .create)
        try addEntries(of: package, to: archive)
        guard let data = archive.data else {
            throw EPUBBuilderError.archiveUnavailable
        }
        return data
    }

    private static func addEntries(of package: EPUBPackage, to archive: Archive) throws {
        for entry in package.entries {
            let data = entry.data
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: package.modified,
                compressionMethod: entry.compress ? .deflate : .none
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        }
    }

    // MARK: - Filenames

    /// Turns a title into a base filename: no path separators or control
    /// characters, single spaces, at most 80 characters, never empty.
    static func suggestedFilename(for title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":", "\\":
                scalars.append("-")
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        var name = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Article" : name
    }

    // MARK: - Text safety

    /// Removes code points XML 1.0 forbids. OCR output and copy-pasted text
    /// occasionally carry them, and one is enough for a reader to refuse
    /// the whole file.
    static func xmlSafe(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isXMLLegal(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isXMLLegal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:
            true
        case 0x20...0xD7FF:
            true
        case 0xE000...0xFFFD:
            true
        case 0x10000...0x10FFFF:
            true
        default:
            false
        }
    }

    static func escape(_ text: String) -> String {
        ReaderDocumentHTMLBuilder.escapeHTML(xmlSafe(text))
    }

    // MARK: - Image placement

    struct PlacedImage: Equatable, Sendable {
        let key: String
        let filename: String
        let manifestID: String
        let image: EPUBImage
        let isCover: Bool

        var href: String { "images/\(filename)" }
    }

    struct PlacedImages: Equatable, Sendable {
        var ordered = [PlacedImage]()
        var byKey = [String: PlacedImage]()

        var cover: PlacedImage? { ordered.first { $0.isCover } }
    }

    private static func placeImages(
        item: SavedItem,
        document: ReaderDocument,
        images: [String: EPUBImage]
    ) -> PlacedImages {
        var placed = PlacedImages()
        var nextIndex = 1
        for request in EPUBImageCollector.requests(item: item, document: document) {
            guard let image = images[request.key] else { continue }
            let entry: PlacedImage
            if request.role == .hero {
                entry = PlacedImage(
                    key: request.key,
                    filename: "cover.\(image.format.fileExtension)",
                    manifestID: "cover-image",
                    image: image,
                    isCover: true
                )
            } else {
                entry = PlacedImage(
                    key: request.key,
                    filename: "img-\(nextIndex).\(image.format.fileExtension)",
                    manifestID: "img-\(nextIndex)",
                    image: image,
                    isCover: false
                )
                nextIndex += 1
            }
            placed.ordered.append(entry)
            placed.byKey[request.key] = entry
        }
        return placed
    }

    // MARK: - Container and package documents

    private static let containerXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func opf(
        item: SavedItem,
        document: ReaderDocument,
        images: PlacedImages,
        modified: Date
    ) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        out += "<package version=\"3.0\" unique-identifier=\"pub-id\" xmlns=\"http://www.idpf.org/2007/opf\">\n"
        out += "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
        out += "    <dc:identifier id=\"pub-id\">urn:uuid:\(item.id.uuidString.lowercased())</dc:identifier>\n"
        out += "    <dc:title>\(escape(item.title))</dc:title>\n"
        out += "    <dc:language>en</dc:language>\n"
        if let author = item.author, !author.isEmpty {
            out += "    <dc:creator>\(escape(author))</dc:creator>\n"
        }
        if let siteName = item.siteName, !siteName.isEmpty {
            out += "    <dc:publisher>\(escape(siteName))</dc:publisher>\n"
        }
        if let source = item.canonicalURL ?? item.sourceURL, ReaderDocumentHTMLBuilder.isSafeHTTPURL(source) {
            out += "    <dc:source>\(escape(source))</dc:source>\n"
        }
        if let published = item.publishedAt {
            out += "    <dc:date>\(published.formatted(.iso8601))</dc:date>\n"
        }
        out += "    <meta property=\"dcterms:modified\">\(modified.formatted(.iso8601))</meta>\n"
        if images.cover != nil {
            out += "    <meta name=\"cover\" content=\"cover-image\"/>\n"
        }
        out += "  </metadata>\n"
        out += "  <manifest>\n"
        out += "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        out += "    <item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        out += "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n"
        for image in images.ordered {
            let properties = image.isCover ? " properties=\"cover-image\"" : ""
            out += "    <item id=\"\(image.manifestID)\" href=\"\(image.href)\" media-type=\"\(image.image.format.mediaType)\"\(properties)/>\n"
        }
        out += "  </manifest>\n"
        out += "  <spine>\n"
        out += "    <itemref idref=\"chapter\"/>\n"
        out += "  </spine>\n"
        out += "</package>\n"
        return out
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    body { line-height: 1.5; }
    header { margin-bottom: 1.5em; }
    header h1 { margin-bottom: 0.25em; }
    .byline, .source, .date { margin: 0.1em 0; font-size: 0.9em; opacity: 0.8; }
    figure { margin: 1.25em 0; text-align: center; }
    figure img { max-width: 100%; height: auto; }
    figcaption { font-size: 0.85em; opacity: 0.8; margin-top: 0.4em; }
    figure.pdf-page img { width: 100%; }
    figure.hero { margin-top: 1em; }
    pre { white-space: pre-wrap; word-wrap: break-word; font-size: 0.85em; padding: 0.75em; }
    code { font-family: Menlo, Consolas, monospace; }
    blockquote { margin: 1em 1.5em; padding-left: 0.75em; border-left: 3px solid #999; }
    aside.callout, aside.embed { margin: 1em 0; padding: 0.75em 1em; border: 1px solid #bbb; }
    aside.callout h4 { margin: 0 0 0.4em; }
    table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    th, td { border: 1px solid #bbb; padding: 0.3em 0.5em; text-align: left; vertical-align: top; }
    hr { border: 0; border-top: 1px solid #bbb; margin: 1.5em 0; }
    .missing-image { opacity: 0.7; }
    """

    // MARK: - Chapter rendering

    struct ChapterRenderer {
        let item: SavedItem
        let document: ReaderDocument
        let images: PlacedImages

        private static let xhtmlPrologue = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">

        """

        func navigationDocument() -> String {
            var out = Self.xhtmlPrologue
            out += "<head>\n"
            out += "  <meta charset=\"utf-8\"/>\n"
            out += "  <title>Contents</title>\n"
            out += "</head>\n"
            out += "<body>\n"
            out += "  <nav epub:type=\"toc\" id=\"toc\">\n"
            out += "    <h1>Contents</h1>\n"
            out += "    <ol>\n"
            out += "      <li><a href=\"chapter.xhtml\">\(escape(item.title))</a>"
            let headings = document.blocks.enumerated().compactMap { index, block -> (Int, String)? in
                guard case let .heading(level, inlines) = block, level <= 2 else { return nil }
                let label = plainText(inlines).trimmingCharacters(in: .whitespacesAndNewlines)
                return label.isEmpty ? nil : (index, label)
            }
            if headings.isEmpty {
                out += "</li>\n"
            } else {
                out += "\n        <ol>\n"
                for (index, label) in headings {
                    out += "          <li><a href=\"chapter.xhtml#block-\(index)\">\(escape(label))</a></li>\n"
                }
                out += "        </ol>\n"
                out += "      </li>\n"
            }
            out += "    </ol>\n"
            out += "  </nav>\n"
            out += "</body>\n"
            out += "</html>\n"
            return out
        }

        func chapterDocument() -> String {
            var out = Self.xhtmlPrologue
            out += "<head>\n"
            out += "  <meta charset=\"utf-8\"/>\n"
            out += "  <title>\(escape(item.title))</title>\n"
            out += "  <link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>\n"
            out += "</head>\n"
            out += "<body>\n"
            out += "<article>\n"
            out += header()
            for (index, block) in document.blocks.enumerated() {
                let rendered = render(block, index: index)
                guard !rendered.isEmpty else { continue }
                out += rendered
                out += "\n"
            }
            out += "</article>\n"
            out += "</body>\n"
            out += "</html>\n"
            return out
        }

        // MARK: Header

        private func header() -> String {
            var out = "<header>\n"
            out += "  <h1>\(escape(item.title))</h1>\n"
            if let author = item.author, !author.isEmpty {
                out += "  <p class=\"byline\">by \(escape(author))</p>\n"
            }
            let source = item.sourceURL.flatMap { ReaderDocumentHTMLBuilder.isSafeHTTPURL($0) ? $0 : nil }
            let sourceName = item.siteName.flatMap { $0.isEmpty ? nil : $0 } ?? source.flatMap { URL(string: $0)?.host }
            if let sourceName {
                if let source {
                    out += "  <p class=\"source\"><a href=\"\(escape(source))\">\(escape(sourceName))</a></p>\n"
                } else {
                    out += "  <p class=\"source\">\(escape(sourceName))</p>\n"
                }
            }
            let date = item.publishedAt ?? item.createdAt
            let dateLabel = item.publishedAt == nil ? "Saved" : "Published"
            out += "  <p class=\"date\">\(dateLabel) \(escape(date.formatted(date: .abbreviated, time: .omitted)))</p>\n"
            if let cover = images.cover {
                out += "  <figure class=\"hero\"><img src=\"\(cover.href)\" alt=\"\"/></figure>\n"
            }
            out += "</header>\n"
            return out
        }

        // MARK: Blocks

        private func render(_ block: ReaderBlock, index: Int) -> String {
            let idAttr = "id=\"block-\(index)\""
            switch block {
            case .paragraph(let inlines):
                return "<p \(idAttr)>\(render(inlines))</p>"

            case let .heading(level, inlines):
                let clamped = min(max(level, 1), 6)
                return "<h\(clamped) \(idAttr)>\(render(inlines))</h\(clamped)>"

            case let .list(ordered, items):
                let tag = ordered ? "ol" : "ul"
                var out = "<\(tag) \(idAttr)>"
                for item in items {
                    out += "<li>\(render(item))</li>"
                }
                out += "</\(tag)>"
                return out

            case .blockquote(let inlines):
                return "<blockquote \(idAttr)><p>\(render(inlines))</p></blockquote>"

            case let .code(language, code):
                let classAttr = language.flatMap { $0.isEmpty ? nil : " class=\"language-\(escape($0))\"" } ?? ""
                return "<pre \(idAttr)><code\(classAttr)>\(escape(code))</code></pre>"

            case .figure(let media):
                return figure(media, idAttr: idAttr)

            case .video(let media):
                return video(media, idAttr: idAttr)

            case .embed(let embed):
                var out = "<aside class=\"embed\" \(idAttr)><p>\(escape(embed.provider))"
                if ReaderDocumentHTMLBuilder.isSafeHTTPURL(embed.embedURL) {
                    out += ": <a href=\"\(escape(embed.embedURL))\">\(escape(embed.embedURL))</a>"
                }
                out += "</p></aside>"
                return out

            case .table(let markdown):
                return ReaderDocumentHTMLBuilder.renderMarkdownTable(EPUBBuilder.xmlSafe(markdown), idAttr: idAttr)

            case .horizontalRule:
                return "<hr \(idAttr)/>"

            case let .callout(title, inlines):
                var out = "<aside class=\"callout\" \(idAttr)>"
                if let title, !title.isEmpty {
                    out += "<h4>\(escape(title))</h4>"
                }
                out += "<p>\(render(inlines))</p>"
                out += "</aside>"
                return out
            }
        }

        private func figure(_ media: MediaDescriptor, idAttr: String) -> String {
            let alt = media.altText.flatMap { $0.isEmpty ? nil : $0 }
            let caption = media.caption.flatMap { $0.isEmpty ? nil : $0 }
            let isPDFPage = media.sourceURL.hasPrefix("stower://pdf-page/")
            guard let placed = images.byKey[media.sourceURL] else {
                let label = alt ?? caption
                guard let label else { return "" }
                return "<p class=\"missing-image\" \(idAttr)><em>[Image: \(escape(label))]</em></p>"
            }
            let figureClass = isPDFPage ? "pdf-page" : "figure"
            var out = "<figure class=\"\(figureClass)\" \(idAttr)>"
            out += "<img src=\"\(placed.href)\" alt=\"\(escape(alt ?? ""))\"/>"
            if let caption {
                out += "<figcaption>\(escape(caption))</figcaption>"
            }
            out += "</figure>"
            return out
        }

        private func video(_ media: MediaDescriptor, idAttr: String) -> String {
            if media.providerName == "YouTube",
               let id = media.providerVideoID,
               YouTubeURLDetector.isValidVideoID(id) {
                let watchURL = "https://www.youtube.com/watch?v=\(id)"
                let label = media.caption.flatMap { $0.isEmpty ? nil : $0 } ?? "Watch on YouTube"
                let posterKey = media.posterURL.flatMap { ReaderDocumentHTMLBuilder.isSafeHTTPURL($0) ? $0 : nil }
                    ?? "youtube-poster:\(id)"
                if let poster = images.byKey[posterKey] {
                    var out = "<figure class=\"video\" \(idAttr)>"
                    out += "<a href=\"\(watchURL)\"><img src=\"\(poster.href)\" alt=\"\(escape(label))\"/></a>"
                    out += "<figcaption><a href=\"\(watchURL)\">\(escape(label))</a></figcaption>"
                    out += "</figure>"
                    return out
                }
                return "<p class=\"video-link\" \(idAttr)><a href=\"\(watchURL)\">\(escape(label))</a></p>"
            }

            let label = media.caption.flatMap { $0.isEmpty ? nil : $0 } ?? media.sourceURL
            guard ReaderDocumentHTMLBuilder.isSafeHTTPURL(media.sourceURL) else {
                return "<p class=\"video-link\" \(idAttr)>Video: \(escape(label))</p>"
            }
            return "<p class=\"video-link\" \(idAttr)><a href=\"\(escape(media.sourceURL))\">Watch video: \(escape(label))</a></p>"
        }

        // MARK: Inlines

        private func render(_ inlines: [ReaderInline]) -> String {
            var out = String()
            for inline in inlines {
                switch inline {
                case .text(let value):
                    out += escape(value)

                case .lineBreak:
                    out += "<br/>"

                case let .link(label, url):
                    if ReaderDocumentHTMLBuilder.isSafeLinkURL(url) {
                        out += "<a href=\"\(escape(url))\">\(escape(label))</a>"
                    } else {
                        out += escape(label)
                    }

                case .emphasis(let value):
                    out += "<em>\(escape(value))</em>"

                case .strong(let value):
                    out += "<strong>\(escape(value))</strong>"

                case .code(let value):
                    out += "<code>\(escape(value))</code>"

                case .strikethrough(let value):
                    out += "<s>\(escape(value))</s>"
                }
            }
            return out
        }

        private func plainText(_ inlines: [ReaderInline]) -> String {
            inlines.map { inline in
                switch inline {
                case .text(let value), .emphasis(let value), .strong(let value), .code(let value), .strikethrough(let value):
                    value
                case .lineBreak:
                    " "
                case .link(let label, _):
                    label
                }
            }
            .joined()
        }

        private func escape(_ text: String) -> String {
            EPUBBuilder.escape(text)
        }
    }
}
