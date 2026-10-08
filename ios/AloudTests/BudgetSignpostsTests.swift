import Combine
import XCTest
import os
@testable import Aloud

/// M19's budget signposts (contracts §9 S3-D): five named intervals on
/// subsystem the bundle id, category "Budgets", compiled in Release. Every
/// begin has one end on every path that begins it: a check that finds
/// nothing, a verify whose hasher throws or that a newer detection outran,
/// a warm-up that throws or that a memory warning cancelled, and a Play
/// paused before it sounded. Nothing an interval carries is text: only the
/// budget, "warm" or "cold", and whether it gave up.
///
/// Silent and isolated: every part records through its own `Recorder`
/// (never the unified log, except the one test that pairs the live
/// signposter), the muted playback rig, sparse model files with a hasher
/// that answers from a table, `startsNetworkTasks` off, and notifications
/// on a private center.
@MainActor
final class BudgetSignpostsTests: XCTestCase {

    typealias Budget = BudgetSignposts.Budget

    /// Every begin and end, in order, keyed by the interval it names.
    final class Recorder: BudgetSignpostRecording, @unchecked Sendable {
        struct Event {
            enum Kind { case begin(BudgetSignposts.Start?), end(gaveUp: Bool) }
            let budget: Budget
            let kind: Kind
            let interval: ObjectIdentifier
        }

        private let lock = NSLock()
        private var log: [Event] = []
        /// Held, so no two intervals ever share an identity.
        private var states: [OSSignpostIntervalState] = []

        var signposts: BudgetSignposts { BudgetSignposts(recorder: self) }
        var events: [Event] { lock.withLock { log } }

        func begin(_ budget: Budget, start: BudgetSignposts.Start?) -> OSSignpostIntervalState {
            lock.withLock {
                let state = OSSignpostIntervalState.beginState(id: OSSignpostID(UInt64(states.count + 1)))
                states.append(state)
                log.append(Event(budget: budget, kind: .begin(start), interval: ObjectIdentifier(state)))
                return state
            }
        }

        func end(_ budget: Budget, _ state: OSSignpostIntervalState, gaveUp: Bool) {
            lock.withLock {
                log.append(Event(budget: budget, kind: .end(gaveUp: gaveUp), interval: ObjectIdentifier(state)))
            }
        }

        /// `budget`'s events as words: "begin", "begin warm", "begin cold",
        /// "end" and "gave up".
        func trace(_ budget: Budget) -> [String] {
            events.filter { $0.budget == budget }.map { event in
                switch event.kind {
                case .begin(nil): return "begin"
                case .begin(let start?): return "begin \(start.rawValue)"
                case .end(let gaveUp): return gaveUp ? "gave up" : "end"
                }
            }
        }

        /// What breaks "one end per begin": an end for no open interval of
        /// its budget, and every interval still open.
        var unpaired: [String] {
            var open: [ObjectIdentifier: Budget] = [:]
            var problems: [String] = []
            for event in events {
                switch event.kind {
                case .begin:
                    open[event.interval] = event.budget
                case .end:
                    if open.removeValue(forKey: event.interval) != event.budget {
                        problems.append("an extra \(event.budget.rawValue) end")
                    }
                }
            }
            return problems + open.values.map { "\($0.rawValue) never ended" }
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - The five budgets

    func testTheIntervalsAreTheFiveBudgetsAndTheDrySpells() {
        XCTAssertEqual(Budget.allCases.map(\.rawValue),
                       ["launch", "modelCheck", "modelVerify", "kokoroWarmup", "firstAudio", "catchingUp"])
        for budget in Budget.allCases {
            XCTAssertEqual(budget.name.description, budget.rawValue, "Instruments lists it by its budget")
        }
        XCTAssertEqual(OSBudgetRecorder.category, "Budgets")
        XCTAssertEqual(OSBudgetRecorder().subsystem, Bundle.main.bundleIdentifier)
    }

    /// The only words any interval carries.
    func testTheOnlyWordsAreWarmColdAndGaveUp() {
        XCTAssertEqual(BudgetSignposts.Start.allCases.map(\.rawValue), ["warm", "cold"])
        let recorder = Recorder()
        let signposts = recorder.signposts
        signposts.end(signposts.begin(.firstAudio, .warm))
        signposts.end(signposts.begin(.firstAudio, .cold), gaveUp: true)
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "end", "begin cold", "gave up"])
    }

