import SwiftUI
import XCTest
@testable import Aloud

/// Pins the centralized `-uitest-*` launch-argument parsing (UITestHooks).
/// The hooks themselves only exist in DEBUG builds — which is exactly the
/// configuration tests run in — and Release gets no-op accessors, so the
/// gate is structural rather than per-call-site `#if DEBUG` discipline.
final class UITestHooksTests: XCTestCase {

    // MARK: - forcedColorScheme

    func testForcedColorSchemeDark() {
        XCTAssertEqual(UITestHooks.forcedColorScheme(in: ["app", "-uitest-force-dark"]), .dark)
    }

    func testForcedColorSchemeLight() {
        XCTAssertEqual(UITestHooks.forcedColorScheme(in: ["app", "-uitest-force-light"]), .light)
    }

    func testForcedColorSchemeAbsent() {
        XCTAssertNil(UITestHooks.forcedColorScheme(in: ["app"]))
    }

    func testForcedColorSchemeDarkWinsWhenBothPassed() {
        XCTAssertEqual(
            UITestHooks.forcedColorScheme(in: ["-uitest-force-light", "-uitest-force-dark"]),
            .dark)
    }

    // MARK: - seekText

    func testSeekTextReturnsFollowingArgument() {
        XCTAssertEqual(
            UITestHooks.seekText(in: ["app", "-uitest-seek-text", "after the first drink"]),
            "after the first drink")
    }

    func testSeekTextWithoutValueIsNil() {
        // Flag at the end of the argument list must not crash or match.
        XCTAssertNil(UITestHooks.seekText(in: ["app", "-uitest-seek-text"]))
    }

    func testSeekTextAbsentIsNil() {
        XCTAssertNil(UITestHooks.seekText(in: ["app"]))
    }
}
