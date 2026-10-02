import SwiftUI
import XCTest
@testable import Aloud

/// R20's haptic vocabulary and its one publisher. Pure: nothing plays, and
/// the DEBUG log is the spy.
@MainActor
final class TransportHapticsTests: XCTestCase {

    private var haptics: TransportHaptics { TransportHaptics.shared }

    override func setUp() {
        super.setUp()
        haptics.resetLog()
    }

    override func tearDown() {
        haptics.resetLog()
        super.tearDown()
    }

    func testFeedbackMapping() {
        XCTAssertEqual(TransportHaptic.play.feedback, .impact(flexibility: .soft, intensity: 0.6))
        XCTAssertEqual(TransportHaptic.pause.feedback, .impact(weight: .light))
        for haptic in [TransportHaptic.detent, .preset, .scrubRelease] {
            XCTAssertEqual(haptic.feedback, .selection, "\(haptic)")
        }
        XCTAssertEqual(TransportHaptic.finished.feedback, .success, "R24: one success at a book's end")
        XCTAssertEqual(TransportHaptic.finished.rawValue, "finished")
        XCTAssertEqual(TransportHaptic.allCases.count, 6, "the vocabulary is exactly six haptics")
    }

    func testToggleEmitsPauseWhenActiveAndPlayOtherwise() {
        TransportHaptics.emitToggle(isActive: true)
        XCTAssertEqual(haptics.log, [.pause])

        haptics.resetLog()
        TransportHaptics.emitToggle(isActive: false)
        XCTAssertEqual(haptics.log, [.play])
    }

    func testIdenticalEmitsGiveDistinctPulses() throws {
        TransportHaptics.emit(.preset)
        let first = try XCTUnwrap(haptics.pulse)
        TransportHaptics.emit(.preset)
        let second = try XCTUnwrap(haptics.pulse)

        XCTAssertEqual(first.haptic, .preset)
        XCTAssertEqual(second.haptic, .preset)
        XCTAssertNotEqual(first.serial, second.serial)
        XCTAssertNotEqual(first, second, "a repeat must change the trigger, or it would not play")
    }

    func testLogKeepsTheLatestHundred() {
        for _ in 0..<100 { TransportHaptics.emit(.play) }
        for _ in 0..<5 { TransportHaptics.emit(.pause) }

        XCTAssertEqual(haptics.log.count, 100)
        XCTAssertEqual(haptics.log.first, .play)
        XCTAssertEqual(Array(haptics.log.suffix(5)), Array(repeating: .pause, count: 5))
    }

    func testLogTextJoinsRawValues() {
        TransportHaptics.emit(.play)
        TransportHaptics.emit(.scrubRelease)
        TransportHaptics.emit(.detent)
        TransportHaptics.emit(.finished)
        XCTAssertEqual(haptics.logText, "play,scrubRelease,detent,finished")

        haptics.resetLog()
        XCTAssertEqual(haptics.logText, "")
    }

    // MARK: - The 1× detent through the slider's snap

    /// R20: a drag from 0.8× to 1.2× ticks once, at 1.0×; back down ticks
    /// once more; resting on 1.0× is silent.
    func testDragAcrossTheDetentTicksOncePerCrossing() {
        let up = stride(from: 0.80, through: 1.20 + 1e-9, by: 0.01).map { $0 }
        XCTAssertEqual(drag(through: up, from: SpeedScale.snap(0.80)), 1)
        XCTAssertEqual(haptics.log, [.detent])

        haptics.resetLog()
        XCTAssertEqual(drag(through: up.reversed(), from: SpeedScale.snap(1.20)), 1)
        XCTAssertEqual(haptics.log, [.detent])

        haptics.resetLog()
        XCTAssertEqual(drag(through: Array(repeating: 1.0, count: 20), from: 1.0), 0)
        XCTAssertEqual(haptics.log, [])
    }

    /// The slider's set closure, step by step: snap, tick on landing, move.
    private func drag(through raws: [Double], from start: Double) -> Int {
        var rate = start
        var landings = 0
        for raw in raws {
            let snapped = SpeedScale.snap(raw)
            if SpeedScale.landsOnDetent(from: rate, to: snapped) {
                landings += 1
                TransportHaptics.emit(.detent)
            }
            rate = snapped
        }
        return landings
    }
}
