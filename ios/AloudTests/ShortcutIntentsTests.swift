import AppIntents
import XCTest
@testable import Aloud

/// R26: the App Intents' static surface. Titles, choices, error copy and the
/// built metadata are read as values only: no test runs an intent's
/// perform(), and none reads the app's shared model (a system-launched run
/// would not be muted).
@MainActor
final class ShortcutIntentsTests: XCTestCase {

    // MARK: - Sleep timer choices

    /// The choices are the sleep menu's options, in its order, with nothing
    /// used last (the menu's order before any pick).
    func testChoicesAreTheSleepMenuInOrder() {
        XCTAssertEqual(SleepTimerChoice.allCases.map(\.option),
                       SleepTimer.orderedOptions(lastUsed: nil, minuteChoices: SleepTimer.standardMinuteChoices))
    }

    /// Siri and the chip's menu use one vocabulary. The menu's title for End
    /// of chapter in a chaptered book is the choice's title; "End of book" is
    /// its synonym.
    func testChoiceTitlesAreTheMenuTitles() throws {
        for choice in SleepTimerChoice.allCases {
            let representation = try XCTUnwrap(SleepTimerChoice.caseDisplayRepresentations[choice],
                                               "\(choice) has no display representation")
            XCTAssertEqual(String(localized: representation.title), choice.option.title(endsAtChapter: true))
        }
        XCTAssertEqual(SleepTimerChoice.caseDisplayRepresentations.count, SleepTimerChoice.allCases.count)
        XCTAssertEqual(String(localized: SleepTimerChoice.typeDisplayRepresentation.name), "Sleep timer")
    }

    /// The raw values users' shortcuts store are the sleep timer's own
    /// storage values ("off" for Off, which the timer never stores).
    func testRawValuesAreTheTimersStorageValues() {
        for choice in SleepTimerChoice.allCases {
            XCTAssertEqual(choice.option.storageValue ?? "off", choice.rawValue)
        }
        XCTAssertEqual(SleepTimerChoice.allCases.map(\.rawValue), ["15", "30", "45", "60", "chapter", "off"],
                       "persisted in users' shortcuts: never rename")
    }

    // MARK: - Intents

    func testTitlesAndAuthentication() {
        XCTAssertEqual(String(localized: ContinueListeningIntent.title), ContinueListeningCopy.eyebrow,
                       "the shortcut is named like the card it plays")
        XCTAssertEqual(String(localized: SetSleepTimerIntent.title), "Set sleep timer")
        XCTAssertEqual(ContinueListeningIntent.authenticationPolicy, .alwaysAllowed, "runs on a locked phone")
        XCTAssertEqual(SetSleepTimerIntent.authenticationPolicy, .alwaysAllowed, "runs on a locked phone")
    }

    func testExactlyTwoAppShortcuts() {
        XCTAssertEqual(AloudShortcuts.appShortcuts.count, 2)
    }

    // MARK: - Continue listening's errors

    func testOutcomesThatPlayOrDeferSayNothing() {
        XCTAssertNil(ContinueListeningIntent.error(for: .started))
        XCTAssertNil(ContinueListeningIntent.error(for: .superseded), "the listener's own tap answered it")
    }

    func testOutcomesThatDontPlaySayWhyWithFixedCopy() {
        let cases: [(ContinueListeningOutcome, ShortcutError, String)] = [
            (.nothingToContinue, .nothingToContinue, ShortcutCopy.nothingToContinue),
            (.finished(title: "Emma"), .finished(title: "Emma"), ShortcutCopy.finished("Emma")),
            (.failed(title: "Emma"), .couldNotPlay(title: "Emma"), ShortcutCopy.couldNotPlay("Emma")),
        ]
        for (outcome, expected, message) in cases {
            let error = ContinueListeningIntent.error(for: outcome)
            XCTAssertEqual(error, expected, "\(outcome)")
            XCTAssertEqual(error?.message, message)
            XCTAssertEqual(error.map { String(localized: $0.localizedStringResource) }, message,
                           "what Siri says is the message itself")
        }
    }

    func testShortcutCopy() {
        XCTAssertEqual(ShortcutCopy.nothingToContinue, "Nothing to continue yet. Open Aloud and choose a book.")
        XCTAssertEqual(ShortcutCopy.finished("Emma"), "You finished Emma. Open Aloud to listen again.")
        XCTAssertEqual(ShortcutCopy.couldNotPlay("Emma"), "Couldn't play Emma. Open Aloud to try again.")
        XCTAssertEqual(ShortcutCopy.sleepTimerSet(.off, endsAtChapter: true), "Sleep timer off")
        XCTAssertEqual(ShortcutCopy.sleepTimerSet(.minutes(30), endsAtChapter: true), "Sleep timer set for 30 minutes")
        XCTAssertEqual(ShortcutCopy.sleepTimerSet(.minutes(60), endsAtChapter: false), "Sleep timer set for 1 hour")
        XCTAssertEqual(ShortcutCopy.sleepTimerSet(.endOfChapter, endsAtChapter: true),
                       "Sleep timer set for the end of the chapter")
        XCTAssertEqual(ShortcutCopy.sleepTimerSet(.endOfChapter, endsAtChapter: false),
                       "Sleep timer set for the end of the book")
    }

    // MARK: - Built metadata

    /// The build's App Intents metadata lists exactly the two actions, so
    /// Shortcuts shows exactly 2 Aloud actions. Skips where the host app was
    /// built without the extraction step's output.
    func testShortcutsMetadataListsExactlyTwoActions() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("No App Intents metadata at \(url.path)")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "extract.actionsdata is not a JSON object")
        guard let actions = root["actions"] as? [String: Any] else {
            XCTFail("No top-level 'actions' dictionary; top-level keys: \(root.keys.sorted())")
            return
        }
        XCTAssertEqual(actions.keys.sorted(), ["ContinueListeningIntent", "SetSleepTimerIntent"])
    }
}
