import XCTest
@testable import Aloud

/// R16's V4 migration: calm follow replaced the Auto-scroll toggle, so its
/// stored value is removed once, and nothing else is touched.
@MainActor
final class CalmFollowMigrationTests: XCTestCase {

    private typealias Key = AppModel.PrefKey

    func testRemovesTheAutoScrollValueAndNothingElse() {
        let defaults = PlaybackTestRig.freshDefaults()
        defaults.set(false, forKey: Key.autoScroll)
        defaults.set("kokoro:am_michael", forKey: Key.voiceID)
        defaults.set(1.25, forKey: Key.rate)
        defaults.set(false, forKey: Key.skipBrackets)
        defaults.set(true, forKey: Key.wordHighlight)

        AppModel.runCalmFollowMigrationIfNeeded(defaults)

        XCTAssertNil(defaults.object(forKey: Key.autoScroll))
        XCTAssertTrue(defaults.bool(forKey: Key.migratedV4))
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:am_michael")
        XCTAssertEqual(defaults.object(forKey: Key.rate) as? Double, 1.25)
        XCTAssertEqual(defaults.object(forKey: Key.skipBrackets) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: Key.wordHighlight) as? Bool, true)
    }

    func testRunsOnce() {
        let defaults = PlaybackTestRig.freshDefaults()
        defaults.set(false, forKey: Key.autoScroll)
        AppModel.runCalmFollowMigrationIfNeeded(defaults)

        // A value written after the migration is not the migration's business.
        defaults.set(false, forKey: Key.autoScroll)
        AppModel.runCalmFollowMigrationIfNeeded(defaults)
        XCTAssertEqual(defaults.object(forKey: Key.autoScroll) as? Bool, false)
    }

    func testFreshInstallOnlySetsTheFlag() {
        let defaults = PlaybackTestRig.freshDefaults()
        AppModel.runCalmFollowMigrationIfNeeded(defaults)

        XCTAssertTrue(defaults.bool(forKey: Key.migratedV4))
        for key in [Key.autoScroll, Key.voiceID, Key.rate, Key.skipBrackets, Key.wordHighlight] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func testKeys() {
        XCTAssertEqual(Key.migratedV4, "aloud.prefs.migratedV4")
        XCTAssertEqual(Key.autoScroll, "aloud.prefs.v1.autoScroll", "the legacy key the migration removes")
    }
}
