#if os(iOS)
import Foundation
import XCTest
@testable import Aloud

/// P012: Kokoro's ONNX Runtime threads on an iPhone, measured (never
/// asserted) for the choice in `PlatformTuning.kokoroThreads` and
/// `kokoroStopsThreadSpinning`. The iPhone's budgets (M19): synthesis at
/// least 2.5x real time at the 2x speed tier, first audio within 1 s warm
/// and 4 s cold.
///
/// Three configurations over the same fixed 20-sentence passage, each on a
/// fresh engine (about 800 MB, freed before the next): 2 threads spinning
/// (the old default), 2 not spinning (the shipping one) and 3 not
/// spinning. For each: the cold load (model, graph and warm line), then
/// the real-time factor and the CPU-seconds per second of audio over the
/// passage. A third thread is worth taking only if it reads at least 15%
/// faster for no more CPU-seconds per second of audio on the A14 floor
/// device.
///
/// SAFETY: nothing plays. No audio graph, no output device, no file is
/// written beyond the engine's own provider config: each clip's duration
/// is the only thing kept. Opt in with TEST_RUNNER_ALOUD_PERF=1 on a device
/// with the natural voice installed; a simulator or an ordinary run skips.
final class IOSSynthesisPerfTests: XCTestCase {

    /// The model the app installed, in the test host's own container.
    private static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KokoroModel", isDirectory: true)
    }

    /// A fixed passage of typical book sentences, short to long, one per
    /// synthesis as the reader segments them.
    private static let passage = [
        "It was the best of times, it was the worst of times.",
        "Mr. Phileas Fogg lived, in 1872, at No. 7, Saville Row, Burlington Gardens.",
        "The door opened, and a tall, thin man stepped into the room without a word.",
        "She had no reason to doubt it.",
        "\"Where are you going?\" she asked.",
        "\"Out,\" he said.",
        "Holmes leaned back in his chair, placed his finger-tips together, and closed his eyes.",
        "The sea was calm, the wind had dropped, and the little boat drifted slowly toward the shore.",
        "\"I cannot tell you,\" said he, after a long pause, \"how much I regret what has passed between us.\"",
        "For a moment nobody spoke; then the old clock in the hall struck nine, and the spell was broken.",
        "Nobody answered.",
        "They walked on in silence until they reached the gate, where Elizabeth stopped and looked back.",
        "The rain had not let up since morning, and the road into town was a river of mud.",
        "\"Is it far?\"",
        "\"Not far now.\"",
        "He counted the coins twice, frowned, and put them back in the drawer without a word.",
        "Outside, a dog barked once and was quiet.",
        "The letter, when it came at last, was shorter than any of them had feared.",
        "She read it through, folded it, and set it on the mantelpiece beside the clock.",
        "Then she sat down by the fire and did not move again until the lamps were lit.",
    ]

    private struct Configuration {
        let threads: Int
        let spinningOff: Bool
        var label: String { "\(threads)t " + (spinningOff ? "no spin" : "spin") }
    }

    private static let configurations = [
        Configuration(threads: 2, spinningOff: false),
        Configuration(threads: 2, spinningOff: true),
        Configuration(threads: 3, spinningOff: true),
    ]

    func testThreadsAndSpinningRealTimeFactorAndCPU() async throws {
        try Self.requireDeviceAndModel()
        var lines: [String] = []
        for configuration in Self.configurations {
            let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory,
                                            numThreads: configuration.threads,
                                            stopsThreadSpinning: configuration.spinningOff)
            let voice = engine.defaultVoice
            let loadStart = Self.now()
            try await engine.warmUp()   // load + graph build + warm line: cold first audio's cost
            let load = Self.now() - loadStart

            var audio: Double = 0
            var compute: Double = 0
            var firstLatency: Double?
            let cpuStart = Self.cpuSeconds()
            for sentence in Self.passage {
                let start = Self.now()
                let clip = try await engine.synthesize(sentence, voice: voice)
                let latency = Self.now() - start
                firstLatency = firstLatency ?? latency
                compute += latency
                audio += clip.duration
            }
            let cpu = Self.cpuSeconds() - cpuStart
            engine.release()
            lines.append(configuration.label.padding(toLength: 12, withPad: " ", startingAt: 0)
                         + String(format: "%8.2f %10.2f %9.2f %9.2f %8.2f %14.3f",
                                  load, firstLatency ?? 0, audio, compute,
                                  compute > 0 ? audio / compute : 0, audio > 0 ? cpu / audio : 0))
        }
        var report = "Kokoro on this iPhone (KokoroSherpaEngine; shipping: \(PlatformTuning.kokoroThreads) threads, "
            + "spinning " + (PlatformTuning.kokoroStopsThreadSpinning ? "off" : "on") + ")\n"
        report += "config        load_s  warm_first_s  audio_s  compute_s  RTF(x)  cpu_s/audio_s\n"
        report += lines.joined(separator: "\n") + "\n"
        report += "budgets: RTF >= 2.5x (the 2x speed tier), first audio <= 1 s warm, <= 4 s cold (load_s)\n"
        report += "take 3 threads only if its RTF is >= 1.15x the 2t no-spin RTF with no more cpu_s/audio_s\n"
        report += Self.deviceLine()
        await Self.publish(report, named: "Kokoro iPhone threads")
    }

    // MARK: - Helpers

    private static func requireDeviceAndModel() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("measurement only: run on a device, never the simulator")
        #else
        // Measurement only, and every core for a minute: opt in.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALOUD_PERF"] == "1",
                          "measurement only: pass TEST_RUNNER_ALOUD_PERF=1 to run it")
        try XCTSkipUnless(ModelManager.installedFilesLookIntact(in: modelDirectory),
                          "install the natural voice in the app on this device first")
        #endif
    }

    /// Monotonic seconds.
    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// The process's user + system CPU time, every thread (ONNX Runtime's
    /// pool included).
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func deviceLine() -> String {
        func sysctlInt(_ name: String) -> String {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? String(value) : "?"
        }
        var size = 0
        var model = "?"
        if sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 { model = String(cString: buffer) }
        }
        return "device: \(model), \(sysctlInt("hw.perflevel0.physicalcpu"))P + "
            + "\(sysctlInt("hw.perflevel1.physicalcpu"))E cores, "
            + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled), "
            + "thermal \(ProcessInfo.processInfo.thermalState.rawValue)\n"
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
}
#endif
