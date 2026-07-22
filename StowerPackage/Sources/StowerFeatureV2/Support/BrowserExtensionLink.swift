import Foundation

/// The URL contract used by Stower's Chromium browser extension.
///
/// Keeping parsing in the feature module gives the app one strict boundary for
/// external input and makes malformed or non-web URLs easy to test without
/// launching the application.
public enum BrowserExtensionLink: Equatable, Sendable {
    case save(URL)

    public init?(_ incomingURL: URL) {
        guard
            let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
            ["stower", "stower-dev"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.lowercased() == "save",
            let rawTarget = components.queryItems?.first(where: { $0.name == "url" })?.value,
            let targetURL = URL(string: rawTarget),
            ["http", "https"].contains(targetURL.scheme?.lowercased() ?? "")
        else { return nil }

        self = .save(targetURL)
    }
}
