import AppIntents
import Foundation

// R26: continue listening without looking. Two App Intents in the app target
// (no extension, widget or Live Activity), offered to Siri, Spotlight,
// Shortcuts and the Action button through one shortcuts provider.
//
// Every title, phrase and display string here is a compile-time literal: the
// build extracts them into Metadata.appintents, and the system reads them
// from there without launching the app.
//
// Persistent identifiers: users' saved shortcuts and Action-button
// assignments store the intent type names and SleepTimerChoice's raw values.
// Never rename them.
//
// The Mac app compiles the same two intents, offered to Shortcuts, Spotlight
// and Siri on macOS. Both run over the shared AppModel and PlaybackController
// alone: nothing here is UIKit or iPhone-only, and neither brings a window
// forward. An intent is the user asking for the voice, so the system's
// launch for it is not muted as a test launch is (the Mac's Debug build
// stays silent anyway without ALOUD_AUDIBLE=1). Only the run itself plays:
// launching the app for an intent starts nothing on its own. Tests reach the
// runs over a muted rig (`continueListening(with:)`, `setSleepTimer(with:)`)
// and never through the system.

/// Plays the Continue card's book from where the listener left off, without
/// opening the app. An audio intent, so iOS keeps the audio session of a
/// background launch.
struct ContinueListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue listening"
    // Declared as Apple's samples do; the system reads it from the metadata.
    static let description = IntentDescription("Plays the book you were listening to, from where you left off.")
    /// Runs from a locked phone: playing a book reveals nothing private.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        try await Self.continueListening(with: AppModel.shared.shortcutActions)
        // Success is the voice itself: no dialog talks over it.
        return .result()
    }

    /// The run, over the app's parts from perform() or a muted rig's in
    /// tests: throws what Siri or Shortcuts says instead of playing.
    @MainActor
    static func continueListening(with actions: ShortcutActions) async throws {
        if let error = error(for: await actions.continueListening()) { throw error }
    }

    /// What Siri or Shortcuts says instead of playing. A superseded run said
    /// nothing because the listener's own tap already answered it.
    static func error(for outcome: ContinueListeningOutcome) -> ShortcutError? {
        switch outcome {
        case .started, .superseded: return nil
        case .nothingToContinue: return .nothingToContinue
        case .finished(let title): return .finished(title: title)
        case .failed(let title): return .couldNotPlay(title: title)
        }
    }
}

/// Arms the reader's sleep timer with one of R19's options.
struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set sleep timer"
    static let description = IntentDescription("Pauses Aloud after a set time or at the end of the chapter.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// No default: Siri asks rather than guess how long someone wants.
    @Parameter(title: "Sleep timer", requestValueDialog: "Which sleep timer?")
    var choice: SleepTimerChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Set sleep timer to \(\.$choice)")
    }

    init() {}

    init(choice: SleepTimerChoice) {
        self.choice = choice
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = setSleepTimer(with: AppModel.shared.shortcutActions)
        return .result(dialog: "\(text)")
    }

    /// The run, over the app's parts from perform() or a muted rig's in
    /// tests: the spoken confirmation.
    @MainActor
    func setSleepTimer(with actions: ShortcutActions) -> String {
        actions.setSleepTimer(choice)
    }
}

/// R19's options as a shortcut parameter, in the sleep menu's order. The raw
/// values are persisted in users' shortcuts; never rename them.
enum SleepTimerChoice: String, AppEnum {
    case fifteen = "15", thirty = "30", fortyFive = "45", sixty = "60", endOfChapter = "chapter", off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep timer"

    // The menu's own titles (SleepTimer.Option.title), so Siri and the chip
    // use one vocabulary. "End of book" is a synonym: the timer resolves it
    // per book, as the menu does.
    static let caseDisplayRepresentations: [SleepTimerChoice: DisplayRepresentation] = [
        .fifteen: "15 minutes",
        .thirty: "30 minutes",
        .fortyFive: "45 minutes",
        .sixty: DisplayRepresentation(title: "1 hour", synonyms: ["60 minutes", "an hour"]),
        .endOfChapter: DisplayRepresentation(title: "End of chapter",
                                             synonyms: ["the end of the chapter", "End of book", "the end of the book"]),
        .off: "Off",
    ]

    /// The sleep timer option this choice arms.
    var option: SleepTimer.Option {
        switch self {
        case .fifteen: return .minutes(15)
        case .thirty: return .minutes(30)
        case .fortyFive: return .minutes(45)
        case .sixty: return .minutes(60)
        case .endOfChapter: return .endOfChapter
        case .off: return .off
        }
    }
}

struct AloudShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueListeningIntent(),
                    phrases: [
                        "Continue listening in \(.applicationName)",
                        "Keep listening in \(.applicationName)",
                        "Resume \(.applicationName)",
                        "Resume my book in \(.applicationName)",
                    ],
                    shortTitle: "Continue listening",
                    systemImageName: "play.fill")
        AppShortcut(intent: SetSleepTimerIntent(),
                    phrases: [
                        "Set a sleep timer in \(.applicationName)",
                        "Set sleep timer in \(.applicationName)",
                        "Set a sleep timer for \(\.$choice) in \(.applicationName)",
                        "\(.applicationName) sleep timer \(\.$choice)",
                    ],
                    shortTitle: "Set sleep timer",
                    systemImageName: "moon")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

/// Why Continue listening didn't play. Its message is fixed copy, never an
/// underlying error's own text.
enum ShortcutError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case nothingToContinue, finished(title: String), couldNotPlay(title: String)

    var message: String {
        switch self {
        case .nothingToContinue: return ShortcutCopy.nothingToContinue
        case .finished(let title): return ShortcutCopy.finished(title)
        case .couldNotPlay(let title): return ShortcutCopy.couldNotPlay(title)
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Everything the shortcuts say, spelled once. Durations go through
/// ListeningEstimate's spoken phrase, as VoiceOver hears them.
enum ShortcutCopy {
    static let nothingToContinue = "Nothing to continue yet. Open Aloud and choose a book."

    static func finished(_ title: String) -> String {
        "You finished \(title). Open Aloud to listen again."
    }

    static func couldNotPlay(_ title: String) -> String {
        "Couldn’t play \(title). Open Aloud to try again."
    }

    static func sleepTimerSet(_ option: SleepTimer.Option, endsAtChapter: Bool) -> String {
        switch option {
        case .off:
            return "Sleep timer off"
        case .minutes(let minutes):
            return "Sleep timer set for " + ListeningEstimate.spokenPhrase(minutes: minutes)
        case .endOfChapter:
            return endsAtChapter
                ? "Sleep timer set for the end of the chapter"
                : "Sleep timer set for the end of the book"
        }
    }
}
