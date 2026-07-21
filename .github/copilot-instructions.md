# Stower coding instructions

- Stower is a unified SwiftUI app targeting iOS, iPadOS, and macOS 27 with Swift 6.4.
- Use the `Stower` workspace and scheme. Shared code belongs in `StowerPackage`; the app shell stays minimal.
- Model application behavior with The Composable Architecture and inject side effects through Dependencies.
- Persist with SQLiteData and StructuredQueries. Do not introduce SwiftData or manual database-change broadcasters.
- Add new database migrations without modifying migrations that may have shipped.
- Use Swift Concurrency and actors for shared background state; keep UI/session work on the main actor.
- Use Swift Testing and deterministic clocks/UUIDs.
- Preserve the WebKit reader and native PDF support.
- Add accessibility labels and identifiers to new interactive UI.
- Validate with `swift test`, SwiftLint, and macOS/iOS builds from `Stower.xcworkspace`.
