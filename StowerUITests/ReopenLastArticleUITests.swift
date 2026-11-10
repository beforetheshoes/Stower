import UIKit
import XCTest

/// Leaving the app with an article open returns to that article; leaving it
/// from the library returns to the library.
final class ReopenLastArticleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone flow")
    }

    @MainActor
    func testRelaunchReturnsToTheOpenArticleAndThenToTheLibrary() throws {
        var app = launchAtLibrary()

        let filters = app.buttons["Filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10), "Filters button not found")
        filters.tap()
        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Library list not found")
        library.tap()
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No library rows")
        firstRow.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), "Reader web view not found")

        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), "The open article did not come back")
        try save(app.screenshot(), name: "reopened_article")

        // Go back to the library and leave from there.
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Filters"].waitForExistence(timeout: 5), "Did not return to the library")
        app.terminate()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Filters"].waitForExistence(timeout: 10), "Library not showing after relaunch")
        XCTAssertFalse(app.webViews.firstMatch.waitForExistence(timeout: 4), "An article reopened after it was closed")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
