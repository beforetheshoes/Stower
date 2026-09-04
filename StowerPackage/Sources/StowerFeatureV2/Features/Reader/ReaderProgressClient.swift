import Dependencies
import Foundation
import WebKit

/// A @MainActor-isolated registry that holds a reference to the currently
/// rendering reader `WebPage` and relays reading-position reports from the
/// page's in-document runtime to whoever is listening (the reader reducer).
///
/// Why this indirection exists: `WebPage` is a non-Sendable @MainActor class,
/// so it cannot be passed across concurrency boundaries or stored in TCA
/// state. The view registers its page here; the page's navigation decider
/// reports positions here; the reducer consumes them through a Sendable
/// client as an `AsyncStream`. Running the consumer as a TCA child effect
/// means `ifLet` cancels it atomically with presentation dismissal, so a
/// late report never reaches a reader whose state is already gone.
@MainActor
public final class ReaderProgressCoordinator {
    public static let shared = ReaderProgressCoordinator()

    private var currentPage: WebPage?
    private var continuations = [UUID: AsyncStream<Int>.Continuation]()
    /// The most recent block index reported by the active page.
    public private(set) var latestBlockIndex: Int?

    private init() {}

    public func register(_ page: WebPage?) {
        if page !== currentPage {
            latestBlockIndex = nil
        }
        currentPage = page
    }

    /// Clears a page only if it is still the active registration. During a
    /// SwiftUI transition an outgoing reader can disappear after the incoming
    /// reader has registered, and must not clear the newer reader's page.
    public func unregister(_ page: WebPage?) {
        guard let page, currentPage === page else { return }
        currentPage = nil
        latestBlockIndex = nil
    }

    /// Records a position reported by the page's runtime. Reports from a page
    /// that is not the active registration are dropped.
    public func report(_ blockIndex: Int, from page: WebPage) {
        guard page === currentPage, blockIndex >= 0 else { return }
        latestBlockIndex = blockIndex
        for continuation in continuations.values {
            continuation.yield(blockIndex)
        }
    }

    /// A stream of block indexes as the reader scrolls. Finishes when the
    /// consuming task is cancelled.
    public func updates() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    ReaderProgressCoordinator.shared.continuations[id] = nil
                }
            }
        }
    }

    /// One-shot query of the page's topmost visible block.
    public func topBlockIndex() async -> Int? {
        guard let currentPage else { return nil }
        return await ReaderWebPageFactory.fetchTopBlockIndex(on: currentPage)
    }
}

// MARK: - Client

/// Sendable façade over `ReaderProgressCoordinator` so it can be used from
/// `@Dependency` inside a TCA reducer effect.
public struct ReaderProgressClient: Sendable {
    /// Positions reported by the page as the user scrolls.
    public var progressUpdates: @Sendable () async -> AsyncStream<Int>
    /// One-shot query of the topmost visible block.
    public var topBlockIndex: @Sendable () async -> Int?

    public init(
        progressUpdates: @escaping @Sendable () async -> AsyncStream<Int>,
        topBlockIndex: @escaping @Sendable () async -> Int?
    ) {
        self.progressUpdates = progressUpdates
        self.topBlockIndex = topBlockIndex
    }
}

extension ReaderProgressClient {
    public static let live = Self(
        progressUpdates: { await ReaderProgressCoordinator.shared.updates() },
        topBlockIndex: { await ReaderProgressCoordinator.shared.topBlockIndex() }
    )

    /// Never reports a position; the update stream finishes immediately.
    public static let noop = Self(
        progressUpdates: { AsyncStream { $0.finish() } },
        topBlockIndex: { nil }
    )
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
