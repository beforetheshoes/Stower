import XCTest

/// Every entry in the Add menu presents something. Each presentation starts
/// while the menu is still closing, which is exactly when SwiftUI drops a
/// sheet presented too early.
final class ImportMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func openAddMenu(_ app: XCUIApplication, choose item: String) {
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add menu not found")
        add.tap()
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(item) not in the Add menu")
        entry.tap()
    }

    @MainActor
    func testAddTextOpensTheComposerAndCancelCloses() throws {
        let app = XCUIApplication()
        app.launch()

        openAddMenu(app, choose: "Add Text/Markdown…")

        let composer = app.navigationBars["Add Text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Text composer did not open")
        try save(app.screenshot(), name: "import_text_composer")

        composer.buttons["Cancel"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), "Text composer stayed open after Cancel")

        // Opening it a second time must work too: the first dismissal has to
        // have left the state clean.
        openAddMenu(app, choose: "Add Text/Markdown…")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Text composer did not reopen")
    }

    @MainActor
    func testImportPDFOpensTheDocumentPicker() throws {
        let app = XCUIApplication()
        app.launch()

        openAddMenu(app, choose: "Import PDF…")

        // The system document browser has no stable identifier of its own;
        // its Cancel button and the absence of the library's Add button are
        // the observable signs that it is up.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Document picker did not open")
        try save(app.screenshot(), name: "import_pdf_picker")
        cancel.tap()

        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5), "Library did not return after cancelling the picker")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/stower_\(name).png"))
    }
}
