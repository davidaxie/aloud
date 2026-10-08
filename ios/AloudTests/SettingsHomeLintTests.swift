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

    // MARK: - iPhone parity, batch B5

    /// P034: the Voice & speed sheet opens at a fixed fraction with `.large`
    /// above it, never a detent sized to its content (an 820 pt takeover
    /// with the natural voices, and a first frame that snapped).
    func testTheVoiceSheetIsNotContentSized() throws {
        let path = "Settings/ListeningSheet.swift"
        let sources = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(sources[path])
        XCTAssertTrue(sheet.contains(".sheetChrome(Self.detents, selection: $detent)"))
        XCTAssertTrue(sheet.contains("[openingDetent, .large]"))
        for needle in [".height(", "onContentHeight", "contentHeight", "backgroundInteraction"] {
            XCTAssertFalse(sheet.contains(needle), "'\(needle)': the sheet keeps its scrim and a fixed fraction")
        }
    }

    /// P037: only the Aa sheet leaves the page live behind it, up through
    /// its fitted detent, and so carries its own Done. Contents and Voice
    /// & speed keep the scrim that dismisses on a tap.
    func testOnlyTheAaSheetLeavesThePageLive() throws {
        let paths = ["Reader/AppearanceSheet.swift", "Settings/ListeningSheet.swift", "Reader/ContentsSheet.swift",
                     "Theme/SheetGrabber.swift"]
        let sources = try SourceTree.sources(only: paths)
        let aa = try XCTUnwrap(sources[paths[0]])
        XCTAssertTrue(aa.contains(".sheetChrome(detents, backgroundInteraction: fittedDetent)"))
        XCTAssertTrue(aa.contains("@Environment(\\.dismiss) private var dismiss"))
        XCTAssertTrue(aa.contains(".accessibilityIdentifier(\"appearance.done\")"))
        XCTAssertTrue(aa.contains("Text(AppearanceCopy.done)"))
        for path in paths[1...2] {
            XCTAssertFalse(try XCTUnwrap(sources[path]).contains("backgroundInteraction"), path)
        }
        let chrome = try XCTUnwrap(sources[paths[3]])
        XCTAssertEqual(SourceTree.occurrences(of: "backgroundInteraction: PresentationDetent? = nil", in: [paths[3]: chrome]), 2,
                       "both sheetChrome overloads take it, off by default")
        XCTAssertTrue(chrome.contains("guard let detent else { return .automatic }"), "nil keeps the system's scrim")
    }

    /// P038: each section of the Aa view stacks leading, so its eyebrow
    /// sits on the gutter its control starts at, and Word highlight's title
    /// is body text, as the Voice & speed toggle's is.
    func testTheAppearanceSectionsAlignLeadingWithABodyToggle() throws {
        let path = "Reader/AppearanceSheet.swift"
        let sources = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(sources[path])
        XCTAssertEqual(SourceTree.occurrences(of: "VStack(alignment: .leading, spacing: Theme.Space.sm)", in: [path: sheet]), 3)
        XCTAssertFalse(sheet.contains("VStack(spacing: Theme.Space.sm)"), "a centred section stack")
        XCTAssertFalse(sheet.contains("titleFont:"), "the toggle row's title keeps its body default")
    }

    /// P039: VoiceOver hears the scheme as one segmented control and the
    /// size as one adjustable element, and every size control steps through
    /// the one shared rule (the Mac's included).
    func testTheAppearanceControlsAreOneElementEachOnOneStepRule() throws {
        let path = "Reader/AppearanceSheet.swift"
        let sources = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(sources[path])
        for needle in [".accessibilityRepresentation {", ".pickerStyle(.segmented)",
                       ".accessibilityIdentifier(\"appearance.scheme\")", ".accessibilityAdjustableAction",
                       ".accessibilityLabel(AppearanceCopy.textSize)", "ReaderTextSize.stepped(from: currentStep"] {
            XCTAssertTrue(sheet.contains(needle), "AppearanceView lacks \(needle)")
        }
        XCTAssertFalse(sheet.contains("currentStep + delta"), "a second step rule")
        let mac = try SourceTree.appSources(platforms: [.macOS])
        XCTAssertEqual(SourceTree.files(containing: "steppedTextSize", in: mac), [], "the Mac's own step rule is gone")
        XCTAssertFalse(SourceTree.files(containing: "ReaderTextSize.stepped(", in: mac).isEmpty)
    }

    /// P041: Settings, its two pushed pages and Licenses draw on one ground,
    /// bgTint, bars included; the reader's sheets stay on surface.
    func testTheSettingsStackDrawsOnOneGround() throws {
        let paths = ["Settings/ListeningView.swift", "Reader/AppearanceSheet.swift", "Settings/SettingsView.swift",
                     "Settings/LicensesView.swift", "Theme/SheetGrabber.swift"]
        let sources = try SourceTree.sources(only: paths)
        for (path, page) in zip(paths[0...1], ["struct ListeningSettingsPage", "struct AppearanceSettingsPage"]) {
            let text = try XCTUnwrap(sources[path])
            let start = try XCTUnwrap(text.range(of: page), path)
            let body = text[start.upperBound...]
            XCTAssertTrue(body.contains(".background(Theme.bgTint.ignoresSafeArea())"), "\(page)'s ground")
            XCTAssertTrue(body.contains("round: Theme.bgTint)"), "\(page)'s bar")
            XCTAssertFalse(body.contains("Theme.surface.ignoresSafeArea()"), page)
        }
        for path in paths[2...3] {
            XCTAssertTrue(try XCTUnwrap(sources[path]).contains("Theme.bgTint.ignoresSafeArea()"), path)
        }
        XCTAssertTrue(try XCTUnwrap(sources[paths[4]]).contains(".presentationBackground(Theme.surface)"))
        // On bgTint a selected preset's tint alone is under AA in light.
        XCTAssertTrue(try XCTUnwrap(sources[paths[0]]).contains("selectedChipUnderlay: Theme.surface2"))
    }

    /// P040: the root keeps exactly three rows, the two preference rows say
    /// their values, and the natural voice's line reads from its copy.
    func testTheSettingsRowsShowTheirValues() throws {
        let path = "Settings/SettingsView.swift"
        let sources = try SourceTree.sources(only: [path])
        let home = try XCTUnwrap(sources[path])
        XCTAssertEqual(SourceTree.occurrences(of: "NavigationLink {", in: [path: home]), 3)
        for needle in ["AppearanceCopy.summary(points: textPoints, appearance: appearance)",
                       "Self.appearanceRowSpokenLabel(points: textPoints, appearance: appearance)",
                       "naturalVoice: naturalVoiceLine", "NaturalVoiceCopy.available"] {
            XCTAssertTrue(home.contains(needle), "SettingsView lacks \(needle)")
        }
    }

    /// P035: the System row names its voice on the Voice & speed view's
    /// first frame, so the pick is ranked off the main thread before that
    /// frame: when the reader loads a book, when Settings opens, and again
    /// after the installed voices change.
    func testTheSystemVoiceIsRankedBeforeTheVoiceViewAsks() throws {
        let paths = ["Reader/ReaderScreen.swift", "Settings/SettingsView.swift", "Playback/AVSpeechEngine.swift"]
        let sources = try SourceTree.sources(only: paths)
        let reader = try XCTUnwrap(sources[paths[0]])
        let settings = try XCTUnwrap(sources[paths[1]])
        let engine = try XCTUnwrap(sources[paths[2]])
        XCTAssertEqual(reader.components(separatedBy: "AVSpeechEngine.warmSystemVoice(reading: playback.systemVoiceLanguage)").count - 1,
                       2, "the reader warms on load and on installedVoicesDidChange")
        XCTAssertTrue(reader.contains("publisher(for: AVSpeechEngine.installedVoicesDidChange)"))
        XCTAssertTrue(settings.contains("AVSpeechEngine.warmSystemVoice(reading: playback.systemVoiceLanguage)"))
        XCTAssertTrue(engine.contains("Task.detached(priority: .utility)"), "ranked off the main thread")
    }

    func testNoSystemErrorTextInDownloadOrSettings() throws {
        let sources = try SourceTree.sources(only: ["TTS", "Settings"])
        XCTAssertEqual(SourceTree.files(containing: "localizedDescription", in: sources), [],
                       "Failures read from the fixed copy table, never an error's own text")
    }

    // MARK: - Critique round 1

    /// R1-31: a license name is muted, never the link colour (accent text
    /// is a tap target); each card's name stays its one heading.
    func testLicenseNamesAreNotDrawnInTheLinkColour() throws {
        let path = "Settings/LicensesView.swift"
        let s = try SourceTree.sources(only: [path])
        let licenses = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(licenses.range(of: "let license = Text(entry.license)"))
        let license = licenses[start.upperBound...].prefix(160)
        XCTAssertTrue(license.contains(".foregroundStyle(Theme.textMuted)"), String(license))
        XCTAssertFalse(licenses.contains("Theme.accent"), "no accent-coloured text on Licenses")
        XCTAssertFalse(licenses.contains("NavigationLink"), "a card is no link")
        XCTAssertEqual(licenses.components(separatedBy: ".accessibilityAddTraits(.isHeader)").count - 1, 3,
                       "the title, each card's name and the Classics card: one heading each")
    }

    /// R1-28: the Aa sheet's text size is a two-button stepper: a capsule
    /// split in two equal 44 pt halves, the size readout beside the
    /// eyebrow, still one adjustable element.
    func testTheTextSizeControlIsATwoButtonStepper() throws {
        let path = "Reader/AppearanceSheet.swift"
        let s = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(s[path])
        for needle in ["Text(verbatim: \"A\")", ".frame(maxWidth: .infinity, minHeight: 44)",
                       ".background(Theme.surface2, in: Capsule())", "ViewThatFits(in: .horizontal)",
                       "HStack(alignment: .firstTextBaseline", ".buttonStyle(StepperHalfButtonStyle())",
                       "configuration.isPressed ? Theme.surface : Color.clear",
                       ".accessibilityIdentifier(\"appearance.textSize.value\")",
                       ".accessibilityIdentifier(\"appearance.textSize.smaller\")",
                       ".accessibilityIdentifier(\"appearance.textSize.larger\")"] {
            XCTAssertTrue(sheet.contains(needle), "the stepper lacks \(needle)")
        }
        XCTAssertFalse(sheet.contains("Text(\"Aa\")"), "the separate sample is gone")
        XCTAssertFalse(sheet.contains("scaleEffect"), "the halves never scale on press")
    }
}
