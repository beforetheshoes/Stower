import Dependencies
import Foundation
import WebKit

/// A @MainActor-isolated registry that holds a reference to the currently
/// rendering reader `WebPage`. It is the bridge between a SwiftUI view
/// (`ReaderWebView`) that owns the `WebPage` instance and a TCA reducer
/// effect (in `ReaderFeature`) that polls reading progress off of it.
///
/// Why this indirection exists: `WebPage` is a non-Sendable @MainActor class
/// from the iOS 18 SwiftUI WebKit API, so we cannot pass it across
/// concurrency boundaries or store it in TCA state. Instead, the view
/// `register`s its current page with this singleton, and the reducer's
/// polling effect queries it via a Sendable client that hops to MainActor
/// internally.
///
/// The previous approach ran the polling loop as a manual `Task` inside
/// `ReaderWebView` and sent `scrollProgressChanged` actions directly to the
/// store. That created a race: on iPhone, `navigationDestination(item:)`
/// nils `state.reader` the instant the user pops, but the view's
/// `.onDisappear` (which cancelled the manual Task) fires at the *end* of
/// the pop animation. A single in-flight poll tick in that window would
/// send an action for an already-dismissed presentation, tripping TCA's
/// "ifLet received a presentation action when destination state was absent"
/// runtime warning. Moving the loop into a TCA child effect means
/// `ifLet` can cancel it atomically with the state transition — no race.
@MainActor
public final class ReaderProgressCoordinator {
    public static let shared = ReaderProgressCoordinator()

    private var currentPage: WebPage?

    private init() {}

    public func register(_ page: WebPage?) {
        self.currentPage = page
    }

    public func topBlockIndex() async -> Int? {
        guard let currentPage else { return nil }
        return await ReaderWebPageFactory.fetchTopBlockIndex(on: currentPage)
    }
}

// MARK: - Client

/// Sendable façade over `ReaderProgressCoordinator` so it can be used from
/// `@Dependency` inside a TCA reducer effect. The single closure is the
/// only API the reducer needs: ask for the topmost visible block index.
public struct ReaderProgressClient: Sendable {
    public var topBlockIndex: @Sendable () async -> Int?

    public init(topBlockIndex: @escaping @Sendable () async -> Int?) {
        self.topBlockIndex = topBlockIndex
    }
}

extension ReaderProgressClient {
    public static let live = Self {
        await ReaderProgressCoordinator.shared.topBlockIndex()
    }

    public static let noop = Self { nil }
}

// MARK: - Dependency registration

private enum ReaderProgressClientKey: DependencyKey {
    static let liveValue: ReaderProgressClient = .live
    static let testValue: ReaderProgressClient = .noop
    static let previewValue: ReaderProgressClient = .noop
}

extension DependencyValues {
    public var readerProgressClient: ReaderProgressClient {
        get { self[ReaderProgressClientKey.self] }
        set { self[ReaderProgressClientKey.self] = newValue }
    }
}
