import XCTest
@testable import Aloud

/// P007: one sleep-menu rule for both apps. The choices keep the shared
/// most-recent-first order and never include Off; Off shows apart, and only
/// while a timer is armed, so an unarmed menu never offers a checked Off as
/// a choice. The iPhone's chip used to list Off among the choices always.
@MainActor
final class SleepMenuItemsTests: XCTestCase {

    private static let standard = SleepTimer.standardMinuteChoices

    func testNoOffWhileUnarmed() {
        let options = SleepTimer.orderedOptions(lastUsed: nil, minuteChoices: Self.standard)
        XCTAssertEqual(options.last, .off, "the shared order still ends in Off")
        let items = SleepTimer.menuItems(options: options, isArmed: false)
        XCTAssertFalse(items.showsOff, "nothing is set, so there is nothing to turn off")
        XCTAssertFalse(items.choices.contains(.off))
        XCTAssertNil(items.recent, "nothing picked yet, so nothing sits apart")
        XCTAssertEqual(items.choices, [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter])
    }

    func testOffSitsApartWhileArmed() {
        let options = SleepTimer.orderedOptions(lastUsed: .minutes(30), minuteChoices: Self.standard)
        let armed = SleepTimer.menuItems(options: options, isArmed: true)
        XCTAssertTrue(armed.showsOff)
        XCTAssertFalse(armed.choices.contains(.off), "Off never joins the choices")
        XCTAssertNotEqual(armed.recent, .off)
        XCTAssertEqual(armed.recent, .minutes(30), "the most recent choice stays nearest the chip, apart")
        let unarmed = SleepTimer.menuItems(options: options, isArmed: false)
        XCTAssertEqual(armed.choices, unarmed.choices)
        XCTAssertEqual(armed.recent, unarmed.recent)
    }

