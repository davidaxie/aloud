import Foundation
import XCTest
@testable import Aloud

/// M19's synthesis budgets, measured (never asserted): first audio <= 1.0 s
/// warm and <= 3.5 s cold, synthesis >= 5x real time. Kokoro reads the
/// pinned model from /Users/Shared/AloudKokoroModel, offline, into sample
/// buffers that are counted and dropped.
///
/// SAFETY: nothing plays. No audio graph, no output device, no file is
/// written: each clip's sample count is the only thing kept.
///
/// - The shipping engine (`KokoroSherpaEngine`, at
///   `PlatformTuning.kokoroThreads`): cold first audio (model load, graph
///   build and warm-up utterance, then the first sentence, as Play pays it
///   when nothing pre-warmed), then each sentence on the warm engine.
/// - A thread sweep (1, 2, 4, 6, 8, spinning on and off): the engine
///   itself at each count (`init(modelDirectory:numThreads:...)`).
///
/// The tables print to the test log and attach to the result bundle.
final class MacSynthesisPerfTests: XCTestCase {

    private static let modelDirectory = URL(fileURLWithPath: "/Users/Shared/AloudKokoroModel", isDirectory: true)

    /// Typical book sentences, short to long, one per synthesis as the
    /// reader segments them (the same ten as the scratchpad's Python
    /// benchmark, for comparison).
    private static let sentences = [
        "It was the best of times, it was the worst of times.",
        "Mr. Phileas Fogg lived, in 1872, at No. 7, Saville Row, Burlington Gardens.",
        "The door opened, and a tall, thin man stepped into the room without a word.",
        "However little known the feelings or views of such a man may be on his first entering a neighbourhood, "
            + "this truth is so well fixed in the minds of the surrounding families, that he is considered the "
            + "rightful property of some one or other of their daughters.",
        "She had no reason to doubt it.",
        "Holmes leaned back in his chair, placed his finger-tips together, and closed his eyes, as though the "
            + "whole matter were already settled in his mind.",
        "The sea was calm, the wind had dropped, and the little boat drifted slowly toward the shore.",
        "\"I cannot tell you,\" said he, after a long pause, \"how much I regret what has passed between us.\"",
        "For a moment nobody spoke; then the old clock in the hall struck nine, and the spell was broken.",
        "They walked on in silence until they reached the gate, where Elizabeth stopped, turned, and looked "
            + "back at the house with an expression that her companion could not read, though he tried for "
            + "some time to understand it.",
    ]

    private static let threadCounts = [1, 2, 4, 6, 8]

    /// The engine's own warm-up line.
    private static let warmUpLine = "Aloud is ready."

    // MARK: - The shipping engine

    func testShippingEngineFirstAudioAndRealTimeFactor() async throws {
        try Self.requireModel()
        let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory)
        defer { engine.release() }
        let voice = engine.defaultVoice

        // Play on a cold engine: synthesize pays load + graph + warm line first.
        let coldStart = Self.now()
        let first = try await engine.synthesize(Self.sentences[0], voice: voice)
        let coldFirstAudio = Self.now() - coldStart
        XCTAssertTrue(engine.isWarm)

        // Warm now; the engine keeps no cache, so sentence 0 synthesizes again.
        var rows: [SentenceRow] = []
        for sentence in Self.sentences {
            let cpuStart = Self.cpuSeconds()
            let start = Self.now()
            let audio = try await engine.synthesize(sentence, voice: voice)
            rows.append(SentenceRow(chars: sentence.count,
                                    latency: Self.now() - start,
                                    audioSeconds: audio.duration,
                                    cpuSeconds: Self.cpuSeconds() - cpuStart))
        }