    func testAnOptionalEndsOnceAndClears() {
        let recorder = Recorder()
        let signposts = recorder.signposts
        var open: BudgetSignposts.Interval? = signposts.begin(.launch)
        signposts.end(&open)
        XCTAssertNil(open)
        signposts.end(&open)
        signposts.end(&open, gaveUp: true)
        XCTAssertEqual(recorder.trace(.launch), ["begin", "end"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// The live signposter takes every budget, tag and ending (it writes to
    /// the unified log, which nothing here reads back).
    func testTheLiveSignposterPairsEveryBudget() {
        let live = BudgetSignposts.live
        for budget in Budget.allCases {
            live.end(live.begin(budget))
        }
        live.end(live.begin(.firstAudio, .warm))
        live.end(live.begin(.firstAudio, .cold), gaveUp: true)
        // Two of one name may overlap: each has its own ID.
        let first = live.begin(.modelVerify)
        let second = live.begin(.modelVerify)
        live.end(first)
        live.end(second)
    }

    // MARK: - Launch

    /// The app's model began it; the Library root's first appearance ends
    /// it (the iPhone host's RootView already has; the windowless Mac host
    /// gets it here), and a later appearance changes nothing.
    func testLaunchEndsAtTheLibrarysFirstAppearance() async {
        let model = AppModel.shared
        await model.performLaunchTasks()
        XCTAssertNil(model.launchInterval)
        await model.performLaunchTasks()
        XCTAssertNil(model.launchInterval)
    }

    // MARK: - Model check and verify

    /// Answers the pinned hashes, a wrong one, or throws; waits for `latch`
    /// when there is one.
    private final class FakeHasher: @unchecked Sendable {
        enum Answer { case pinned, wrong, throwing }
        private let answer: Answer
        private let lock = NSLock()
        private var released: Bool

        init(_ answer: Answer = .pinned, held: Bool = false) {
            self.answer = answer
            released = !held
        }

        func release() { lock.withLock { released = true } }

        func hash(_ url: URL) throws -> String {
            let deadline = Date().addingTimeInterval(5)
            while !lock.withLock({ released }), Date() < deadline { usleep(2_000) }
            switch answer {
            case .pinned:
                return ModelManager.remoteFiles.first { $0.name == url.lastPathComponent }?.sha256 ?? ""
            case .wrong:
                return String(repeating: "0", count: 64)
            case .throwing:
                throw CocoaError(.fileReadNoPermission)
            }
        }
    }

    private var directory: URL!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgetSignpostsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "aloud.tests.budgetSignposts.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        suite = nil
        super.tearDown()
    }

    private func makeManager(_ hasher: FakeHasher, recorder: Recorder) -> ModelManager {
        let manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: false),
                                   installDirectory: directory,
                                   defaults: UserDefaults(suiteName: suite)!,
                                   freeSpace: { 2_000_000_000 },
                                   hasher: { try hasher.hash($0) })
        manager.startsNetworkTasks = false
        manager.announce = { _ in }
        // From here on; the init's own detection went to the live log.
        manager.budgetSignposts = recorder.signposts
        return manager
    }