    /// R3-17: the durations keep their order, ascending then the chapter's
    /// end, and the last pick sits apart rather than jumping the queue (a
    /// 45-minute pick used to land out of order, below 15). A pick that
    /// already leads the order sits in it, so the menu reads as it does
    /// with nothing picked, and nothing is listed twice.
    func testTheDurationsKeepTheirOrderWithTheLastPickApart() {
        func items(_ lastUsed: SleepTimer.Option?) -> (recent: SleepTimer.Option?, choices: [SleepTimer.Option]) {
            let options = SleepTimer.orderedOptions(lastUsed: lastUsed, minuteChoices: Self.standard)
            let split = SleepTimer.menuItems(options: options, isArmed: false)
            return (split.recent, split.choices)
        }
        let thirty = items(.minutes(30))
        XCTAssertEqual(thirty.recent, .minutes(30))
        XCTAssertEqual(thirty.choices, [.minutes(15), .minutes(45), .minutes(60), .endOfChapter])

        let fortyFive = items(.minutes(45))
        XCTAssertEqual(fortyFive.recent, .minutes(45))
        XCTAssertEqual(fortyFive.choices, [.minutes(15), .minutes(30), .minutes(60), .endOfChapter])

        let chapter = items(.endOfChapter)
        XCTAssertEqual(chapter.recent, .endOfChapter)
        XCTAssertEqual(chapter.choices, [.minutes(15), .minutes(30), .minutes(45), .minutes(60)])

        let natural: [SleepTimer.Option] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]
        for lastUsed in [nil, SleepTimer.Option.minutes(15)] {
            XCTAssertNil(items(lastUsed).recent, "\(String(describing: lastUsed)) leads the order already")
            XCTAssertEqual(items(lastUsed).choices, natural, "\(String(describing: lastUsed))")
        }
        // Every option exactly once, wherever it sits.
        for lastUsed in natural {
            let split = items(lastUsed)
            XCTAssertEqual(Set([split.recent].compactMap { $0 } + split.choices), Set(natural))
            XCTAssertEqual(split.choices.count + (split.recent == nil ? 0 : 1), natural.count)
        }
        // The UI-test hook's one-minute choice leads the order like 15 does.
        let hooked = SleepTimer.menuItems(options: SleepTimer.orderedOptions(lastUsed: .minutes(1),
                                                                              minuteChoices: [1] + Self.standard),
                                          isArmed: true)
        XCTAssertNil(hooked.recent)
        XCTAssertEqual(hooked.choices.first, .minutes(1))
    }

    /// R3-17 on both apps: the iPhone's chip sets the recent pick in its
    /// own section ahead of the titled one (nearest the chip under
    /// `.priority`), the Mac's chip and its Playback ▸ Sleep Timer submenu
    /// set it apart above a separator, and all three read the shared rule.
    /// A source pin: skips where the checkout can't be read (the Mac host).
    func testEveryMenuSetsTheRecentPickApart() throws {
        let s = try SourceTree.sources(only: ["Reader/SleepChip.swift"])
        let chip = try XCTUnwrap(s["Reader/SleepChip.swift"])
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let iPhone = compact(chip)
        let recent = try XCTUnwrap(iPhone.range(of: "if let recent = items.recent { Section { choice(recent) } }"),
                                   "the iPhone's recent section")
        let titled = try XCTUnwrap(iPhone.range(of: "Section(SleepTimer.Copy.section) { ForEach(items.choices, id: \\.self) { option in choice(option) } }"),
                                   "the titled section lists the rest")
        XCTAssertLessThan(recent.lowerBound, titled.lowerBound, "declared first, so drawn nearest the chip")
        XCTAssertTrue(iPhone.contains(".menuOrderNearestFirst()"))
        XCTAssertEqual(iPhone.components(separatedBy: "Toggle(isOn: selection(option))").count - 1, 1,
                       "one item builder for both sections")

        guard SourceTree.exists(SourceTree.macRoot) else { return }
        let macPaths = ["Reader/MacSleepMenu.swift", "Commands/AloudCommands.swift", "Commands/MacCommandActions.swift"]
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: macPaths)
        let menu = compact(try XCTUnwrap(mac["Reader/MacSleepMenu.swift"]))
        XCTAssertTrue(menu.contains("if let recent = items.recent { choice(recent) Divider() } ForEach(items.choices, id: \\.self) { option in choice(option) } if items.showsOff { Divider()"),
                      "the Mac chip: recent, a separator, the rest, a separator, Off")
        let commands = compact(try XCTUnwrap(mac["Commands/AloudCommands.swift"]))
        XCTAssertTrue(commands.contains("let items = snapshot.sleepItems"), "the submenu reads the shared split")
        XCTAssertTrue(commands.contains("if let recent = items.recent { sleepItem(recent) Divider() } ForEach(items.choices, id: \\.self) { option in sleepItem(option) }"),
                      "the submenu: recent, a separator, the rest")
        let actions = compact(try XCTUnwrap(mac["Commands/MacCommandActions.swift"]))
        XCTAssertTrue(actions.contains("SleepTimer.menuItems(options: sleepOptions, isArmed: sleepSelection != .off)"),
                      "the snapshot splits by the shared rule")
    }

    /// The live timer: arming adds Off, disarming takes it away again, and
    /// the armed choice is the one the menu checks.
    func testTheTimersMenuFollowsItsState() {
        let suite = "aloud.tests.sleepMenuItems.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let timer = SleepTimer(defaults: defaults)

        XCTAssertFalse(SleepTimer.menuItems(options: timer.menuOptions, isArmed: timer.isArmed).showsOff)
        timer.select(.minutes(15))
        let armed = SleepTimer.menuItems(options: timer.menuOptions, isArmed: timer.isArmed)
        XCTAssertTrue(armed.showsOff)
        XCTAssertEqual(armed.choices.first, .minutes(15), "the pick is listed first next time")
        XCTAssertEqual(timer.option, .minutes(15), "the checked item")
        timer.select(.off)
        XCTAssertFalse(timer.isArmed)
        XCTAssertFalse(SleepTimer.menuItems(options: timer.menuOptions, isArmed: timer.isArmed).showsOff)
    }
}