        let summary = Summary(label: "engine @\(PlatformTuning.kokoroThreads)t",
                              load: nil, warmLine: nil, rows: rows)
        var report = "Shipping KokoroSherpaEngine (threads = PlatformTuning.kokoroThreads = "
            + "\(PlatformTuning.kokoroThreads), provider cpu, voice \(voice.id))\n"
        report += String(format: "cold first audio (load + graph + warm line + sentence 0): %.2f s "
                            + "[M19 budget 3.5 s]; sentence 0 audio %.2f s\n",
                         coldFirstAudio, first.duration)
        report += Self.sentenceTable(rows)
        report += Summary.header + "\n" + summary.line + "\n"
        report += Self.speedNote
        report += Self.machineLine()
        await Self.publish(report, named: "Kokoro shipping engine")
    }

    // MARK: - Thread sweep

    func testThreadSweepWarmUpFirstSentenceAndRealTimeFactor() async throws {
        try Self.requireModel()
        var summaries: [Summary] = []
        var tables = ""
        // The app's own engine at each count, with ONNX Runtime's spinning
        // on and (from 2 threads) off, freed (about 800 MB) before the next.
        for threads in Self.threadCounts {
            for spinningOff in threads >= 2 ? [false, true] : [false] {
                let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory, numThreads: threads,
                                                stopsThreadSpinning: spinningOff)
                let voice = engine.defaultVoice
                let warmStart = Self.now()
                try await engine.warmUp()   // load + graph build + warm line
                let warmUp = Self.now() - warmStart
                var rows: [SentenceRow] = []
                for sentence in Self.sentences {
                    let cpuStart = Self.cpuSeconds()
                    let start = Self.now()
                    let audio = try await engine.synthesize(sentence, voice: voice)
                    rows.append(SentenceRow(chars: sentence.count, latency: Self.now() - start,
                                            audioSeconds: audio.duration,
                                            cpuSeconds: Self.cpuSeconds() - cpuStart))
                }
                engine.release()
                let summary = Summary(label: "\(threads)t" + (spinningOff ? " nospin" : ""),
                                      load: warmUp, warmLine: nil, rows: rows)
                summaries.append(summary)
                tables += "\(summary.label):\n" + Self.sentenceTable(rows)
            }
        }

        var report = "Kokoro thread sweep (KokoroSherpaEngine; load_s = load + graph + warm line; "
            + "shipping: \(PlatformTuning.kokoroThreads) threads, spinning "
            + (PlatformTuning.kokoroStopsThreadSpinning ? "off" : "on") + ")\n"
        report += Summary.header + "\n" + summaries.map(\.line).joined(separator: "\n") + "\n"
        report += "M19: first audio <= 1.0 s warm, <= 3.5 s cold; synthesis >= 5x real time\n"
        report += Self.speedNote
        report += Self.machineLine()
        report += tables
        await Self.publish(report, named: "Kokoro thread sweep")
    }

    // MARK: - Rows and tables

    private struct SentenceRow: Sendable {
        let chars: Int
        let latency: Double
        let audioSeconds: Double
        let cpuSeconds: Double
    }

    private struct Summary: Sendable {
        let label: String
        let load: Double?
        let warmLine: Double?
        let rows: [SentenceRow]

        static let header = "config          load_s  warm_line_s  first_s  longest_s  median_s  "
            + "audio_s  compute_s  RTF(x)  cpu_s/audio_s"

        var line: String {
            let latencies = rows.map(\.latency).sorted()
            let median = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
            let audio = rows.reduce(0) { $0 + $1.audioSeconds }
            let compute = rows.reduce(0) { $0 + $1.latency }
            let cpu = rows.reduce(0) { $0 + $1.cpuSeconds }
            func cell(_ value: Double?, _ width: Int) -> String {
                let text = value.map { String(format: "%.2f", $0) } ?? "-"
                return String(repeating: " ", count: max(0, width - text.count)) + text
            }
            return label.padding(toLength: 14, withPad: " ", startingAt: 0)
                + cell(load, 8) + cell(warmLine, 13) + cell(rows.first?.latency, 9)
                + cell(latencies.last, 11) + cell(median, 10) + cell(audio, 9) + cell(compute, 11)
                + cell(compute > 0 ? audio / compute : nil, 8)
                + cell(audio > 0 ? cpu / audio : nil, 15)
        }
    }

    private static func sentenceTable(_ rows: [SentenceRow]) -> String {
        var table = "  #  chars  latency_s  audio_s  RTF(x)\n"
        for (index, row) in rows.enumerated() {
            table += String(format: "%3d  %5d  %9.3f  %7.2f  %6.1f\n",
                            index, row.chars, row.latency, row.audioSeconds,
                            row.latency > 0 ? row.audioSeconds / row.latency : 0)
        }
        return table
    }

    /// Playback speed is applied after synthesis (the time-pitch unit), so
    /// reading keeps up only while RTF stays above the chosen speed.
    private static let speedNote = "reading keeps up only while RTF(x) exceeds the playback speed "
        + "(SpeedScale \(SpeedScale.range.lowerBound)x...\(SpeedScale.range.upperBound)x), with margin for "
        + "short sentences and a busy machine\n"

    private static func machineLine() -> String {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        return "machine: \(sysctlString("machdep.cpu.brand_string") ?? "?"), "
            + "\(sysctlInt("hw.perflevel0.physicalcpu").map(String.init) ?? "?")P + "
            + "\(sysctlInt("hw.perflevel1.physicalcpu").map(String.init) ?? "?")E cores, "
            + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled), "
            + String(format: "load average %.1f %.1f %.1f\n", load[0], load[1], load[2])
    }

    /// XCTest runs activities on the main thread only.
    @MainActor
    private static func publish(_ report: String, named name: String) {
        print("\n===== \(name) =====\n\(report)===== end \(name) =====")
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    // MARK: - Helpers

    private static func requireModel() throws {
        // Measurement only, and minutes of every core: opt in with
        // TEST_RUNNER_ALOUD_PERF=1, so an ordinary run never competes with
        // someone listening on this Mac.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALOUD_PERF"] == "1",
                          "measurement only: pass TEST_RUNNER_ALOUD_PERF=1 to run it")
        for name in ["model.onnx", "voices.bin"] {
            let path = modelDirectory.appendingPathComponent(name).path
            try XCTSkipUnless(FileManager.default.isReadableFile(atPath: path),
                              "\(path) is missing or unreadable: run ios/tools/fetch_kokoro_model.sh (353 MB, "
                                + "with the owner's OK); a sandboxed Release host can't read it at all")
        }
        try XCTSkipUnless(ModelManager.installedFilesLookIntact(in: modelDirectory),
                          "the seed doesn't match ModelManager's pinned sizes: rerun ios/tools/fetch_kokoro_model.sh")
    }

    /// Monotonic seconds.
    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// The process's user + system CPU time (every thread: ONNX Runtime's
    /// pool included).
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
