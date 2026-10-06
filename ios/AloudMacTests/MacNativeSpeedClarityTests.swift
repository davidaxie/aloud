import Accelerate
import AVFoundation
import XCTest
@testable import Aloud

/// How clear fast Kokoro speech is, measured (never asserted): the same
/// sentence brought to the listener's speed by the time-pitch unit alone
/// (today), or partly by Kokoro speaking faster itself and the rest by the
/// time-pitch unit, at two overlaps. Each result is compared with the 1x
/// clip it came from: a speed-up should keep the clip's spectrum, so a loss
/// of high frequencies or of spectral contrast (harmonics smeared into the
/// gaps between them) is what "muffled" measures.
///
/// SAFETY: nothing plays. The time-pitch unit runs in an AVAudioEngine in
/// offline manual rendering mode, which never opens an output device. Clips
/// go to WAV files in this host's temporary folder, for listening later.
///
/// Opt in: TEST_RUNNER_ALOUD_PERF=1 (minutes of every core).
final class MacNativeSpeedClarityTests: XCTestCase {

    private static let modelDirectory = URL(fileURLWithPath: "/Users/Shared/AloudKokoroModel", isDirectory: true)

    private static let sentences = [
        "Mr. Phileas Fogg lived, in 1872, at No. 7, Saville Row, Burlington Gardens.",
        "The door opened, and a tall, thin man stepped into the room without a word.",
        "Holmes leaned back in his chair, placed his finger-tips together, and closed his eyes, as though the "
            + "whole matter were already settled in his mind.",
        "Traction is a sign that your company is working, and the best way to get it is to test channels early.",
    ]

    /// One way of reaching the target speed.
    private struct Route {
        let label: String
        let native: Double
        let overlap: Float
    }

    private static func routes(to target: Double) -> [Route] {
        var routes = [Route(label: "today: 1.0 + stretch, overlap 8", native: 1.0, overlap: 8),
                      Route(label: "1.0 + stretch, overlap 32", native: 1.0, overlap: 32)]
        for native in [1.25, 1.5, 1.75, 2.0, 2.5] where native < target - 0.01 {
            routes.append(Route(label: String(format: "native %.2f + stretch, overlap 32", native),
                                native: native, overlap: 32))
        }
        routes.append(Route(label: String(format: "native %.2f + stretch, overlap 8", min(2.0, target)),
                            native: min(2.0, target), overlap: 8))
        routes.append(Route(label: String(format: "native %.2f only", target), native: target, overlap: 32))
        return routes
    }

