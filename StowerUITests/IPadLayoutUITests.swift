import UIKit
import XCTest

/// The regular-width layout: three columns, and a reader toolbar that shows
/// the tools an iPhone keeps in its More menu.
final class IPadLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    }

    @MainActor
    func testReaderToolbarShowsItsToolsAndFocusCollapsesTheColumns() throws {
        let app = XCUIApplication()
        app.launch()

        // Make sure there is something to open.
        if !app.cells.firstMatch.waitForExistence(timeout: 5) {
            let add = app.buttons["Add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), "Add menu not found")
            add.tap()
            app.buttons["Add URL…"].tap()
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "URL field not found")
            sleep(1)
            field.tap()
            field.typeText("https://www.oneusefulthing.org/p/15-times-to-use-ai-and-5-not-to")
            app.navigationBars["Add URL"].buttons["Add"].tap()
        }
        try save(app.screenshot(), name: "ipad_library")

        // The remembered list may be Inbox; the saved article is there or in Library.
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "No article to open")
        row.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "Reader web view not found")
        sleep(2)
        try save(app.screenshot(), name: "ipad_reader")

        // Beside the library the reader is narrow: its tools stay in the
        // More menu, and there is exactly one such menu.
        XCTAssertFalse(app.buttons["Find"].exists, "Reader tools should not crowd a narrow toolbar")
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More menu not found")
        more.tap()
        let focus = app.buttons["Focus Reader"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 5), "Focus Reader is not in the More menu")
        focus.tap()
        sleep(2)
        try save(app.screenshot(), name: "ipad_reader_focused")

        // Focused, the reader has the whole window: the columns are gone
        // and the tools are buttons.
        XCTAssertFalse(app.cells.firstMatch.isHittable, "The library column is still showing in focus mode")
        for name in ["Find", "Listen", "Article Tools", "Exit Focus"] {
            XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 5), "\(name) is not in the wide reader toolbar")
        }

        app.buttons["Exit Focus"].firstMatch.tap()
        sleep(2)
        try save(app.screenshot(), name: "ipad_reader_unfocused")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5), "The library column did not come back")
        XCTAssertTrue(app.cells.firstMatch.isHittable, "The library column did not come back")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
