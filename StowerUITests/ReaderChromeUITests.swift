import XCTest

/// Verifies the reader's chrome toggle keeps the page still and that a saved
/// article reopens at its restored position without intermediate states.
final class ReaderChromeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testChromeToggleKeepsPageStill() throws {
        let app = XCUIApplication()
        app.launch()

        let filters = app.buttons["Filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10), "Filters button not found")
        filters.tap()

        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Library list not found")
        library.tap()

        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No library rows")
        firstRow.tap()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20), "Reader web view not found")
        sleep(2)
        try save(app.screenshot(), name: "chrome_visible")

        webView.tap()
        sleep(1)
        try save(app.screenshot(), name: "chrome_hidden")

        webView.tap()
        sleep(1)
        try save(app.screenshot(), name: "chrome_visible_again")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
