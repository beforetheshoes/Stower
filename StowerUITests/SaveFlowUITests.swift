import XCTest

/// Verifies that adding a link returns control immediately: the sheet closes
/// on Add, the save is listed in Inbox at once, and the article replaces it.
final class SaveFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testAddURLReturnsImmediatelyAndRowArrives() throws {
        let app = launchAtLibrary()

        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add menu not found")
        add.tap()

        let addURL = app.buttons["Add URL…"]
        XCTAssertTrue(addURL.waitForExistence(timeout: 5), "Add URL menu item not found")
        addURL.tap()

        // Focus is requested on appear; the simulator with a hardware
        // keyboard does not report it reliably, so tap to be safe.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "URL field not found")
        sleep(1)
        field.tap()
        field.typeText("https://www.oneusefulthing.org/p/15-times-to-use-ai-and-5-not-to")
        try save(app.screenshot(), name: "save_field_focused")

        let confirm = app.navigationBars["Add URL"].buttons["Add"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Sheet Add button not found")
        confirm.tap()

        // The sheet must be gone well before any network fetch could finish.
        let sheetGone = field.waitForNonExistence(timeout: 3)
        XCTAssertTrue(sheetGone, "Add URL sheet stayed open after Add")
        try save(app.screenshot(), name: "save_queued")

        // The save is listed at once, before anything has been fetched.
        let pending = app.descendants(matching: .any)["pendingSaveRow"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 3), "Save was not listed while it was being fetched")
        try save(app.screenshot(), name: "save_pending_row")

        // Then the article replaces it.
        XCTAssertTrue(pending.waitForNonExistence(timeout: 120), "Save never finished")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Saved row never arrived")
        try save(app.screenshot(), name: "save_row_arrived")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
