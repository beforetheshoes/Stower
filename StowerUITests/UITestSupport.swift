import UIKit
import XCTest

extension XCTestCase {
    /// Launches the app and makes sure the library is showing.
    ///
    /// The app reopens the article that was open when it was last used, so a
    /// test that ended inside the reader leaves the next launch there too.
    @MainActor
    func launchAtLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        guard UIDevice.current.userInterfaceIdiom == .phone else { return app }
        if app.webViews.firstMatch.waitForExistence(timeout: 4) {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            _ = app.buttons["Filters"].waitForExistence(timeout: 5)
        }
        return app
    }
}
