# Stower development guide

Stower is one SwiftUI application for iOS, iPadOS, and macOS 27. It compiles in Swift 6 mode with Xcode 27 and shares its implementation through `StowerPackage`.

## Architecture

- `StowerFeature` contains the TCA app domain, SwiftUI screens, reader, ingestion clients, Foundation Models integration, and App Intents.
- `StowerData` contains SQLiteData tables, migrations, repositories, CloudKit sync, and shared ingestion payloads.
- `Stower/StowerApp.swift` is the thin application entry point.
- `StowerShare` writes imports into the shared SQLite ingestion queue.
- `StowerFeatureV2Tests` uses Swift Testing and TCA `TestStore`.

Open `Stower.xcworkspace` and use the unified `Stower` scheme for both iOS and macOS. There is no `StowerMac` project/package and no SwiftData stack.

## Implementation rules

- Put shared product work in `StowerPackage`; change the app shell only for lifecycle, commands, assets, entitlements, or target wiring.
- Use modern TCA reducer composition, `EffectOf`, presentation state, and dependency injection.
- Use SQLiteData/StructuredQueries for persistence and database-backed observation for UI-visible data.
- Add schema changes as new non-destructive `DatabaseMigrator` migrations. Never alter an already shipped migration.
- Inject clocks, UUIDs, and coordination boundaries. Use actors for shared mutable background state and `@MainActor` only for UI/session state.
- Do not use `@unchecked Sendable` in application code or blanket module-wide main-actor isolation.
- Keep WebKit as the offline reader. Use native PDF presentation for original PDFs.
- Keep Foundation Models on-device and cancel work when its reader panel closes.
- Add Swift Testing coverage for reducer behavior and persistence changes.

## Commands

```bash
cd StowerPackage && swift test
swiftlint lint --config .swiftlint.yml --strict
xcodebuild build -workspace Stower.xcworkspace -scheme Stower -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -workspace Stower.xcworkspace -scheme Stower -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

OS 27 simulator tests use `platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0`. CI build/test jobs run on a self-hosted runner labelled `macOS` and `xcode-27` until a suitable hosted image exists.

## Key paths

- App reducer: `StowerPackage/Sources/StowerFeatureV2/App/AppFeature.swift`
- Root navigation: `StowerPackage/Sources/StowerFeatureV2/ContentView.swift`
- Reader: `StowerPackage/Sources/StowerFeatureV2/Features/Reader/`
- Repository: `StowerPackage/Sources/StowerData/Data/StowerRepository*.swift`
- Tables and migrations: `StowerPackage/Sources/StowerData/Data/Tables.swift`, `Bootstrap.swift`
- Tests: `StowerPackage/Tests/StowerFeatureV2Tests/`
