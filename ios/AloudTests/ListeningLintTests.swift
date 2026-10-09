import XCTest

/// R7/R8 source lints: one app-wide voice and speed (no scopes, no per-book
/// pins applied), and one audio path (no second AVAudioEngine, no
/// VoicePreviewer). Reads the app's sources from the host checkout next to
/// this file; skips when the simulator can't read them.
final class ListeningLintTests: XCTestCase {

    /// ios/Aloud, from ios/AloudTests/ListeningLintTests.swift.
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Aloud", isDirectory: true)

    func testRemovedListeningSymbolsAreGone() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        for symbol in ["PreferenceScope", "pinTarget", "VoicePreviewer",
                       "selectGlobalRate", "selectGlobalVoice", "effectiveRate(",
                       "downloadSizeLabel"] {
            let hits = Self.files(in: sources, containing: symbol)
            XCTAssertTrue(hits.isEmpty, "'\(symbol)' should be gone from ios/Aloud, found in \(hits)")
        }
    }

    /// Every sound the app makes goes through PlaybackController's one muted
    /// graph, so the mute and "only one voice speaks" hold everywhere.
    func testOnlyPlaybackControllerOwnsAnAudioEngine() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        let count = sources.values.reduce(0) { $0 + $1.components(separatedBy: "AVAudioEngine()").count - 1 }
        XCTAssertEqual(count, 1, "Exactly one AVAudioEngine() in ios/Aloud")
        XCTAssertEqual(Self.files(in: sources, containing: "AVAudioEngine()"),
                       ["Playback/PlaybackController.swift"])
    }

    /// The legacy per-book fields are decoded, re-encoded and read once by
    /// the R7 migration; nothing else may apply them.
    func testLegacyPerBookFieldsStayInTheModelAndMigration() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        let allowed: Set<String> = ["Models/LibraryDocument.swift", "App/AppModel.swift"]
        for field in ["preferredRate", "preferredVoiceID"] {
            let outside = Self.files(in: sources, containing: field).filter { !allowed.contains($0) }
            XCTAssertTrue(outside.isEmpty, "'\(field)' should only appear in \(allowed.sorted()), found in \(outside)")
        }
    }

    /// No scoped pickers: Settings and the reader edit the same values.
    func testSettingsHasNoScopeParameters() throws {
        let sources = try Self.swiftSources(in: Self.appRoot.appendingPathComponent("Settings", isDirectory: true))
        let hits = Self.files(in: sources, containing: "scope:")
        XCTAssertTrue(hits.isEmpty, "No 'scope:' in Settings/*.swift, found in \(hits)")
    }

    // MARK: - Source scan

    /// Relative path → contents of every .swift file under `root`.
    private static func swiftSources(in root: URL) throws -> [String: String] {
        // The path form yields paths relative to `root`.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw XCTSkip("Can't read \(root.path) from this test host")
        }
        var sources: [String: String] = [:]
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                throw XCTSkip("Can't read \(relative) from this test host")
            }
            sources[relative] = text
        }
        if sources.isEmpty { throw XCTSkip("No Swift sources readable under \(root.path)") }
        return sources
    }

    private static func files(in sources: [String: String], containing needle: String) -> [String] {
        sources.filter { $0.value.contains(needle) }.map(\.key).sorted()
    }

    // MARK: - Critique round 1

    /// R1-25: the selected voice's bar is Contents' bar: 3 pt accentStrong,
    /// flush and full row height, hidden from VoiceOver; the natural-voice
    /// eyebrow is textMuted, as Contents' eyebrows are.
    func testTheSelectedVoiceBarMatchesContents() throws {
        let path = "Settings/ListeningView.swift"
        let s = try SourceTree.sources(only: [path])
        let view = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(view.range(of: ".overlay(alignment: .leading) {"))
        let bar = view[start.upperBound...].prefix(300)
        XCTAssertTrue(bar.contains(".fill(Theme.accentStrong)"), String(bar))
        XCTAssertTrue(bar.contains(".frame(width: 3)"), String(bar))
        XCTAssertTrue(bar.contains(".accessibilityHidden(true)"), String(bar))
        XCTAssertFalse(bar.contains(".padding(.leading, Theme.Space.xs)"), "the bar is flush: \(bar)")
        XCTAssertFalse(bar.contains(".padding(.vertical, Theme.Space.xs)"), "the bar is full height: \(bar)")
        let header = try XCTUnwrap(view.range(of: "Text(ListeningCopy.naturalVoicesHeader)"))
        let eyebrow = view[header.upperBound...].prefix(300)
        XCTAssertTrue(eyebrow.contains(".foregroundStyle(Theme.textMuted)"), String(eyebrow))
    }

    /// R1-29: the origin column is fixed-width and trailing-aligned, so the
    /// origin sits on the gutter.
    func testTheVoiceOriginSitsOnTheGutter() throws {
        let path = "Settings/ListeningView.swift"
        let s = try SourceTree.sources(only: [path])
        let view = try XCTUnwrap(s[path])
        XCTAssertTrue(view.contains(".frame(width: originColumnWidth, alignment: .trailing)"))
        XCTAssertFalse(view.contains(".frame(width: originColumnWidth, alignment: .leading)"))
        XCTAssertTrue(view.contains("@ScaledMetric(relativeTo: .caption) private var originColumnWidth: CGFloat = 80"))
    }

    /// R1-22: the sheet's list scrolls inside the 60% sheet, with the speed
    /// pinned above it; the lifecycle work stays on the one container, and
    /// the scroll to the selected voice on the inner list.
    func testTheSpeedStaysInViewAboveAScrollingVoiceList() throws {
        let paths = ["Settings/ListeningSheet.swift", "Settings/ListeningView.swift"]
        let s = try SourceTree.sources(only: paths)
        let sheet = try XCTUnwrap(s[paths[0]])
        let view = try XCTUnwrap(s[paths[1]])
        let chrome = try XCTUnwrap(sheet.range(of: ".sheetChrome(Self.detents, selection: $detent)"))
        let interaction = try XCTUnwrap(sheet.range(of: ".presentationContentInteraction(.scrolls)"))
        XCTAssertLessThan(chrome.lowerBound, interaction.lowerBound, "right after the sheet's chrome")
        XCTAssertTrue(sheet.contains("ListeningView(pinsSpeed: true)"))
        XCTAssertTrue(view.contains("struct ListeningSpeedControls: View"))
        XCTAssertTrue(view.contains("struct ListeningVoiceList: View"))
        XCTAssertTrue(view.contains("requested && !dynamicTypeSize.isAccessibilitySize"), "one scroll at AX sizes")
        for once in [".onAppear { resolveSystemVoiceName() }", "playback.releaseNeuralEngineIfUnused()",
                     "proxy.scrollTo(playback.voice.id)",
                     ".publisher(for: AVSpeechEngine.installedVoicesDidChange)"] {
            XCTAssertEqual(view.components(separatedBy: once).count - 1, 1, "'\(once)' runs from one place")
        }
        let page = try XCTUnwrap(view.range(of: "struct ListeningSettingsPage"))
        XCTAssertTrue(view[page.upperBound...].contains(
            "ListeningView(showsInstalledModel: true, selectedChipUnderlay: Theme.surface2, pinsSpeed: true, edgesUnselectedChips: true)"))
        let speed = try XCTUnwrap(view.range(of: "struct ListeningSpeedControls: View"))
        let speedBody = view[speed.upperBound...].prefix(3000)
        XCTAssertTrue(speedBody.contains(".padding(.bottom, Theme.Space.sm)"), "a small gap under the speed")
        // R3-10: the rate reads on the slider's row below AX sizes; the
        // numeral only at AX sizes (a deliberate change from R8).
        let compact = speedBody.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(compact.contains("if Self.showsNumeral(at: dynamicTypeSize) { Text(ListeningFormat.rate(playback.rate)) "
                                       + ".font(Theme.font(.numeral))"),
                      "the rate reads on the slider's row below AX sizes; the numeral only at AX sizes")
        XCTAssertTrue(compact.contains("HStack(spacing: Theme.Space.sm) { speedTrack SpeedReadout(rate: playback.rate) }"),
                      "below AX sizes the readout sits on the track's row")
        XCTAssertTrue(view.contains("nonisolated static func showsNumeral(at size: DynamicTypeSize) -> Bool {\n"
                                    + "        size.isAccessibilitySize\n"), "the numeral's sizes")
        XCTAssertEqual(view.components(separatedBy: ".font(Theme.font(.numeral))").count - 1, 1, "one numeral")
        let readout = try XCTUnwrap(view.range(of: "struct SpeedReadout: View"))
        let readoutBody = view[readout.upperBound...].prefix(1200)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for needle in ["ZStack(alignment: .trailing) { Text(ListeningFormat.rate(Self.widestRate)) "
                       + ".font(Theme.font(.callout)) .monospacedDigit() .hidden()",
                       "Text(ListeningFormat.rate(rate)) .font(Theme.font(.callout)) .monospacedDigit() "
                       + ".foregroundStyle(Theme.text) .numericReadout(rate)",
                       ".accessibilityHidden(true)"] {
            XCTAssertTrue(readoutBody.contains(needle), "the readout: \(needle)")
        }
    }

    /// R2-18: on the Settings page's bgTint an unselected preset's surface2
    /// fill alone doesn't read as a chip, so that page edges every preset
    /// at the border's weight; the selected one keeps its 1.5 pt edge. The
    /// reader's sheet and the Mac keep the default: no edge on the others
    /// except under Increase Contrast (R3-11), where every surface edges
    /// them in the darkened line token.
    func testTheSettingsPageEdgesEverySpeedPreset() throws {
        let paths = ["Settings/ListeningView.swift", "Settings/ListeningSheet.swift"]
        let s = try SourceTree.sources(only: paths)
        let view = try XCTUnwrap(s[paths[0]])
        let sheet = try XCTUnwrap(s[paths[1]])
        XCTAssertTrue(view.contains("edgesUnselectedChips: Bool = false,"), "off by default")
        let preset = try XCTUnwrap(view.range(of: "private func presetButton("))
        let body = view[preset.upperBound...].prefix(2400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(body.contains(".strokeBorder(selected ? Theme.Stroke.selectedColor "
                                    + ": (Self.edgesUnselected(asked: edgesUnselectedChips, contrast: contrast) "
                                    + "? Theme.Stroke.borderColor : Color.clear), "
                                    + "lineWidth: selected ? Theme.Stroke.selectedWidth : Theme.Stroke.borderWidth)"),
                      "no edge on the others except under Increase Contrast: \(body)")
        XCTAssertTrue(view.contains("@Environment(\\.colorSchemeContrast) private var contrast"), "it reads the contrast")
        XCTAssertTrue(view.contains("asked || contrast == .increased"), "asked, or Increase Contrast on any surface")
        XCTAssertTrue(body.contains(".background(selected ? Theme.accentSoft : Theme.surface2,"), "the fills stay")
        XCTAssertEqual(view.components(separatedBy: "edgesUnselectedChips: edgesUnselectedChips)").count - 1, 2,
                       "both speed blocks, pinned and in the list, hear it")
        XCTAssertTrue(sheet.contains("ListeningView(pinsSpeed: true)"), "the reader's sheet keeps the default")
        let mac = try SourceTree.appSources(platforms: [.macOS])
        XCTAssertEqual(SourceTree.files(containing: "edgesUnselectedChips", in: mac), [],
                       "the Mac's call sites keep the default")
    }
}
