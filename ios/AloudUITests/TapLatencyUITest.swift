import XCTest

/// C1: tap to first audio in the natural voice, read from the DEBUG
/// `debug.tapAudio` probe (TapAudioProbe): `n` seeks that sounded, `ms`
/// from the seek to the started node's play, the `path` its first clip
/// came by (hit, lead, phrase, whole), `wait` behind a job in flight,
/// `cold`, and taps a coasting scroll ate (`swallowed`). Every launch is
/// muted, so the node still starts with no sound; the readings leave out
/// the output's own latency. The model is read from the shared seed, so
/// nothing downloads. The readings are attached to the result for the
/// before and after of each change; on a device, the same run gives the
/// absolute figures.
final class TapLatencyUITest: XCTestCase {

    /// The shared seed ios/tools/fetch_kokoro_model.sh fills (L029).
    static let modelDirectory = "/Users/Shared/AloudKokoroModel"
    /// Taps per run.
    private static let taps = 10

    override func setUp() {
        continueAfterFailure = false
    }

    func testTapToFirstAudioIsReported() throws {
        guard FileManager.default.fileExists(atPath: Self.modelDirectory + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(Self.modelDirectory)")
        }
        let app = XCUIApplication.aloud([
            "-uitest-reset-library",
            "-uitest-seed-first-classic",
            "-uitest-open-first-doc",
            "-uitest-reset-voice-pref",
            "-uitest-kokoro-model-path", Self.modelDirectory,
        ])
        app.launch()

        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 20), "Reader should auto-open")
        let probe = app.descendants(matching: .any)["debug.tapAudio"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the tap probe shows in a UI-test launch")

        var readings: [String] = []
        for tap in 0..<Self.taps {
            let sounded = field("n", of: probe) ?? 0
            // Alternate two lines below the voice, so each tap lands on a
            // sentence not yet made more often than not.
            let offset = CGVector(dx: 0.5, dy: tap.isMultiple(of: 2) ? 0.72 : 0.58)
            var reached = false
            // A tap on text still moving after a follow scroll only stops it
            // (counted as swallowed): tap again, at most twice more.
            for _ in 0..<3 where !reached {
                let swallowed = field("swallowed", of: probe) ?? 0
                readerText.coordinate(withNormalizedOffset: offset).tap()
                _ = waitUntil(180) {
                    (field("n", of: probe) ?? 0) > sounded || (field("swallowed", of: probe) ?? 0) > swallowed
                }
                reached = (field("n", of: probe) ?? 0) > sounded
            }
            XCTAssertTrue(reached, "tap \(tap) should reach first audio, probe: \(value(of: probe))")
            readings.append(value(of: probe))
            XCTAssertNotNil(field("ms", of: probe), "a reading names its time")
        }

        let report = readings.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "tapAudio readings (iPhone)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("tapAudio readings (iPhone):\n\(report)")
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

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }
}