    func testNativeSpeedClarity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALOUD_PERF"] == "1",
                          "measurement only: pass TEST_RUNNER_ALOUD_PERF=1 to run it")
        for name in ["model.onnx", "voices.bin"] {
            try XCTSkipUnless(FileManager.default.isReadableFile(
                atPath: Self.modelDirectory.appendingPathComponent(name).path), "no seeded model")
        }
        let samplesFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AloudSpeedSamples", isDirectory: true)
        try? FileManager.default.removeItem(at: samplesFolder)
        try FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        let blendFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AloudSpeedBlends", isDirectory: true)
        try FileManager.default.createDirectory(at: blendFolder, withIntermediateDirectories: true)

        let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory, blendDirectory: blendFolder)
        defer { engine.release() }
        let voices = ["kokoro:am_puck", "kokoro:am_michael", "kokoro:aloud_velvet"]
            .compactMap { id in engine.voices.first { $0.id == id } }

        var report = "Native-speed clarity. Each row: averages over \(Self.sentences.count) sentences, against "
            + "the 1x clip.\n"
            + "  hf_dB: change in the share of energy above 4 kHz (negative = duller)\n"
            + "  contrast_dB: change in spectral peak-to-valley contrast (negative = smeared)\n"
            + "  ltas_dB: RMS change of the 1/3-octave spectrum shape (lower = truer)\n"
            + "  speed: achieved speech-length speed-up; synth_s: Kokoro time per sentence\n"
        for target in [2.95, 1.5] {
            for voice in voices {
                report += String(format: "\n%@ at %.2fx\n", voice.name, target)
                report += "  route                                  hf_dB  contrast_dB  ltas_dB  speed  synth_s\n"
                // 1x references, one per sentence.
                var references: [[Float]] = []
                for sentence in Self.sentences {
                    references.append(try await engine.synthesize(sentence, voice: voice, speed: 1.0).samples)
                }
                for route in Self.routes(to: target) {
                    var hf = 0.0, contrast = 0.0, ltas = 0.0, speed = 0.0, synth = 0.0
                    for (index, sentence) in Self.sentences.enumerated() {
                        let start = Date()
                        let clip = try await engine.synthesize(sentence, voice: voice, speed: route.native)
                        synth += Date().timeIntervalSince(start)
                        let residual = Float(target / clip.nativeSpeed)
                        let output = abs(residual - 1) < 0.001
                            ? clip.samples
                            : try Self.stretch(clip.samples, sampleRate: clip.sampleRate,
                                               rate: residual, overlap: route.overlap)
                        let ref = Spectra(references[index], sampleRate: clip.sampleRate)
                        let out = Spectra(output, sampleRate: clip.sampleRate)
                        hf += out.highShareDB - ref.highShareDB
                        contrast += out.contrastDB - ref.contrastDB
                        ltas += out.shapeDistance(to: ref)
                        speed += ref.speechSeconds / max(out.speechSeconds, 0.001)
                        if index == 1, target == 2.95 {
                            let name = "\(voice.name)-\(route.label)"
                                .replacingOccurrences(of: ": ", with: "-")
                                .replacingOccurrences(of: ", ", with: "-")
                                .replacingOccurrences(of: " + ", with: "+")
                                .replacingOccurrences(of: " ", with: "_")
                            try Self.writeWAV(output, sampleRate: clip.sampleRate,
                                              to: samplesFolder.appendingPathComponent(name + ".wav"))
                        }
                    }
                    let n = Double(Self.sentences.count)
                    report += route.label.padding(toLength: 38, withPad: " ", startingAt: 0)
                        + String(format: " %6.2f  %11.2f  %7.2f  %5.2f  %7.2f\n",
                                 hf / n, contrast / n, ltas / n, speed / n, synth / n)
                }
            }
        }
        report += "\nWAV samples (sentence 2 at 2.95x): \(samplesFolder.path)\n"
        await Self.publish(report)
    }

    /// How much shorter Kokoro's clips really are at each native speed, for
    /// every listed voice, over sentences of two bundled classics: the whole
    /// clip's 1x length over its native length (what sets the listening
    /// pace). Prints `NativeSpeed.compression`'s table.
    func testNativeSpeedCompression() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALOUD_PERF"] == "1",
                          "measurement only: pass TEST_RUNNER_ALOUD_PERF=1 to run it")
        var sentences: [String] = []
        for (name, count) in [("103-around-the-world-in-eighty-days", 8), ("161-sense-and-sensibility", 8)] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Bookshelf")
                                    ?? Bundle.main.url(forResource: name, withExtension: "txt"))
            let text = try String(contentsOf: url, encoding: .utf8)
            let middle = text.index(text.startIndex, offsetBy: text.count / 2)
            var taken = 0
            for paragraph in text[middle...].components(separatedBy: "\n\n") where taken < count {
                for sentence in SentenceSegmenter.splitIntoSentences(paragraph.replacingOccurrences(of: "\n", with: " "))
                where (40...240).contains(sentence.count) && taken < count {
                    sentences.append(sentence)
                    taken += 1
                }
            }
        }
        let blendFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AloudSpeedBlends", isDirectory: true)
        try FileManager.default.createDirectory(at: blendFolder, withIntermediateDirectories: true)
        let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory, blendDirectory: blendFolder)
        defer { engine.release() }
        let speeds = [1.25, 1.5, 1.75, 2.0]
        var report = "Native-speed compression over \(sentences.count) sentences (1x length / native length)\n"
        var table = "static let measured: [String: [Double]] = [   // speeds \(speeds)\n"
        for voice in engine.voices {
            var lengths: [Double] = []
            for speed in [1.0] + speeds {
                var whole = 0.0
                for sentence in sentences {
                    whole += try await engine.synthesize(sentence, voice: voice, speed: speed).duration
                }
                lengths.append(whole)
            }
            let ratios = lengths.dropFirst().map { lengths[0] / $0 }
            report += voice.name.padding(toLength: 8, withPad: " ", startingAt: 0)
                + ratios.map { String(format: "  %.3f", $0) }.joined() + "\n"
            table += "    \"\(voice.id)\": [" + ratios.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "],\n"
        }
        report += "\n" + table + "]\n"
        await Self.publish(report)
    }

    // MARK: - Offline time-pitch

    /// `samples` through an AVAudioUnitTimePitch at `rate`, rendered offline:
    /// manual rendering never touches an output device.
    private static func stretch(_ samples: [Float], sampleRate: Double, rate: Float, overlap: Float) throws -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = rate
        timePitch.overlap = overlap
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try engine.start()
        defer { player.stop(); engine.stop() }
        player.scheduleBuffer(input, at: nil)
        player.play()
        let wanted = Int(Double(samples.count) / Double(rate)) + 2048
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var output: [Float] = []
        output.reserveCapacity(wanted)
        while output.count < wanted {
            let frames = AVAudioFrameCount(min(4096, wanted - output.count))
            guard try engine.renderOffline(frames, to: chunk) == .success else { break }
            let channel = chunk.floatChannelData![0]
            output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(chunk.frameLength)))
        }
        return output
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    @MainActor
    private static func publish(_ report: String) {
        print("\n===== Native-speed clarity =====\n\(report)===== end =====")
        XCTContext.runActivity(named: "Native-speed clarity") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "Native-speed clarity"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}

