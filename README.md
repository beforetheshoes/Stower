# Stower

Stower is a native read-it-later app for iPhone, iPad, and Mac. It saves web articles, PDFs, website archives, Markdown, and plain text for offline reading and synchronizes the library through CloudKit.

## Platform and toolchain

- Xcode 27 developer beta with Swift 6.4
- iOS, iPadOS, and macOS 27 or later
- One shared SwiftUI application and one shared Swift package
- The Composable Architecture 1.26
- SQLiteData 1.7 and StructuredQueries for persistence
- Swift Testing for reducer, database, parsing, and integration tests

The OS 27 minimum is intentional. Foundation Models, current SwiftUI navigation and toolbar behavior, and the current App Intents surface are used without compatibility branches for older systems.

## Repository layout

```text
Stower.xcworkspace/              Xcode workspace to open
Stower.xcodeproj/                Unified iOS/macOS app and extension targets
Stower/                          Thin SwiftUI app entry point and assets
StowerShare/                     Share extension
StowerPackage/
  Sources/StowerData/            SQLiteData schema, migrations, repositories, sync
  Sources/StowerFeatureV2/       TCA domains, SwiftUI screens, ingestion, reader
  Tests/StowerFeatureV2Tests/    Swift Testing suites
StowerUITests/                   UI automation
Config/                          Shared build settings and entitlements
```

There is no separate Mac project and no SwiftData persistence stack. Both app platforms use the same `Stower` scheme, TCA feature tree, and SQLiteData database.

## Main capabilities

- Three-column library navigation on Mac and regular-width iPad
- Same-window reader focus mode that preserves the active WebKit session
- Offline HTML archives, native PDF presentation, selection, and find-in-page
- Reader appearance controls, listening, and on-device Foundation Models summary/Q&A
- URL and text App Intents for Siri, Shortcuts, Spotlight, and Apple Intelligence surfaces
- App Group ingestion from the share extension
- Transactional ingestion claims, bounded retries, crash recovery, and visible import failures
- Database-backed live observation for library rows, counts, and tags
- CloudKit synchronization through SQLiteData's sync engine

## Build and test

Open `Stower.xcworkspace`, select the `Stower` scheme, and choose either a Mac or an OS 27 iOS simulator.

```bash
cd StowerPackage
swift test

# Optional: semantic fixtures against the real OS 27 on-device model.
STOWER_RUN_FOUNDATION_MODEL_TESTS=1 swift test

cd ..
swiftlint lint --config .swiftlint.yml --strict

xcodebuild build \
  -workspace Stower.xcworkspace \
  -scheme Stower \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -workspace Stower.xcworkspace \
  -scheme Stower \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -skip-testing:StowerUITests \
  CODE_SIGNING_ALLOWED=NO
```

CI build and test jobs currently require a self-hosted macOS runner labelled `xcode-27`. The lint job remains hosted. This can return to a hosted Xcode image after Xcode 27 is generally available there.

## Data and synchronization

The main app and share extension use App Group `group.com.ryanleewilliams.stower`. Synced records use CloudKit container `iCloud.com.ryanleewilliams.stower`; downloaded/rendered content and ingestion jobs remain local where appropriate.

Database schema changes belong in a new, non-destructive migration in `StowerPackage/Sources/StowerData/Data/Bootstrap.swift`. Do not revise a migration that may already have shipped.

## Development conventions

- Keep app-shell code minimal; shared implementation belongs in `StowerPackage`.
- Model feature behavior in TCA reducers and inject side effects with Dependencies.
- Keep UI/session state on the main actor and shared background coordination in actors.
- Use SQLiteData observation for visible database state; do not add manual reload broadcasters.
- Use Swift Testing and deterministic clocks/UUIDs for new behavior.
- Preserve WebKit as the reader engine. TextKit is reserved for text authoring work.
