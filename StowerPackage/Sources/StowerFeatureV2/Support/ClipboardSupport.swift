import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The single place the app writes to the system clipboard.
///
/// Kept as one namespace so a copy affordance can be added anywhere without
/// each screen growing its own private pasteboard helper — which is how the
/// only previous copy action ended up locked inside `LibraryScreen`, out of
/// reach of every error message in the app.
enum ClipboardSupport {
    static func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
