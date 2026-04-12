import CoreGraphics
import CryptoKit
import Dependencies
import Foundation
import OSLog
import PDFKit
import StowerData
import Vision

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let kPDFIngestLog = Logger(
    subsystem: "com.ryanleewilliams.stower",
    category: "PDFIngest"
)

public enum PDFIngestionError: Error, LocalizedError {
    case unreadable
    case passwordProtected
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The PDF couldn't be opened. It may be corrupted or not a valid PDF."
        case .passwordProtected:
            // swiftlint:disable:next no_sensitive_logging
            return "This PDF is password-protected. Open it in another app to remove the password, then re-share it."
        case .emptyDocument:
            return "The PDF contains no pages."
        }
    }
}

/// Ingests a local PDF file into an `IngestionResult` for Stower's reader.
///
/// Strategy: **rasterize every page to JPEG, emit one `.figure` block per
/// page pointing at the rasterized image**. The reader's structured HTML
/// renders the PDF exactly as designed — logos, colors, tables, fonts,
/// everything — because the "content" *is* the page image. Text is still
/// extracted in parallel (via `PDFKit.PDFPage.string` with a Vision OCR
/// fallback for empty pages) and stored in `IngestionResult.plainText` so
/// TTS, Summarize, Ask, and library search keep working against the real
/// words of the document.
///
/// This replaces an earlier structural-extraction pipeline (PDFKit
/// attributed-string heading detection + Vision `RecognizeDocumentsRequest`
/// tables/lists + a Foundation Models guided-generation reconstructor).
/// Every one of those approaches failed on visually-designed PDFs
/// (benefits summaries, brochures, forms) because they tried to
/// reconstruct the design as text and threw the layout away. Rendering
/// the page as an image and feeding the words in through a hidden channel
/// is the only approach that composes with the rest of the reader.
public struct PDFIngestionClient: Sendable {
    public var ingest: @Sendable (URL) async throws -> IngestionResult

    public init(
        ingest: @escaping @Sendable (URL) async throws -> IngestionResult
    ) {
        self.ingest = ingest
    }

    public static let failing = PDFIngestionClient { _ in
        throw PDFIngestionError.unreadable
    }

    public static let live = PDFIngestionClient { url in
        try await pdfIngest(url: url)
    }
}

// MARK: - Pipeline

