import Foundation
import StowerData

/// What a reader page is made from. A value, so it can be handed to another
/// executor and built there.
public enum ReaderHTMLSource: Sendable {
    /// HTML that already exists: a captured page, or an editor preview.
    case ready(String)
    /// A structured document still to be rendered.
    case document(ReaderDocumentPage)

    /// Produces the page's HTML away from the main actor.
    @concurrent
    public func build() async -> String {
        switch self {
        case .ready(let html):
            html
        case .document(let page):
            ReaderDocumentHTMLBuilder.buildReaderHTML(
                item: page.item,
                document: page.document,
                appearance: page.appearance,
                pageWidth: page.pageWidth,
                fontScale: page.fontScale,
                restoreBlockIndex: page.restoreBlockIndex,
                insets: page.insets
            )
        }
    }
}

/// Everything `ReaderDocumentHTMLBuilder` needs to render one document.
public struct ReaderDocumentPage: Sendable {
    public var item: SavedItem
    public var document: ReaderDocument
    public var appearance: ReaderAppearanceSettings
    public var pageWidth: CGFloat
    public var fontScale: Double
    public var restoreBlockIndex: Int?
    public var insets: ReaderInsets

    public init(
        item: SavedItem,
        document: ReaderDocument,
        appearance: ReaderAppearanceSettings,
        pageWidth: CGFloat,
        fontScale: Double,
        restoreBlockIndex: Int?,
        insets: ReaderInsets
    ) {
        self.item = item
        self.document = document
        self.appearance = appearance
        self.pageWidth = pageWidth
        self.fontScale = fontScale
        self.restoreBlockIndex = restoreBlockIndex
        self.insets = insets
    }
}
