import ComposableArchitecture
import Foundation
import SQLiteData

// Helpers for `LibraryFeature`'s save and import effects.

struct TextImportRequest {
    var text: String
    var explicitTitle: String?
    var titleHint: String?
    var mode: TextImportMode
    var openAfterSave: Bool
}

func runTextImport(
    _ request: TextImportRequest,
    repository: StowerRepository,
    textIngestionClient: TextIngestionClient
) -> EffectOf<LibraryFeature> {
    .run { send in
        do {
            let result = try await textIngestionClient.ingest(
                request.text,
                request.explicitTitle,
                request.titleHint,
                request.mode
            )
            let item = try await repository.createItemFromIngestion(result)
            await send(.saveURLFinished(item))
            if request.openAfterSave {
                await send(.openItem(item))
            }
        } catch {
            await send(.saveURLFailed(error.localizedDescription))
        }
    }
}

func normalizeSourceURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // If the user typed a scheme (or pasted one), lowercase it so we don't
    // end up with "Https://…" from iOS autocapitalization. URL schemes are
    // case-insensitive per RFC 3986, but `URL(string:)` and third-party
    // parsers have a habit of being picky about the canonical form.
    if let schemeRange = trimmed.range(of: "://") {
        let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()
        let rest = trimmed[schemeRange.lowerBound...]
        return scheme + rest
    }

    if trimmed.contains(".") {
        return "https://\(trimmed)"
    }
    return nil
}

extension LibraryFeature.State {
    /// Whether the list being viewed is one a new save lands in. A new item
    /// is unread and untagged, so it is absent from the other lists.
    public var showsPendingSaves: Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return switch filter {
        case .all, .unread, .untagged:
            true
        case .read, .starred, .recentlyDeleted, .tag:
            false
        }
    }

    /// Saves to list ahead of the article they will become.
    public var pendingSaves: [PendingSave] {
        guard showsPendingSaves else { return [] }
        return PendingSave.notYetArrived(queuedSaves, among: library.items)
    }
}
