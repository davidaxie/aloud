import XCTest

/// R21 source lints: each preference is bound in one view (Text &
/// appearance owns word highlight, the scheme and the text size; Voice &
/// speed owns the speed, the voice and bracketed asides), the removed rows
/// are gone, Settings' home holds no toggle, and no download or settings
/// surface shows a system error's own text.
final class SettingsHomeLintTests: XCTestCase {

    func testAppearancePreferencesAreBoundOnlyInTheAppearanceView() throws {
        let sources = try SourceTree.sources()
        for needle in ["$model.wordHighlight", "appearanceRaw = preference.rawValue", "textSizeStep = target"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), ["Reader/AppearanceSheet.swift"],
                           "'\(needle)' belongs to AppearanceView alone")
        }
    }

    func testListeningPreferencesAreBoundOnlyInTheListeningView() throws {
        let sources = try SourceTree.sources()
        for needle in ["ListeningCopy.readAsidesTitle", "playback.selectRate(", "playback.selectVoice("] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), ["Settings/ListeningView.swift"],
                           "'\(needle)' belongs to ListeningView alone")
        }
    }

    func testRemovedRowsAreGone() throws {
        let sources = try SourceTree.sources()
        for needle in ["Auto-scroll", "$model.autoScroll", "settings.wordHighlight"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), [],
                           "'\(needle)' should be gone from ios/Aloud")
        }
    }

    func testSettingsHomeHoldsNoToggle() throws {
        let path = "Settings/SettingsView.swift"
        let home = try XCTUnwrap(SourceTree.sources(only: [path])[path])
        XCTAssertFalse(home.contains("Toggle"), "Every preference lives on a pushed page")
        XCTAssertFalse(home.contains("PreferenceToggleRow"))
    }

    /// Voice & speed is drawn on the Mac too (Settings, the Voice & Speed
    /// popover), where the main screen's hairline is the wrong display's on
    /// a Mac with a Retina and a 1x screen: its rules are one pixel of the
    /// screen they are drawn on, as every Mac rule is (I015).
    func testListeningRulesFollowTheScreenTheyAreDrawnOn() throws {
        let path = "Settings/ListeningView.swift"
        let listening = try XCTUnwrap(SourceTree.sources(only: [path])[path])
        XCTAssertFalse(listening.contains("Theme.Stroke.hairlineWidth"), "the main screen's hairline")
        XCTAssertTrue(listening.contains(".hairlineHeight()"))
    }

    /// L027: Settings and Licenses give VoiceOver's Headings rotor their
    /// titles, as every other pushed screen does, and each Licenses card's
    /// name is a heading, so the rotor steps card to card.
    func testSettingsAndLicensesOfferHeadings() throws {
        let paths = ["Settings/SettingsView.swift", "Settings/LicensesView.swift"]
        let sources = try SourceTree.sources(only: paths)
        for (path, title) in zip(paths, ["Text(\"Settings\")", "Text(\"Licenses\")"]) {
            let text = try XCTUnwrap(sources[path])
            let start = try XCTUnwrap(text.range(of: "ToolbarItem(placement: .principal) {"), path)
            let item = text[start.upperBound...].prefix { $0 != "}" }
            XCTAssertTrue(item.contains(title), String(item))
            XCTAssertTrue(item.contains(".accessibilityAddTraits(.isHeader)"), "\(path)'s title is a heading")
        }
        let licenses = try XCTUnwrap(sources[paths[1]])
        for name in ["let name = Text(entry.id)", "Text(Self.classicsTitle)"] {
            let start = try XCTUnwrap(licenses.range(of: name), name)
            let modifiers = licenses[start.upperBound...].prefix(250)
            XCTAssertTrue(modifiers.contains(".accessibilityAddTraits(.isHeader)"), "\(name) is a heading")
        }
    }

    func testNoSystemErrorTextInDownloadOrSettings() throws {
        let sources = try SourceTree.sources(only: ["TTS", "Settings"])
        XCTAssertEqual(SourceTree.files(containing: "localizedDescription", in: sources), [],
                       "Failures read from the fixed copy table, never an error's own text")
    }
}
