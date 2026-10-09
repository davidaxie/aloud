import XCTest
@testable import Aloud

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
    /// its fitted detent. Its header's close button (R2-17) closes it, as
    /// on the other reader sheets. Contents and Voice & speed keep the
    /// scrim that dismisses on a tap.
    func testOnlyTheAaSheetLeavesThePageLive() throws {
        let paths = ["Reader/AppearanceSheet.swift", "Settings/ListeningSheet.swift", "Reader/ContentsSheet.swift",
                     "Theme/SheetGrabber.swift"]
        let sources = try SourceTree.sources(only: paths)
        let aa = try XCTUnwrap(sources[paths[0]])
        XCTAssertTrue(aa.contains(".sheetChrome(detents, backgroundInteraction: fittedDetent)"))
        XCTAssertTrue(aa.contains("closeIdentifier: \"appearance.close\")"))
        XCTAssertFalse(aa.contains("appearance.done"), "the lone Done is gone")
        XCTAssertFalse(aa.contains("AppearanceCopy.done"), "the lone Done is gone")
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
    /// is a tap target); each card's name stays its one heading. R2-20:
    /// the only link-coloured text is each card's source, a real Link, and
    /// the only push is its License text row.
    func testLicenseNamesAreNotDrawnInTheLinkColour() throws {
        let path = "Settings/LicensesView.swift"
        let s = try SourceTree.sources(only: [path])
        let licenses = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(licenses.range(of: "let license = Text(entry.license)"))
        let license = licenses[start.upperBound...].prefix(160)
        XCTAssertTrue(license.contains(".foregroundStyle(Theme.textMuted)"), String(license))

        XCTAssertEqual(licenses.components(separatedBy: "Theme.accent").count - 1, 1, "accent on one row only")
        let link = try XCTUnwrap(licenses.range(of: "Link(destination: entry.source) {"))
        let linkRow = licenses[link.upperBound...].prefix(400)
        XCTAssertTrue(linkRow.contains(".foregroundStyle(Theme.accentStrong)"), String(linkRow))
        XCTAssertTrue(linkRow.contains("LicensesCopy.source(entry.source)"), String(linkRow))

        XCTAssertEqual(licenses.components(separatedBy: "NavigationLink").count - 1, 1, "one push per card")
        let push = try XCTUnwrap(licenses.range(of: "NavigationLink {"))
        let pushRow = licenses[push.upperBound...].prefix(400)
        XCTAssertTrue(pushRow.contains("LicenseTextView(entry: entry)"), String(pushRow))
        XCTAssertTrue(pushRow.contains("Text(LicensesCopy.licenseText)"), String(pushRow))
        XCTAssertFalse(pushRow.contains("Theme.accent"), "the push row is no link colour: \(String(pushRow))")

        let page = try XCTUnwrap(licenses.range(of: "struct LicenseTextView"))
        XCTAssertEqual(licenses[..<page.lowerBound].components(separatedBy: ".accessibilityAddTraits(.isHeader)").count - 1, 3,
                       "the title, each card's name and the Classics card: one heading each")
        let textPage = licenses[page.lowerBound...]
        XCTAssertTrue(textPage.contains(".textSelection(.enabled)"), "a license's text is selectable")
        XCTAssertTrue(textPage.contains(".background(Theme.bgTint.ignoresSafeArea())"), "on the page's ground")
        XCTAssertTrue(textPage.contains("Text(entry.id)"), "the component names the page")
        XCTAssertEqual(textPage.components(separatedBy: ".accessibilityAddTraits(.isHeader)").count - 1, 1,
                       "the pushed page's one heading")
    }

    /// R2-20: every component's license text ships in the app bundle (both
    /// apps' Resources/Licenses), and is the license it names.
    func testEveryLicenseTextShipsInTheBundle() throws {
        let expected = ["sherpa-onnx": ["Apache License", "Version 2.0, January 2004"],
                        "ONNX Runtime": ["MIT License", "Copyright (c) Microsoft Corporation",
                                         "Permission is hereby granted"],
                        "Kokoro voice model": ["Apache License", "Version 2.0, January 2004"],
                        "espeak-ng": ["GNU GENERAL PUBLIC LICENSE", "Version 3, 29 June 2007"]]
        XCTAssertEqual(Set(LicensesView.entries.map(\.id)), Set(expected.keys))
        for entry in LicensesView.entries {
            XCTAssertNotNil(entry.textResource, "\(entry.id) ships its license's text")
            let url = try XCTUnwrap(LicensesView.licenseTextURL(for: entry), "\(entry.id)'s text is in Bundle.main")
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in expected[entry.id] ?? [] {
                XCTAssertTrue(text.contains(needle), "\(entry.id): \(needle)")
            }
            XCTAssertFalse(LicenseText.paragraphs(of: text).isEmpty, entry.id)
        }
    }

    /// R2-20: each card links its component's source, over https.
    func testEveryLicenseLinksItsSource() {
        let expected = ["sherpa-onnx": "github.com/k2-fsa/sherpa-onnx",
                        "ONNX Runtime": "github.com/microsoft/onnxruntime",
                        "Kokoro voice model": "huggingface.co/csukuangfj/kokoro-multi-lang-v1_0",
                        "espeak-ng": "github.com/espeak-ng/espeak-ng"]
        for entry in LicensesView.entries {
            XCTAssertEqual(entry.source.scheme, "https", entry.id)
            XCTAssertEqual(LicensesCopy.shortForm(of: entry.source), expected[entry.id], entry.id)
            XCTAssertEqual(LicensesCopy.source(entry.source), "Source \u{00B7} " + (expected[entry.id] ?? ""), entry.id)
        }
        let espeak = LicensesView.entries.first { $0.id == "espeak-ng" }
        XCTAssertTrue(espeak?.detail.contains("github.com/espeak-ng/espeak-ng") == true,
                      "the GPL note names the exact source")
    }

    /// R2-20: the cards' copy is set typographically: a copyright sign, a
    /// curly apostrophe, and a non-breaking hyphen in k2-fsa so it never
    /// splits across a line. The Classics card still closes the page.
    func testTheLicensesCopyIsTypographic() {
        let details = Dictionary(uniqueKeysWithValues: LicensesView.entries.map { ($0.id, $0.detail) })
        XCTAssertTrue(details["sherpa-onnx"]?.contains("by the k2\u{2011}fsa project") == true)
        XCTAssertTrue(details["ONNX Runtime"]?.contains("Copyright \u{00A9} Microsoft Corporation.") == true)
        XCTAssertTrue(details["Kokoro voice model"]?.contains("Aloud\u{2019}s own mixes") == true)
        for (id, detail) in details {
            XCTAssertFalse(detail.contains("(c)"), id)
            XCTAssertFalse(detail.contains("'"), "\(id): a straight apostrophe")
            XCTAssertFalse(detail.contains("k2-fsa"), "\(id): a breakable hyphen in k2-fsa")
        }
        XCTAssertEqual(LicensesView.classicsTitle, "Bundled classics")
    }

    /// R2-20: a license file's hard line breaks reflow into paragraphs.
    func testALicenseTextReflowsIntoParagraphs() {
        XCTAssertEqual(LicenseText.paragraphs(of: "MIT License\n\nPermission is\n  granted,\r\nfree.\n\n\n"),
                       ["MIT License", "Permission is granted, free."])
    }

    /// R2-21: Settings' row separators are drawn at the border's weight
    /// and colour (the system draws them a full point wide), as quiet as
    /// the Licenses cards' edges, never the main screen's strong hairline.
    func testSettingsSeparatorsAreDrawnAtTheBorderWeight() throws {
        let path = "Settings/SettingsView.swift"
        let s = try SourceTree.sources(only: [path])
        let home = try XCTUnwrap(s[path])
        XCTAssertTrue(home.contains(".listRowSeparatorTint(Theme.Stroke.borderColor)"))
        XCTAssertFalse(home.contains(".listRowSeparatorTint(Theme.Stroke.hairlineColor)"))
        XCTAssertTrue(home.contains(".listStyle(.insetGrouped)"), "the list stays")
    }

    /// R1-28, R2-16: the Aa sheet's text size is a stepper in one capsule:
    /// the smaller A, the size readout, the larger A, as the Mac's reads,
    /// each A at least 44 pt wide, the readout still one adjustable element.
    /// The eyebrow above it is a plain section label.
    func testTheTextSizeControlIsATwoButtonStepper() throws {
        let path = "Reader/AppearanceSheet.swift"
        let s = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(s[path])
        for needle in ["ViewThatFits", "firstTextBaseline", "textSizeHeader", "textSizeReadout"] {
            XCTAssertFalse(sheet.contains(needle), "the readout no longer sits beside its eyebrow: \(needle)")
        }
        XCTAssertTrue(sheet.contains("sectionLabel(AppearanceCopy.textSize)\n                textSizeRow"))
        let start = try XCTUnwrap(sheet.range(of: "private var textSizeRow: some View {"))
        let end = try XCTUnwrap(sheet.range(of: "private var stepperHairline: some View {",
                                            range: start.upperBound..<sheet.endIndex))
        let row = String(sheet[start.upperBound..<end.lowerBound])
        let smaller = try XCTUnwrap(row.range(of: "stepButton(bigger: false"), row)
        let readout = try XCTUnwrap(row.range(of: "Text(AppearanceCopy.points(currentPoints))"), row)
        let larger = try XCTUnwrap(row.range(of: "stepButton(bigger: true"), row)
        XCTAssertLessThan(smaller.lowerBound, readout.lowerBound, "the readout follows the smaller A")
        XCTAssertLessThan(readout.lowerBound, larger.lowerBound, "and comes before the larger A")
        XCTAssertEqual(row.components(separatedBy: "{ stepperHairline }").count - 1, 2, "a hairline each side")
        for needle in ["Text(verbatim: \"A\")", ".frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)",
                       ".background(Theme.surface2, in: Capsule())", ".buttonStyle(StepperHalfButtonStyle())",
                       "configuration.isPressed ? Theme.surface : Color.clear",
                       ".accessibilityIdentifier(\"appearance.textSize.value\")",
                       "identifier: \"appearance.textSize.smaller\")",
                       "identifier: \"appearance.textSize.larger\")"] {
            XCTAssertTrue(sheet.contains(needle), "the stepper lacks \(needle)")
        }
        XCTAssertFalse(sheet.contains("Text(\"Aa\")"), "the separate sample is gone")
        XCTAssertFalse(sheet.contains("scaleEffect"), "the halves never scale on press")
    }

    /// R1-28, R2-16: the size readout is one adjustable element over its
    /// whole frame, at least 64 by 44 pt. An element made with
    /// `.accessibilityElement(children: .ignore)` takes the text's own
    /// bounds (31 by 14 pt), so its accessibility shape is set to the
    /// frame: the audit's hit region then reads a full target.
    func testTheTextSizeReadoutIsOneFull44PointElement() throws {
        let path = "Reader/AppearanceSheet.swift"
        let s = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(sheet.range(of: "private var textSizeRow: some View {"))
        let end = try XCTUnwrap(sheet.range(of: "private var stepperHairline: some View {",
                                            range: start.upperBound..<sheet.endIndex))
        let row = sheet[start.upperBound..<end.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(row.contains(".accessibilityIdentifier(\"appearance.textSize.value\")"), row)
        let frame = try XCTUnwrap(row.range(of: ".frame(minWidth: 64, minHeight: 44)"), row)
        let element = try XCTUnwrap(row.range(of: ".accessibilityElement(children: .ignore)"), row)
        XCTAssertLessThan(frame.lowerBound, element.lowerBound, "the element wraps the 44 pt frame")
        let block = row[element.lowerBound...].prefix(600)
        XCTAssertTrue(block.contains(".contentShape(.accessibility, Rectangle())"), "the frame is its shape: \(block)")
        XCTAssertTrue(block.contains(".accessibilityAdjustableAction"), String(block))
        XCTAssertTrue(block.contains(".accessibilityLabel(AppearanceCopy.textSize)"), String(block))
        XCTAssertFalse(row.contains(".padding(.vertical, -"), "no overhang")
        XCTAssertFalse(sheet.contains("readoutLine"), "the overhang's metric is gone")
    }

    /// R2-16: the Aa sheet's title sits close over the first eyebrow; the
    /// Settings page keeps the full step under its bar.
    func testTheAaSheetPadsLessAboveItsFirstEyebrow() throws {
        let path = "Reader/AppearanceSheet.swift"
        let s = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(s[path])
        XCTAssertTrue(sheet.contains("init(topPadding: CGFloat = Theme.Space.md,"))
        XCTAssertTrue(sheet.contains(".padding(.top, topPadding)"))
        XCTAssertFalse(sheet.contains(".padding(.top, Theme.Space.md)"), "no fixed top step")
        XCTAssertTrue(sheet.contains("AppearanceView(topPadding: Theme.Space.xs, onContentHeight:"))
        let page = try XCTUnwrap(sheet.range(of: "struct AppearanceSettingsPage"))
        XCTAssertTrue(sheet[page.upperBound...].contains("AppearanceView()\n"), "the page keeps the default")
        XCTAssertTrue(sheet.contains("@State private var contentHeight: CGFloat = 304"), "the seed follows the layout")
    }

    /// R2-15, R2-17: the three reader sheets share one header: grabber,
    /// centred title and a close button whose frame keeps a 44 pt target
    /// on screen inside a sheet iOS draws scaled by about 0.98. The button
    /// rides an overlay, so the header is no taller than its title, on a
    /// solid circle, never glass; at the accessibility sizes it takes its
    /// own row and VoiceOver meets the heading first.
    func testTheReaderSheetsShareOneHeaderWithAClose() throws {
        let sheets = ["Reader/ContentsSheet.swift": ("ContentsSearch.title", "contents"),
                      "Settings/ListeningSheet.swift": ("ListeningCopy.title", "listening"),
                      "Reader/AppearanceSheet.swift": ("AppearanceCopy.title", "appearance")]
        let chromePath = "Theme/SheetGrabber.swift"
        let sources = try SourceTree.sources(only: Array(sheets.keys) + [chromePath])
        for (path, names) in sheets {
            let (title, prefix) = names
            let text = try XCTUnwrap(sources[path]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(text.contains("SheetHeader(title: \(title), titleIdentifier: \"\(prefix).title\", "
                                        + "closeIdentifier: \"\(prefix).close\""), path)
            XCTAssertFalse(text.contains("SheetGrabber()"), "\(path): the header carries the grabber")
        }
        let chrome = try XCTUnwrap(sources[chromePath])
        XCTAssertTrue(chrome.contains("static let minimum: CGFloat = 46"), "R2-15's headroom over 44 pt")
        let start = try XCTUnwrap(chrome.range(of: "struct SheetHeader: View {"))
        let header = String(chrome[start.upperBound...])
        for needle in [".frame(width: Theme.SheetTarget.minimum, height: Theme.SheetTarget.minimum)",
                       ".contentShape(Circle())", ".background(Theme.surface2, in: Circle())",
                       "Circle().strokeBorder(Theme.Stroke.borderColor", ".foregroundStyle(Theme.textMuted)",
                       "Image(systemName: \"xmark\")", ".accessibilityLabel(SheetCopy.close)",
                       ".accessibilityInputLabels(SheetCopy.closeInputLabels", "Label(SheetCopy.close, systemImage: \"xmark\")",
                       "dismiss()", ".overlay(alignment: .trailing)",
                       ".padding(.horizontal, Theme.Space.sheetGutter + Theme.SheetTarget.minimum)",
                       "if dynamicTypeSize.isAccessibilitySize {", ".accessibilitySortPriority(1)",
                       ".accessibilityAddTraits(.isHeader)", ".fixedSize(horizontal: false, vertical: true)",
                       "static let closeTrailing = Theme.Space.sheetGutter - (Theme.SheetTarget.minimum - circle) / 2"] {
            XCTAssertTrue(header.contains(needle), "SheetHeader lacks \(needle)")
        }
        for glass in ["glassEffect", "Material", "ultraThin"] {
            XCTAssertFalse(header.contains(glass), "the close button stands on a solid circle")
        }
        XCTAssertTrue(chrome.contains("static let close = \"Close\""))
        XCTAssertTrue(chrome.contains("static let closeInputLabels = [\"Close\", \"Done\"]"))
    }
}
