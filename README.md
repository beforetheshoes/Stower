# Stower - Read-It-Later App

A clean, modern read-it-later app that saves articles for offline reading across all your devices. Built natively for iOS and macOS with SwiftUI and CloudKit sync.

## 2026 Reboot Architecture

The app now uses:
- The Composable Architecture (TCA) for state, actions, reducers, and effects
- SQLite-Data for persistence and CloudKit-backed sync engine wiring
- A library-first product model with no unread debt framing in UI copy


## Features

- **Save articles instantly** from Safari or any app using the Share Extension
- **Distraction-free reading** with clean, formatted text extraction
- **Cross-platform sync** between iPhone, iPad, and Mac via CloudKit
- **Customizable reading experience** with themes, fonts, and layout options
- **Offline reading** - articles are saved locally for access anywhere
- **Smart content extraction** that removes ads and clutter
- **Tagging and organization** to keep your reading library organized

## Project Architecture

This project uses a **workspace + SPM package** architecture for clean separation between platform-specific app shells and shared business logic.

```
Stower/
├── Stower.xcworkspace/                 # 📱 Main workspace - open this in Xcode
├── 
├── # iOS App
├── Stower.xcodeproj/                   # iOS app shell project
├── Stower/                             # iOS app target (minimal)
│   ├── Assets.xcassets/                # iOS app assets
│   ├── StowerApp.swift                 # iOS app entry point
│   └── Stower.xctestplan              # iOS test configuration
├── StowerUITests/                      # iOS UI automation tests
├── StowerShare/                        # iOS Share Extension
│   ├── ShareViewController.swift       # Share Extension implementation
│   └── StowerShare.entitlements       # Share Extension entitlements
├── 
├── # macOS App
├── StowerMac.xcodeproj/               # Mac app shell project  
├── StowerMac/                         # Mac app target (minimal)
│   ├── Assets.xcassets/               # Mac app assets
│   ├── StowerMacApp.swift            # Mac app entry point
│   └── StowerMac.xctestplan          # Mac test configuration
├── StowerMacUITests/                  # Mac UI automation tests
├── 
├── # Shared Business Logic
├── StowerPackage/                     # 🚀 iOS feature package
│   ├── Package.swift                 # iOS package configuration
│   ├── Sources/StowerFeature/        # Core iOS business logic
│   └── Tests/StowerFeatureTests/     # iOS unit tests
├── StowerMacPackage/                  # 🚀 Mac feature package
│   ├── Package.swift                 # Mac package configuration  
│   ├── Sources/StowerMacFeature/     # Mac-specific adaptations
│   └── Tests/StowerMacFeatureTests/  # Mac unit tests
├── 
├── # Configuration
├── Config/                           # Build configuration
│   ├── Shared.xcconfig              # Common settings
│   ├── Shared-iOS.xcconfig          # iOS-specific settings
│   ├── Shared-macOS.xcconfig        # macOS-specific settings
│   ├── Debug.xcconfig               # Debug configuration
│   ├── Release.xcconfig             # Release configuration
│   ├── Tests.xcconfig               # Test configuration
│   ├── Stower.entitlements          # iOS entitlements
│   └── Stower-macOS.entitlements    # macOS entitlements
└── 
```

## Development

### Getting Started

1. **Open the workspace**: `Stower.xcworkspace` (not the individual .xcodeproj files)
2. **Choose your target**: Select either `Stower` (iOS) or `StowerMac` (macOS) scheme
3. **Build and run**: The app will launch with sample data in debug mode

### Key Architecture Points

- **App Shells**: iOS and Mac app targets contain minimal lifecycle code
- **Feature Packages**: All business logic lives in the SPM packages (`StowerPackage` & `StowerMacPackage`)
- **Shared Models**: Core data models and services are shared between platforms
- **Platform Adaptations**: Each platform has its own package for UI adaptations

### Code Organization

- **iOS Development**: Work primarily in `StowerPackage/Sources/StowerFeature/`
- **Mac Development**: Work primarily in `StowerMacPackage/Sources/StowerMacFeature/`
- **Shared Models**: Located in `StowerPackage/Sources/StowerFeature/Models/`
- **Services**: Content extraction, CloudKit sync in `StowerPackage/Sources/StowerFeature/Services/`

### Tech Stack

- **Language**: Swift 6.1+ with strict concurrency
- **UI Framework**: SwiftUI (iOS 18.0+, macOS 15.0+)
- **Data**: SQLite-Data with CloudKit sync engine
- **Testing**: Swift Testing framework (not XCTest)
- **Architecture**: The Composable Architecture (TCA)
- **Concurrency**: Swift Concurrency (async/await, actors, @MainActor)

## Features Overview

### Content Extraction
- Smart HTML parsing with SwiftSoup
- Removes ads, navigation, and clutter
- Preserves formatting, links, and images
- Converts to clean Markdown for consistent rendering

### Reading Experience
- Multiple reading themes (Light, Dark, Sepia, High Contrast)
- Customizable fonts and sizes
- Adjustable line spacing and margins
- Distraction-free fullscreen reading mode
- **Metadata editing** - Edit article titles, authors, and tags
- Author display in article lists for better organization

### Sync & Storage
- CloudKit integration for seamless sync across devices
- Offline-first architecture - works without internet
- App Groups for sharing data between main app and Share Extension
- Automatic background processing of saved URLs

### Platform Features

#### iOS Specific
- Share Extension for saving from Safari and other apps
- Native iOS navigation and controls
- Optimized for iPhone and iPad

#### macOS Specific  
- Menu bar integration
- Keyboard shortcuts for power users
- Multi-window support
- Native macOS document handling

## Configuration

### CloudKit Setup
The app uses CloudKit for cross-device sync. Container identifier: `iCloud.com.ryanleewilliams.stower`

### App Groups
Enables data sharing between main app and Share Extension: `group.com.ryanleewilliams.stower`

### Bundle Identifiers
- **iOS App**: `com.ryanleewilliams.stower`
- **macOS App**: `com.ryanleewilliams.stower`
- **Share Extension**: `com.ryanleewilliams.stower.share`

## Testing

### Test Structure
- **Swift Testing**: Modern testing framework with `@Test` macros
- **Unit Tests**: Business logic testing in package test targets
- **UI Tests**: Platform-specific UI automation tests
- **Test Plans**: Coordinated test execution with `.xctestplan` files

### Running Tests
```bash
# iOS tests
xcodebuild test -workspace Stower.xcworkspace -scheme Stower -destination 'platform=iOS Simulator,name=iPhone 16'

# Mac tests  
xcodebuild test -workspace Stower.xcworkspace -scheme StowerMac -destination 'platform=macOS'
```

## Building & Distribution

### Debug Builds
- Includes sample data for testing
- CloudKit sandbox environment
- Verbose logging enabled

### Release Builds
- Production CloudKit environment
- Optimized performance
- App Store distribution ready

## Dependencies

- **SwiftSoup**: HTML parsing and content extraction
- **MarkdownUI**: Rich text rendering from Markdown
- **NetworkImage**: Async image loading with caching

## Contributing

1. **Code Style**: Follow SwiftUI best practices and Swift 6 concurrency patterns
2. **Architecture**: Keep business logic in packages, UI-specific code in app targets
3. **Testing**: Add tests for new features using Swift Testing framework
4. **Documentation**: Update this README and inline documentation for significant changes

## License

This project was built with the assistance of Claude Code.