    /// Both files at their pinned sizes in `folder`, sparse (no disk use).
    private func writePinnedSizes(in folder: URL, size: ((ModelManager.RemoteFile) -> Int64)? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ModelManager.remoteFiles {
            let url = folder.appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size?(file) ?? file.expectedBytes))
            try handle.close()
        }
    }

    private func drain(_ manager: ModelManager) async {
        for _ in 0..<4 {
            guard let task = manager.verification else { return }
            await task.value
        }
    }

    /// Nothing on disk, damaged sizes, a vouched install and an unvouched
    /// one: each detection is one check, begun and ended.
    func testModelCheckEndsOnEveryDetection() async throws {
        let recorder = Recorder()
        let manager = makeManager(FakeHasher(), recorder: recorder)
        manager.detectExisting()                       // nothing there

        try writePinnedSizes(in: directory) { $0.expectedBytes - 1 }
        manager.detectExisting()                       // wrong sizes: damaged, no hash
        XCTAssertEqual(manager.state, .failed(.damaged))

        try writePinnedSizes(in: directory)
        manager.detectExisting()                       // no record: hashed in the background
        XCTAssertTrue(manager.isVerifying)
        await drain(manager)
        XCTAssertEqual(manager.state, .installed)
        manager.detectExisting()                       // the record vouches: two stats

        XCTAssertEqual(recorder.trace(.modelCheck), Array(repeating: ["begin", "end"], count: 4).flatMap { $0 })
        XCTAssertEqual(recorder.trace(.modelVerify), ["begin", "end"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// The launch verify ends whatever the hashes say, a throwing hasher's
    /// unreadable file included.
    func testLaunchVerifyEndsForEveryAnswer() async throws {
        try writePinnedSizes(in: directory)
        for answer in [FakeHasher.Answer.pinned, .wrong, .throwing] {
            let recorder = Recorder()
            let manager = makeManager(FakeHasher(answer), recorder: recorder)
            await drain(manager)   // the init's own verify, to the live log
            // Unvouched again, so this detection hashes too.
            try? FileManager.default.removeItem(at: ModelInstallRecord.url(in: directory))
            manager.detectExisting()
            await drain(manager)
            XCTAssertEqual(manager.state, answer == .pinned ? .installed : .failed(.damaged), "\(answer)")
            XCTAssertEqual(recorder.trace(.modelVerify), ["begin", "end"], "\(answer)")
            XCTAssertEqual(recorder.unpaired, [], "\(answer)")
        }
    }

    /// A newer detection while the first verify hashes: both verifies end,
    /// the outrun one included.
    func testAnOutrunVerifyStillEnds() async throws {
        try writePinnedSizes(in: directory)
        let hasher = FakeHasher(held: true)
        let recorder = Recorder()
        let manager = makeManager(hasher, recorder: recorder)
        let atInit = manager.verification
        manager.detectExisting()
        let first = try XCTUnwrap(manager.verification)
        manager.detectExisting()
        let second = try XCTUnwrap(manager.verification)
        hasher.release()
        await atInit?.value
        await first.value
        await second.value

        XCTAssertEqual(recorder.trace(.modelVerify), ["begin", "begin", "end", "end"])
        XCTAssertEqual(recorder.unpaired, [])
        XCTAssertEqual(manager.state, .installed)
    }

    /// Staged files (no network task: `startsNetworkTasks` is off): one
    /// verify per file, each ended.
    func testEachStagedVerifyEnds() async throws {
        try writePinnedSizes(in: directory.appendingPathComponent("staging", isDirectory: true))
        let recorder = Recorder()
        let manager = makeManager(FakeHasher(), recorder: recorder)
        manager.startDownload()
        await drain(manager)
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(recorder.trace(.modelVerify), ["begin", "end", "begin", "end"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// A wrong staged file ends its verify, and the run stops there.
    func testAWrongStagedFileEndsItsVerify() async throws {
        try writePinnedSizes(in: directory.appendingPathComponent("staging", isDirectory: true))
        let recorder = Recorder()
        let manager = makeManager(FakeHasher(.wrong), recorder: recorder)
        manager.startDownload()
        await drain(manager)
        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertEqual(recorder.trace(.modelVerify), ["begin", "end"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    // MARK: - Kokoro warm-up

    private struct Prewarm {
        let rig: PlaybackTestRig
        let neural: PlaybackTestRig.FakeNeuralEngine
        let card: PassthroughSubject<Bool, Never>
        let center: NotificationCenter
        let prewarm: NeuralPrewarm
    }

    /// Michael, the model installed, the scene active, no book loaded.
    private func makePrewarm(_ recorder: Recorder) -> Prewarm {
        let neural = PlaybackTestRig.FakeNeuralEngine()
        let rig = PlaybackTestRig(neural: neural)
        rig.controller.voice = PlaybackTestRig.michael
        let card = PassthroughSubject<Bool, Never>()
        let center = NotificationCenter()
        // The card alone asks, on both hosts: a Mac's launch warm-up would
        // start inside init, before the recorder below is attached.
        let prewarm = NeuralPrewarm(playback: rig.controller, kokoro: neural,
                                    cardVisible: card.eraseToAnyPublisher(),
                                    isModelInstalled: { true }, isLowPowerMode: { false },
                                    sceneActive: true, warmsForLoadedBook: false, warmsAtLaunch: false,
                                    notifications: center)
        prewarm.budgetSignposts = recorder.signposts
        return Prewarm(rig: rig, neural: neural, card: card, center: center, prewarm: prewarm)
    }

    func testWarmUpEndsWhenTheLoadFinishesOrThrows() async {
        for failing in [false, true] {
            let recorder = Recorder()
            let harness = makePrewarm(recorder)
            harness.card.send(true)
            let asked = await waitUntil(2) { harness.neural.warmUpCalls == 1 }
            XCTAssertTrue(asked)
            XCTAssertEqual(recorder.trace(.kokoroWarmup), ["begin"], "open while it loads")
            harness.neural.finishWarmUp(failing: failing)
            let ended = await waitUntil(2) { !harness.prewarm.isWarming }
            XCTAssertTrue(ended)
            XCTAssertEqual(recorder.trace(.kokoroWarmup), ["begin", "end"], failing ? "thrown" : "warm")
            XCTAssertEqual(recorder.unpaired, [])
        }
    }

    /// A memory warning lets the load go; the interval still ends when the
    /// engine's queue hands it back.
    func testWarmUpEndsAfterAMemoryWarningCancelsIt() async {
        let recorder = Recorder()
        let harness = makePrewarm(recorder)
        harness.card.send(true)
        let asked = await waitUntil(2) { harness.neural.warmUpCalls == 1 }
        XCTAssertTrue(asked)
        PlatformLifecycle.post(.memoryWarning, to: harness.center)
        let cancelled = await waitUntil(2) { !harness.prewarm.isWarming }
        XCTAssertTrue(cancelled)
        harness.neural.finishWarmUp()
        let ended = await waitUntil(2) { recorder.trace(.kokoroWarmup).count == 2 }
        XCTAssertTrue(ended)
        XCTAssertEqual(recorder.trace(.kokoroWarmup), ["begin", "end"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    // MARK: - First audio

    private func makeRig(_ recorder: Recorder, neural: PlaybackTestRig.FakeNeuralEngine? = nil) -> PlaybackTestRig {
        let rig = neural.map { PlaybackTestRig(neural: $0) } ?? PlaybackTestRig()
        if neural != nil { rig.controller.voice = PlaybackTestRig.michael }
        rig.controller.budgetSignposts = recorder.signposts
        rig.loadDefault()
        return rig
    }

    /// Play to the first buffer on the started node, then a warm resume.
    func testFirstAudioEndsAtTheFirstBufferAndAtAWarmResume() async throws {
        let recorder = Recorder()
        let rig = makeRig(recorder)
        rig.controller.play()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm"], "open while it buffers")
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "end"])

        rig.controller.pause()
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "end", "begin warm", "end"])
        XCTAssertEqual(recorder.unpaired, [])
        rig.controller.pause(rampsOut: false)
    }

    /// Cold: the neural model loads before the first clip.
    func testFirstAudioIsColdWhenTheNeuralModelLoadsFirst() async throws {
        let recorder = Recorder()
        let rig = makeRig(recorder, neural: PlaybackTestRig.FakeNeuralEngine())
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin cold", "end"])
        XCTAssertEqual(recorder.unpaired, [])
        rig.controller.pause(rampsOut: false)
    }

    /// Paused while it buffers: it gives up there, never running on.
    func testFirstAudioGivesUpWhenPausedBeforeItSounds() {
        let recorder = Recorder()
        let rig = makeRig(recorder)
        rig.controller.play()
        XCTAssertEqual(rig.controller.status, .buffering)
        rig.controller.pause()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "gave up"])
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// A second Play while the first buffers starts the clock again.
    func testASecondPlayWhileBufferingSupersedesTheFirst() async throws {
        let recorder = Recorder()
        let rig = makeRig(recorder)
        rig.controller.play()
        rig.controller.play()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "gave up", "begin warm"])
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(recorder.trace(.firstAudio), ["begin warm", "gave up", "begin warm", "end"])
        XCTAssertEqual(recorder.unpaired, [])
        rig.controller.pause(rampsOut: false)
    }

    func testPlayWithNoBookBeginsNothing() {
        let recorder = Recorder()
        let rig = PlaybackTestRig()
        rig.controller.budgetSignposts = recorder.signposts
        rig.controller.play()
        XCTAssertEqual(recorder.events.count, 0)
    }

    /// A whole start, as Instruments would see it: no sentence of the book
    /// reaches a recorder, which is handed only a budget, a tag and a flag.
    func testNoIntervalCarriesTheBooksWords() async throws {
        let recorder = Recorder()
        let rig = makeRig(recorder)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause(rampsOut: false)
        let words = Set(recorder.trace(.firstAudio).flatMap { $0.split(separator: " ").map(String.init) })
        XCTAssertTrue(words.isSubset(of: ["begin", "end", "gave", "up", "warm", "cold"]), "\(words)")
        let written = recorder.events.map { "\($0.budget.rawValue) \($0.kind)" }.joined(separator: "\n")
        for sentence in rig.content.sentences {
            XCTAssertFalse(written.contains(sentence.text))
            XCTAssertFalse(written.contains("Line\(sentence.id)"))
        }
    }
}