private func pdfIngest(url: URL) async throws -> IngestionResult {
    // Memory-map the file so huge PDFs don't blow the heap while we
    // compute the checksum. `PDFDocument(url:)` also mmaps internally —
    // this read is just for the SHA-256.
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data)
    let hexHash = digest.map { String(format: "%02x", $0) }.joined()
    let canonicalURL = "pdf-sha256:\(hexHash)"

    guard let pdf = PDFDocument(url: url) else {
        throw PDFIngestionError.unreadable
    }
    if pdf.isLocked {
        throw PDFIngestionError.passwordProtected
    }
    guard pdf.pageCount > 0 else {
        throw PDFIngestionError.emptyDocument
    }

    // Resolve the deterministic item ID up front so we can write page
    // images directly into the item's archive directory. The item row
    // itself is created later by `createItemFromIngestion`, but the
    // directory is just filesystem state — it's safe to populate early,
    // and it means the ingestion result's MediaDescriptors can reference
    // real URLs that the reader can load immediately.
    let itemID = StowerRepository.stableItemID(from: canonicalURL)

    // Wipe any stale page images from a previous ingestion of the same
    // SHA. Without this, re-ingesting a PDF that had more pages last
    // time would leave orphaned `pdf-page-N.jpg` files remaining.
    PDFArchiver.deletePageImages(for: itemID)

    let attributes = pdf.documentAttributes ?? [:]
    let metaTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let creationDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
    let fallbackTitle = url.deletingPathExtension().lastPathComponent
    let title: String = {
        if let metaTitle, !metaTitle.isEmpty {
            return metaTitle
        }
        return fallbackTitle.isEmpty ? "Untitled PDF" : fallbackTitle
    }()

    kPDFIngestLog.notice(
        "Ingesting PDF \"\(title, privacy: .public)\" (\(pdf.pageCount, privacy: .public) pages, sha=\(hexHash, privacy: .public))"
    )

    // swiftlint:disable:next prefer_let_over_var
    var blocks: [ReaderBlock] = []
    // swiftlint:disable:next prefer_let_over_var
    var plainTextChunks: [String] = []
    var sawOCRFallback = false

    for pageIndex in 0..<pdf.pageCount {
        guard let page = pdf.page(at: pageIndex) else { continue }

        // Rasterize at 2x scale (~144 DPI for a letter-size page) —
        // sharp enough to read on retina displays without bloating
        // storage or memory. This same image is used both for display
        // and, when needed, for Vision OCR text extraction.
        guard let image = rasterizePage(page, scale: 2.0) else {
            kPDFIngestLog.error("Failed to rasterize page \(pageIndex, privacy: .public)")
            continue
        }

        // Persist the page image to the archive directory. The caller
        // never sees this file go through a temp-directory staging pass
        // — for image-first ingestion the archive is the only place the
        // rasterized bytes ever live.
        do {
            try PDFArchiver.archivePageImage(image, for: itemID, pageIndex: pageIndex)
        } catch {
            kPDFIngestLog.error(
                "Failed to archive page image \(pageIndex, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            continue
        }

        // Emit the figure block pointing at the image on disk.
        // `MediaDescriptor.sourceURL` uses a custom `stower://pdf-page/N`
        // scheme as a marker so `ReaderDocumentHTMLBuilder.resolveMediaURL`
        // knows to emit a relative-path `<img src="pdf-page-N.jpg">` that
        // the structured-HTML local server can resolve against the
        // per-view scratch directory (which symlinks in the archive's
        // page images at load time).
        let pageFilename = PDFArchiver.pageImageFilename(pageIndex: pageIndex)
        let media = MediaDescriptor(
            kind: .image,
            sourceURL: "stower://pdf-page/\(pageIndex)",
            localURL: PDFArchiver.pageImageURL(for: itemID, pageIndex: pageIndex).path,
            mimeType: "image/jpeg",
            altText: "Page \(pageIndex + 1) of \(pdf.pageCount)",
            posterLocalURL: nil
        )
        _ = pageFilename // silence unused-let warning; filename is used via resolveMediaURL
        blocks.append(.figure(media: media))

        // Text extraction for the hidden substrate (TTS / AI / search).
        // Try PDFKit's born-digital path first — fast, exact, and works
        // for most PDFs. Fall back to Vision OCR on the rasterized image
        // only when PDFKit returns nothing (scanned / image-only pages).
        let pdfKitText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pdfKitText.isEmpty {
            plainTextChunks.append(pdfKitText)
        } else {
            sawOCRFallback = true
            if let ocrText = try? await recognizeText(in: image),
               !ocrText.isEmpty {
                plainTextChunks.append(ocrText)
            }
        }
    }

    guard !blocks.isEmpty else {
        throw PDFIngestionError.emptyDocument
    }

    let plainText = plainTextChunks.joined(separator: "\n\n")
    let excerpt = plainText.isEmpty ? nil : String(plainText.prefix(220))
    // Even if a few pages fell back to OCR, the visual fidelity is
    // unchanged (the user sees the rasterized page either way), so we
    // mark the processing state `.ready` rather than `.partial`. The
    // partial flag in this app is a user-visible "might be incomplete"
    // badge — no reason to surface it when the rendered output is
    // identical.
    _ = sawOCRFallback

    let document = ReaderDocument(
        version: 1,
        sourceURL: nil,
        canonicalURL: canonicalURL,
        title: title,
        blocks: blocks
    )

    let media = blocks.compactMap { block -> MediaDescriptor? in
        if case .figure(let descriptor) = block {
            return descriptor
        }
        return nil
    }

    return IngestionResult(
        title: title,
        sourceURL: nil,
        canonicalURL: canonicalURL,
        excerpt: excerpt,
        author: (author?.isEmpty == true) ? nil : author,
        publishedAt: creationDate,
        siteName: nil,
        heroImageURL: nil,
        readingTimeMinutes: estimateReadingTime(text: plainText),
        hasRichMedia: true,
        renderFormat: .pdf,
        processingState: .ready,
        processingError: nil,
        document: document,
        plainText: plainText,
        media: media,
        embeds: [],
        sourceHTML: "",
        pdfSHA256: hexHash
    )
}

// MARK: - Rasterization

/// Renders a PDF page to a CGImage at `scale`x the page's point size.
/// Uses CoreGraphics directly so the function works on both iOS and
/// macOS with no UIKit/AppKit dependency.
private func rasterizePage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let width = Int(bounds.width * scale)
    let height = Int(bounds.height * scale)
    guard width > 0, height > 0 else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    // White backdrop — PDF pages can have transparent regions that would
    // otherwise show through as the destination's uninitialized bytes.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
}

// MARK: - Text fallback (scanned pages only)

/// Runs Vision's `RecognizeTextRequest` on a rasterized page image and
/// returns the joined line transcripts as a single string. Used only when
/// `PDFPage.string` returns empty (i.e. the page is a scanned image with
/// no embedded text). For born-digital PDFs this is never called.
private func recognizeText(in image: CGImage) async throws -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let observations = try await request.perform(on: image)
    let lines: [String] = observations.compactMap { obs in
        obs.topCandidates(1).first?.string
    }
    return lines
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

// MARK: - Dependency key

private enum PDFIngestionClientKey: DependencyKey {
    static let liveValue = PDFIngestionClient.live
    static let testValue = PDFIngestionClient.failing
}

extension DependencyValues {
    public var pdfIngestionClient: PDFIngestionClient {
        get { self[PDFIngestionClientKey.self] }
        set { self[PDFIngestionClientKey.self] = newValue }
    }
}