/// Short-time spectra of a clip (1024-point Hann frames, hop 256) over its
/// speech frames (within 40 dB of the loudest).
private struct Spectra {
    let sampleRate: Double
    /// Mean power per bin over speech frames, normalized to sum 1.
    let ltas: [Double]
    let highShareDB: Double
    let contrastDB: Double
    let speechSeconds: Double

    private static let size = 1024
    private static let hop = 256

    init(_ samples: [Float], sampleRate: Double) {
        self.sampleRate = sampleRate
        let n = Self.size, half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frames: [[Float]] = []
        var energies: [Float] = []
        var start = 0
        while start + n <= samples.count {
            var frame = [Float](repeating: 0, count: n)
            vDSP_vmul(Array(samples[start..<(start + n)]), 1, window, 1, &frame, 1, vDSP_Length(n))
            var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
            var power = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            frames.append(power)
            energies.append(power.reduce(0, +))
            start += Self.hop
        }
        let loudest = energies.max() ?? 0
        let speech = frames.indices.filter { energies[$0] > loudest * 1e-4 && loudest > 0 }
        var mean = [Double](repeating: 0, count: half)
        for index in speech { for bin in 0..<half { mean[bin] += Double(frames[index][bin]) } }
        let total = max(mean.reduce(0, +), 1e-30)
        ltas = mean.map { $0 / total }
        let binHz = sampleRate / Double(n)
        let high = ltas.enumerated().filter { Double($0.offset) * binHz >= 4000 }.reduce(0) { $0 + $1.element }
        highShareDB = 10 * log10(max(high, 1e-12))
        // Contrast: per speech frame, per octave band from 250 Hz, the mean
        // of the top fifth of bins minus the bottom fifth, in dB.
        var contrastSum = 0.0, contrastCount = 0
        var low = 250.0
        var bands: [Range<Int>] = []
        while low * 2 <= sampleRate / 2 {
            let a = Int(low / binHz), b = min(half, Int(low * 2 / binHz))
            if b - a >= 5 { bands.append(a..<b) }
            low *= 2
        }
        for index in speech {
            for band in bands {
                let db = frames[index][band].map { 10 * log10(Double(max($0, 1e-12))) }.sorted()
                let k = max(1, db.count / 5)
                contrastSum += db.suffix(k).reduce(0, +) / Double(k) - db.prefix(k).reduce(0, +) / Double(k)
                contrastCount += 1
            }
        }
        contrastDB = contrastCount > 0 ? contrastSum / Double(contrastCount) : 0
        if let first = speech.first, let last = speech.last {
            speechSeconds = Double(last - first) * Double(Self.hop) / sampleRate
        } else {
            speechSeconds = 0
        }
    }

    /// RMS difference of the two spectra's 1/3-octave levels, 100 Hz to 10 kHz.
    func shapeDistance(to other: Spectra) -> Double {
        let binHz = sampleRate / Double(Self.size)
        var low = 100.0, sum = 0.0, count = 0
        while low * pow(2, 1.0 / 3) <= 10_000 {
            let high = low * pow(2, 1.0 / 3)
            let range = Int(low / binHz)..<max(Int(low / binHz) + 1, Int(high / binHz))
            let a = range.reduce(0.0) { $0 + ltas[$1] }, b = range.reduce(0.0) { $0 + other.ltas[$1] }
            let d = 10 * log10(max(a, 1e-12)) - 10 * log10(max(b, 1e-12))
            sum += d * d
            count += 1
            low = high
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }
}
