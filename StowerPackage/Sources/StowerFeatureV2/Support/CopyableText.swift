import SwiftUI

/// A button that copies a string and briefly confirms it did.
///
/// Exists as its own type because the banners already own a row of buttons —
/// dropping a whole `CopyableText` into one of those would nest a second stack
/// in the label column and put the button in the wrong place. Those sites take
/// the button alone; everything else takes `CopyableText`.
struct CopyButton: View {
    enum Style {
        case compact
        case labeled
    }

    let text: String
    var style: Style = .labeled

    @State private var didCopy = false

    var body: some View {
        Button {
            ClipboardSupport.copy(text)
            didCopy = true
            #if canImport(UIKit)
            AccessibilityNotification.Announcement("Copied").post()
            #endif
        } label: {
            Label(
                didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
        }
        .modifier(CopyButtonStyle(style: style))
        .accessibilityLabel(didCopy ? "Copied" : "Copy")
        // `.task(id:)` rather than a detached `Task`: SwiftUI cancels it when
        // the view goes away, which matters because the banners this sits in
        // can be dismissed while the confirmation is still showing.
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
        .animation(.default, value: didCopy)
    }
}

/// Applies the size/prominence treatment for a `CopyButton`.
///
/// A modifier rather than a branch in `body` so both cases share one button
/// identity — branching would rebuild the button on style change and drop the
/// in-flight "Copied" confirmation.
private struct CopyButtonStyle: ViewModifier {
    let style: CopyButton.Style

    func body(content: Content) -> some View {
        switch style {
        case .compact:
            content
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption)
                .contentShape(.rect)
        case .labeled:
            content
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// A diagnostic string the user can select *and* copy.
///
/// Every error and diagnostic in the app used to be a plain `Text`: not
/// selectable, sometimes truncated, and impossible to get out of the app
/// except by retyping it from a screenshot.
///
/// `copyText` is the escape hatch for the sites that must stay visually
/// bounded — the displayed string can be elided while the copied one stays
/// whole.
struct CopyableText: View {
    enum Layout {
        case belowText
        case trailingButton
    }

    private let text: String
    private let copyText: String?
    private let layout: Layout
    private let font: Font
    private let textColor: Color?
    private let lineLimit: Int?
    private let truncationMode: Text.TruncationMode
    private let buttonStyle: CopyButton.Style

    init(
        text: String,
        copyText: String? = nil,
        layout: Layout = .belowText,
        font: Font = .caption,
        textColor: Color? = nil,
        lineLimit: Int? = nil,
        truncationMode: Text.TruncationMode = .tail,
        buttonStyle: CopyButton.Style = .labeled
    ) {
        self.text = text
        self.copyText = copyText
        self.layout = layout
        self.font = font
        self.textColor = textColor
        self.lineLimit = lineLimit
        self.truncationMode = truncationMode
        self.buttonStyle = buttonStyle
    }

    /// What actually reaches the clipboard. Always the full string, even when
    /// the visible one is truncated.
    var payload: String {
        copyText ?? text
    }

    var body: some View {
        switch layout {
        case .belowText:
            VStack(alignment: .leading, spacing: 6) {
                label
                CopyButton(text: payload, style: buttonStyle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .trailingButton:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                CopyButton(text: payload, style: buttonStyle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(textColor ?? Color.secondary)
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
