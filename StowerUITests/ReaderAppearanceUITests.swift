import XCTest

/// The reader's appearance controls have to fit an iPhone and be usable
/// there: every control on screen, and a way to close them.
final class ReaderAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testAppearanceControlsFitAndClose() throws {
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
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), "Reader web view not found")

        let appearance = app.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), "Appearance button not found")
        appearance.tap()
        sleep(1)
        try save(app.screenshot(), name: "appearance_panel")

        // The reader's own toolbar has a Done button too, under the panel.
        let done = try XCTUnwrap(
            app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last { $0.isHittable },
            "Appearance controls have no Done button on screen"
        )
        // Every section is on screen without scrolling on this device.
        for label in ["Background", "Primary Accent", "Secondary Accent", "Font Size", "Line Width"] {
            let title = app.staticTexts[label]
            XCTAssertTrue(title.exists && app.windows.firstMatch.frame.contains(title.frame), "\(label) is not on screen")
        }
        // Accent swatches are comfortable to hit.
        let swatch = app.buttons["Blue"].firstMatch
        XCTAssertTrue(swatch.exists, "Accent swatch not found")
        XCTAssertGreaterThanOrEqual(swatch.frame.height, 43.9, "Accent swatch is \(swatch.frame.size)")
        XCTAssertGreaterThanOrEqual(swatch.frame.width, 39.9, "Accent swatch is \(swatch.frame.size)")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(done.frame), "Done is off screen: \(done.frame) in \(window)")
        done.tap()
        XCTAssertTrue(app.staticTexts["Primary Accent"].waitForNonExistence(timeout: 5), "Appearance controls stayed open after Done")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
