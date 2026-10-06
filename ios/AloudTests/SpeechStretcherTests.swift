import XCTest
@testable import Aloud

/// Speech sped up or slowed in the time domain (`SpeechStretcher`), so the
/// time-pitch unit and its ring are bypassed: the length lands on the speed
/// asked, the pitch stays, nothing is amplified, and short or 1x clips come
/// back as they were. Pure: synthetic voiced signals, nothing plays.
final class SpeechStretcherTests: XCTestCase {

    private let rate = 24_000.0

    /// A voiced-speech stand-in: a 120 Hz tone with harmonics under a
    /// syllable-like envelope, then a quiet tail as a sentence ends.
    private func voice(seconds: Double, pitch: Double = 120) -> [Float] {
        let count = Int(seconds * rate)
        let tail = Int(0.15 * rate)
        return (0..<count).map { index in
            guard index < count - tail else { return 0 }
            let t = Double(index) / rate
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            let tone = sin(2 * .pi * pitch * t) + 0.5 * sin(2 * .pi * 2 * pitch * t) + 0.25 * sin(2 * .pi * 3 * pitch * t)
            return Float(0.3 * envelope * tone)
        }
    }

    /// Upward zero crossings per second over the voiced part: the pitch.
    private func pitch(_ samples: [Float], voicedFraction: Double) -> Double {
        let voiced = samples.prefix(Int(Double(samples.count) * voicedFraction))
        var crossings = 0
        var previous: Float = 0
        for sample in voiced {
            if previous < 0, sample >= 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(voiced.count) / rate)
    }

    func testFasterSpeechIsShorterByTheSpeedAndKeepsItsPitch() {
        let input = voice(seconds: 3)
        for speed in [1.25, 1.44, 1.65, 2.0, 2.95] {
            let output = SpeechStretcher.stretch(input, sampleRate: rate, speed: speed)
            XCTAssertEqual(Double(output.count), Double(input.count) / speed, accuracy: 1.5, "length at \(speed)")
            XCTAssertEqual(pitch(output, voicedFraction: 0.8), pitch(input, voicedFraction: 0.8),
                           accuracy: pitch(input, voicedFraction: 0.8) * 0.06, "pitch kept at \(speed)")
            let peak = output.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, (input.map(abs).max() ?? 0) * 1.001, "never louder at \(speed)")
            XCTAssertFalse(output.contains { !$0.isFinite })
        }
    }

    func testSlowerSpeechIsLongerAndKeepsItsPitch() {
        let input = voice(seconds: 2)
        for speed in [0.5, 0.75, 0.9] {
            let output = SpeechStretcher.stretch(input, sampleRate: rate, speed: speed)
            XCTAssertEqual(Double(output.count), Double(input.count) / speed, accuracy: 1.5, "length at \(speed)")
            XCTAssertEqual(pitch(output, voicedFraction: 0.8), pitch(input, voicedFraction: 0.8),
                           accuracy: pitch(input, voicedFraction: 0.8) * 0.06, "pitch kept at \(speed)")
        }
    }

    func testOneTimesAndTinyClipsComeBackAsTheyWere() {
        let input = voice(seconds: 1)
        XCTAssertEqual(SpeechStretcher.stretch(input, sampleRate: rate, speed: 1.0), input)
        XCTAssertEqual(SpeechStretcher.stretch(input, sampleRate: rate, speed: 1.001), input)
        let tiny = Array(input.prefix(500))
        XCTAssertEqual(SpeechStretcher.stretch(tiny, sampleRate: rate, speed: 2), tiny, "too short to find a period")
        XCTAssertEqual(SpeechStretcher.stretch([], sampleRate: rate, speed: 2), [])
        XCTAssertEqual(SpeechStretcher.stretch(input, sampleRate: rate, speed: .nan), input)
    }

    /// The clip carries everything it was sped up by: Kokoro's own share
    /// times what the stretch achieved.
    func testTheClipCarriesItsWholeSpeedUp() {
        let clip = SynthesizedAudio(samples: voice(seconds: 2), sampleRate: rate, nativeSpeed: 1.5)
        let stretched = SpeechStretcher.stretch(clip, speed: 1.44)
        XCTAssertEqual(stretched.nativeSpeed, 1.5 * 1.44, accuracy: 0.002)
        XCTAssertEqual(stretched.naturalDuration, clip.naturalDuration, accuracy: 0.001, "the same 1x length")
        let silence = SynthesizedAudio.silence(duration: 0.5, sampleRate: rate)
        XCTAssertEqual(SpeechStretcher.stretch(silence, speed: 2).duration, 0.25, accuracy: 0.001)
    }
}
