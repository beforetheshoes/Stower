import Dependencies
import Foundation
import StowerData

struct ReaderDisplayPreferenceClient: Sendable {
    var load: @Sendable (_ host: String) async -> RenderFormat?
    var save: @Sendable (_ host: String, _ format: RenderFormat) async -> Void
}

private enum ReaderDisplayPreferenceClientKey: DependencyKey {
    static let liveValue = ReaderDisplayPreferenceClient(
        load: { host in
            guard let rawValue = UserDefaults.standard.string(forKey: key(for: host)) else {
                return nil
            }
            return RenderFormat(rawValue: rawValue)
        },
        save: { host, format in
            UserDefaults.standard.set(format.rawValue, forKey: key(for: host))
        }
    )

    static let testValue = ReaderDisplayPreferenceClient(
        load: { _ in nil },
        save: { _, _ in }
    )

    private static func key(for host: String) -> String {
        "stower.readerDisplayPreference.\(host.lowercased())"
    }
}

extension DependencyValues {
    var readerDisplayPreferenceClient: ReaderDisplayPreferenceClient {
        get { self[ReaderDisplayPreferenceClientKey.self] }
        set { self[ReaderDisplayPreferenceClientKey.self] = newValue }
    }
}
