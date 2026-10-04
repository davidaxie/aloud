import Foundation
import os

/// M19's budgets as signposted intervals, for Instruments' os_signpost
/// instrument: subsystem the bundle id, category "Budgets", one interval
/// name per budget. Compiled in every configuration, Release included,
/// because a budget is measured on the build that ships. A signpost is a
/// cheap log write that never blocks and changes nothing it measures, and
/// next to free with nothing recording.
///
/// An interval carries its name and, for first audio, the literal "warm" or
/// "cold" at its begin and "gave up" at an end that never sounded. Never a
/// book's words, a title or a path: a recorder takes only the enums and the
/// flag below, so there is nothing else it could write. Every begin has one
/// end on every path that begins it (`end` on an optional clears it, so a
/// second end is a no-op), and a start that never sounds ends where it
/// gives up rather than running on into the next one.
struct BudgetSignposts: Sendable {

    /// The five budgets (mac PRD M19). The raw value is the interval's name.
    enum Budget: String, CaseIterable, Sendable {
        /// App start to an interactive Library: ≤ 1.0 s, with no model
        /// load and no network.
        case launch
        /// The model's presence check, by `stat`: ≤ 5 ms.
        case modelCheck
        /// SHA-256 of the model files, off the main actor: ≤ 1.5 s.
        case modelVerify
        /// Kokoro's load ahead of a tap: ≤ 2.5 s.
        case kokoroWarmup
        /// Play to the first buffer on the started player node: ≤ 1.0 s
        /// warm, ≤ 3.5 s cold.
        case firstAudio
        /// A dry spell while reading: a sentence ended before the next was
        /// ready, so the listener heard silence. Its budget is none; each
        /// one is a stall M19 counts.
        case catchingUp

        /// The interval's name as Instruments lists it (`rawValue`, as the
        /// static string the signposter takes).
        var name: StaticString {
            switch self {
            case .launch: return "launch"
            case .modelCheck: return "modelCheck"
            case .modelVerify: return "modelVerify"
            case .kokoroWarmup: return "kokoroWarmup"
            case .firstAudio: return "firstAudio"
            case .catchingUp: return "catchingUp"
            }
        }
    }

    /// First audio's start: cold pays the neural model's load first.
    enum Start: String, CaseIterable, Sendable {
        case warm, cold
    }

    /// One begun interval. End it once.
    struct Interval: Sendable {
        let budget: Budget
        let state: OSSignpostIntervalState
    }

    /// The process's signposts, to the unified log.
    static let live = BudgetSignposts(recorder: OSBudgetRecorder())

    /// Where the intervals go. Tests pass a recorder of their own.
    let recorder: any BudgetSignpostRecording

    func begin(_ budget: Budget, _ start: Start? = nil) -> Interval {
        Interval(budget: budget, state: recorder.begin(budget, start: start))
    }

    /// `gaveUp`: the measured thing never happened (a Play paused before
    /// it sounded), so the interval is no reading of its budget.
    func end(_ interval: Interval, gaveUp: Bool = false) {
        recorder.end(interval.budget, interval.state, gaveUp: gaveUp)
    }

    /// Ends `interval` if one is open, and clears it.
    func end(_ interval: inout Interval?, gaveUp: Bool = false) {
        guard let open = interval else { return }
        interval = nil
        end(open, gaveUp: gaveUp)
    }
}

/// Writes the budget intervals. The app's is `OSBudgetRecorder`.
protocol BudgetSignpostRecording: Sendable {
    func begin(_ budget: BudgetSignposts.Budget, start: BudgetSignposts.Start?) -> OSSignpostIntervalState
    func end(_ budget: BudgetSignposts.Budget, _ state: OSSignpostIntervalState, gaveUp: Bool)
}

/// An `OSSignposter` on subsystem the bundle id, category "Budgets". Each
/// interval has its own signpost ID, so two of one name may overlap (a
/// verify that a new detection outran, a warm-up a memory warning let go).
struct OSBudgetRecorder: BudgetSignpostRecording {

    static let category = "Budgets"

    let subsystem: String
    private let signposter: OSSignposter

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.davidxie.Aloud") {
        self.subsystem = subsystem
        signposter = OSSignposter(subsystem: subsystem, category: Self.category)
    }

    func begin(_ budget: BudgetSignposts.Budget, start: BudgetSignposts.Start?) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        // Literal messages only: no value is ever formatted into one.
        switch start {
        case .warm?: return signposter.beginInterval(budget.name, id: id, "warm")
        case .cold?: return signposter.beginInterval(budget.name, id: id, "cold")
        case nil: return signposter.beginInterval(budget.name, id: id)
        }
    }

    func end(_ budget: BudgetSignposts.Budget, _ state: OSSignpostIntervalState, gaveUp: Bool) {
        if gaveUp {
            signposter.endInterval(budget.name, state, "gave up")
        } else {
            signposter.endInterval(budget.name, state)
        }
    }
}
