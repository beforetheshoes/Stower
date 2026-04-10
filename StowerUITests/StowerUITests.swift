import XCTest

final class StowerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testSaveAndOpenNgrokArticle() throws {
        let app = XCUIApplication()
        app.launch()

        // Enter URL
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 10), "URL text field not found")
        textField.tap()
        textField.typeText("https://ngrok.com/blog/quantization")

        // Tap "Add URL"
        let addButton = app.buttons["Add URL"]
        XCTAssertTrue(addButton.exists, "Add URL button not found")
        addButton.tap()

        // Wait for ingestion + asset archiving (can take a while for a complex page)
        // The app auto-opens the reader after saving, so check for webView
        let webView = app.webViews.firstMatch
        let readerLoaded = webView.waitForExistence(timeout: 180)

        // Wait for page to fully render
        sleep(10)

        // Take initial screenshot
        let readerScreenshot = app.screenshot()
        try readerScreenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_reader_view.png"))

        if readerLoaded {
            // Scroll down to find the interactive SVGs
            for i in 0..<15 {
                webView.swipeUp()
                sleep(1)
                let scrollShot = app.screenshot()
                try scrollShot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_reader_scroll\(i).png"))
            }
        }

        // Check for "Item not found"
        let itemNotFound = app.staticTexts["Item not found"]
        XCTAssertFalse(itemNotFound.exists, "Reader shows 'Item not found'")
    }
}
