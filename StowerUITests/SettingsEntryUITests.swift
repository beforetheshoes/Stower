import XCTest

/// Settings can be reached from the library toolbar and from inside the
/// filter sheet. The second replaces one sheet with another, which is the
/// kind of hand-off SwiftUI drops when it is done in the wrong order.
final class SettingsEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testSettingsOpensFromTheToolbarAndFromTheFilterSheet() throws {
        let app = launchAtLibrary()

        let settingsBar = app.navigationBars["Settings"]

        let toolbarSettings = app.buttons["Settings"]
        XCTAssertTrue(toolbarSettings.waitForExistence(timeout: 10), "No Settings button in the library toolbar")
        toolbarSettings.tap()
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5), "Settings did not open from the toolbar")
        try save(app.screenshot(), name: "settings_from_toolbar")
        settingsBar.buttons["Done"].tap()
        XCTAssertTrue(settingsBar.waitForNonExistence(timeout: 5), "Settings stayed open after Done")

        let filters = app.buttons["Filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5), "Filters button not found")
        filters.tap()
        let inbox = app.buttons["Inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), "Filter sheet did not open")

        // Two buttons are named Settings now: the toolbar's, covered by the
        // sheet, and the sheet's own. The sheet's is the one that can be hit.
        let candidates = app.buttons.matching(identifier: "Settings").allElementsBoundByIndex
        let sheetSettings = try XCTUnwrap(candidates.last { $0.isHittable }, "No Settings button in the filter sheet")
        try save(app.screenshot(), name: "settings_filter_sheet")
        sheetSettings.tap()
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 8), "Settings did not open from the filter sheet")
        XCTAssertFalse(inbox.exists, "Filter sheet is still up behind Settings")
        try save(app.screenshot(), name: "settings_from_filters")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
