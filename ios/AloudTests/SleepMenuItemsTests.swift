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
        XCTAssertEqual(items.choices, [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter])
    }

    func testOffSitsApartWhileArmed() {
        let options = SleepTimer.orderedOptions(lastUsed: .minutes(30), minuteChoices: Self.standard)
        let armed = SleepTimer.menuItems(options: options, isArmed: true)
        XCTAssertTrue(armed.showsOff)
        XCTAssertFalse(armed.choices.contains(.off), "Off never joins the choices")
        XCTAssertEqual(armed.choices.first, .minutes(30), "the most recent choice stays nearest the chip")
        XCTAssertEqual(armed.choices, SleepTimer.menuItems(options: options, isArmed: false).choices)
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
