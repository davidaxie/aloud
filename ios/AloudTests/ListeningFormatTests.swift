import XCTest
@testable import Aloud

/// The one voice and speed formatter (ListeningFormat) and the speed scale
/// (SpeedScale) every speed control shares.
final class ListeningFormatTests: XCTestCase {

    // MARK: - SpeedScale

    func testPresetsAreThePRDSet() {
        XCTAssertEqual(SpeedScale.presets, [1, 1.25, 1.5, 2, 2.5])
        XCTAssertEqual(SpeedScale.range, 0.5...3.0)
        XCTAssertEqual(SpeedScale.step, 0.05)
    }

    func testSnapTable() {
        let table: [(raw: Double, snapped: Double)] = [
            (0.96, 1), (1.04, 1),          // inside the ±0.04 detent, inclusive
            (1.041, 1.05), (0.959, 0.95),  // just outside it
            (1.37, 1.35),                  // nearest 0.05 step
            (0.3, 0.5), (3.4, 3.0),        // clamped to the range
        ]
        for row in table {
            XCTAssertEqual(SpeedScale.snap(row.raw), row.snapped, accuracy: 1e-9, "snap(\(row.raw))")
        }
    }

    func testEverySnapIsAStepInRange() {
        for raw in stride(from: 0.0, through: 3.6, by: 0.007) {
            let snapped = SpeedScale.snap(raw)
            XCTAssertTrue(SpeedScale.range.contains(snapped), "snap(\(raw)) = \(snapped)")
            XCTAssertEqual(snapped * 20, (snapped * 20).rounded(), accuracy: 1e-9, "snap(\(raw)) = \(snapped)")
        }
    }

    func testClampedRateUsesTheScaleRange() {
        XCTAssertEqual(PlaybackController.clampedRate(0), SpeedScale.range.lowerBound)
        XCTAssertEqual(PlaybackController.clampedRate(9), SpeedScale.range.upperBound)
        XCTAssertEqual(PlaybackController.clampedRate(1.25), 1.25)
    }

    func testIsSelected() {
        XCTAssertTrue(SpeedScale.isSelected(1.5, at: 1.5000001))
        XCTAssertFalse(SpeedScale.isSelected(1.5, at: 1.55))
    }

    /// R20: the detent ticks only on arriving at 1×.
    func testLandsOnDetentTable() {
        let table: [(from: Double, to: Double, lands: Bool)] = [
            (0.95, 1, true),      // arriving
            (1, 1.05, false),     // leaving
            (1, 1, false),        // holding
            (0.9, 0.95, false),   // nowhere near
        ]
        for row in table {
            XCTAssertEqual(SpeedScale.landsOnDetent(from: row.from, to: row.to), row.lands,
                           "landsOnDetent(from: \(row.from), to: \(row.to))")
        }
    }

    // MARK: - ListeningFormat

    func testWholeRate() {
        XCTAssertEqual(ListeningFormat.rate(1), "1×")
        XCTAssertEqual(ListeningFormat.rate(2), "2×")
    }

    func testFractionalRates() throws {
        // `formatted()` follows the device locale; these strings assume en_US.
        try XCTSkipUnless(Locale.current.decimalSeparator == ".", "needs a '.' decimal separator")
        XCTAssertEqual(ListeningFormat.rate(1.25), "1.25×")
        XCTAssertEqual(ListeningFormat.rate(2.5), "2.5×")
        XCTAssertEqual(ListeningFormat.rate(1.2499999), "1.25×", "rounded to the hundredth")
        XCTAssertEqual(ListeningFormat.chipTitle(voice: michael, rate: 1.25), "Michael · 1.25×")
    }

    func testSpokenRateIsWords() throws {
        try XCTSkipUnless(Locale.current.decimalSeparator == ".", "needs a '.' decimal separator")
        XCTAssertEqual(ListeningCopy.spokenRate(1), "1 times speed")
        XCTAssertEqual(ListeningCopy.spokenRate(1.25), "1.25 times speed")
        XCTAssertEqual(ListeningCopy.spokenRate(2.5), "2.5 times speed")
        XCTAssertFalse(SpeedScale.presets.map(ListeningCopy.spokenRate).contains { $0.contains("×") })
    }

    func testIdentifierNumberIsLocaleFree() {
        XCTAssertEqual(ListeningFormat.identifierNumber(1), "1")
        XCTAssertEqual(ListeningFormat.identifierNumber(1.25), "1.25")
        XCTAssertEqual(ListeningFormat.identifierNumber(2.5), "2.5")
    }

    func testShortName() {
        XCTAssertEqual(ListeningFormat.shortName(AVSpeechEngine(mutesOutput: true).defaultVoice), "System")
        XCTAssertEqual(ListeningFormat.shortName(michael), "Michael")
    }

    private let michael = TtsVoice(id: "kokoro:am_michael", name: "Michael", lang: "en-US",
                                   gender: "m", engine: .kokoro, quality: 2)
}
