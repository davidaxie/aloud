import XCTest

/// M8's adding items that need the window. A file opened the way Finder's
/// Open With opens it (`-uitest-open <path>`, replayed through
/// `application(_:open:)`) plays with no click; the same file opened again
/// stays one book; an add held past 0.8 s (`-uitest-slow-import`) shows the
/// import overlay, and Esc cancels it with nothing stored.
///
/// The file is a classic's plain text inside the built Aloud Dev app: the
/// sandboxed app may read its own bundle, and the test never writes into
/// any container. Muted throughout; autoplay only where an open must reach
/// "playing". Runs only in the consented `AloudMacUI` scheme.
final class MacImportUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// The Cask of Amontillado's text in the Aloud Dev app beside this
    /// runner in the build products; skips when there is none.
    private func fixturePath() throws -> String {
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        let apps = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        for bundle in apps where bundle.pathExtension == "app" {
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == "com.davidxie.Aloud.mac.dev" else { continue }
            let file = bundle.appendingPathComponent("Contents/Resources/Bookshelf/1063-the-cask-of-amontillado.txt")
            if FileManager.default.fileExists(atPath: file.path) { return file.path }
        }
        throw XCTSkip("No Aloud Dev app with the bundled classics next to the runner in \(products.path)")
    }

    private func launch(_ arguments: [String], allowAutoplay: Bool = false) -> MacSuite {
        let app = XCUIApplication.aloud(arguments, allowAutoplay: allowAutoplay)
        self.app = app
        launchAloud(app)
        return MacSuite(app: app)
    }

    func testAnOpenWithLaunchPlaysWithNoClick() throws {
        let path = try fixturePath()
        let suite = launch(MacSuite.fresh + ["-uitest-open", path], allowAutoplay: true)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60),
                      "the opened file plays with 0 clicks, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.modals, 0, "no alert on the way")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testOpeningTheSameFileTwiceKeepsOneBook() throws {
        let path = try fixturePath()
        var suite = launch(MacSuite.fresh + ["-uitest-open", path])
        XCTAssertTrue(suite.play.waitForExistence(timeout: 60), "the first open adds and opens it")
        suite.app.terminate()

        suite = launch(["-uitest-temp-model-dir", "-uitest-open", path])
        XCTAssertTrue(suite.play.waitForExistence(timeout: 60), "the second open opens it again")
        XCTAssertTrue(suite.backToLibrary(self))
        XCTAssertTrue(suite.poll(timeout: 10) { suite.libraryBookCount == 1 }, "deduplicated by content: one book")
        XCTAssertEqual(suite.modals, 0, "no failure alert")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testASlowAddShowsTheOverlayAndEscCancelsIt() throws {
        let path = try fixturePath()
        let suite = launch(MacSuite.fresh + ["-uitest-slow-import", "-uitest-open", path])
        let overlay = suite.element("import.overlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), "an add past 0.8 s shows the overlay")
        XCTAssertTrue(suite.element("import.cancel").exists, "with Cancel")

        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { !overlay.exists }, "Esc cancels")
        XCTAssertTrue(suite.element("library.featured").waitForExistence(timeout: 10), "nothing was stored")
        XCTAssertFalse(suite.play.exists, "and nothing opened")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testSeveralDroppedFilesAreAddedAndNoneOpens() throws {
        // XCUITest can't drag a file in without driving Finder, which no
        // test may do; `-uitest-open` takes one path. MacImportTests (hosted)
        // covers a 3-file intake opening none.
        throw XCTSkip("Needs a multi-file -uitest-open; the hosted MacImportTests cover it")
    }

    func testAnUndownloadedPlaceholderShowsNotDownloaded() throws {
        // A cloud placeholder needs a File Provider domain, which a test
        // can't make; MacImportTests (hosted) maps the coordinator's
        // failure to notDownloaded.
        throw XCTSkip("Needs a placeholder fixture; the hosted MacImportTests cover the mapping")
    }
}
