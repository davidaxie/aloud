import XCTest

/// C1 on the Mac: click to first audio in the natural voice, read from the
/// DEBUG `debug.tapAudio` probe (TapAudioProbe, shown by the overlay in
/// MacTestSilence): as the iPhone's, plus `fromClick`, from the click
/// itself through the double-click hold (C5 starts the sentence in it).
/// Muted (MutedRenderPump renders offline, so the node still starts), and
/// the model is read from the shared seed, so nothing downloads. The
/// readings are attached to the result.
final class TapLatencyUITest: XCTestCase {

    /// The shared seed ios/tools/fetch_kokoro_model.sh fills (L029).
    private static let modelDirectory = "/Users/Shared/AloudKokoroModel"
    /// Clicks per run.
    private static let clicks = 10

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

    func testClickToFirstAudioIsReported() throws {
        guard FileManager.default.fileExists(atPath: Self.modelDirectory + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(Self.modelDirectory)")
        }
        // Not `MacSuite.fresh`: its temporary model directory would win over
        // the seeded one.
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-reset-voice-pref",
                                         "-uitest-reset-natural-voice-offer",
                                         "-uitest-kokoro-model-path", Self.modelDirectory,
                                         "-uitest-seed-first-classic", "-uitest-open-first-doc"])
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "the reader opens")
        let probe = suite.element("debug.tapAudio")
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the tap probe shows in a UI-test launch")

        var readings: [String] = []
        for click in 0..<Self.clicks {
            let sounded = field("n", of: probe) ?? 0
            let frame = suite.pageText.frame
            let point = CGPoint(x: frame.minX + 40, y: frame.minY + frame.height * (click.isMultiple(of: 2) ? 0.72 : 0.58))
            var reached = false
            // A click on text still moving after a follow scroll only stops
            // it (counted as swallowed): click again, at most twice more.
            for _ in 0..<3 where !reached {
                let swallowed = field("swallowed", of: probe) ?? 0
                suite.coordinate(at: point).click()
                _ = suite.poll(timeout: 120) {
                    (field("n", of: probe) ?? 0) > sounded || (field("swallowed", of: probe) ?? 0) > swallowed
                }
                reached = (field("n", of: probe) ?? 0) > sounded
            }
            XCTAssertTrue(reached, "click \(click) should reach first audio, probe: \(value(of: probe))")
            readings.append(value(of: probe))
            XCTAssertNotNil(field("fromClick", of: probe), "a click's reading carries its time from the click")
        }

        let report = readings.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "tapAudio readings (Mac)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("tapAudio readings (Mac):\n\(report)")
    }

    // MARK: - Probe

    private func value(of probe: XCUIElement) -> String {
        (probe.value as? String) ?? ""
    }

    /// `name=<integer>` from the probe's value.
    private func field(_ name: String, of probe: XCUIElement) -> Int? {
        guard probe.exists else { return nil }
        for part in value(of: probe).split(separator: " ") where part.hasPrefix(name + "=") {
            return Int(part.dropFirst(name.count + 1))
        }
        return nil
    }
}
