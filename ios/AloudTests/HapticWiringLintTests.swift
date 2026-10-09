import XCTest

/// Who emits which haptic (TransportHaptics' doc): the subtle press on the
/// buttons the hand presses, the place tick when the hand moves the reading
/// place, exactly one event per control, and nothing unattended. Reads the
/// checkout through SourceTree; skips when the host can't.
final class HapticWiringLintTests: XCTestCase {

    // MARK: - Helpers

    private static func source(_ path: String) throws -> String {
        let s = try SourceTree.sources(only: [path])
        return try XCTUnwrap(s[path], "missing \(path)")
    }

    private static func body(_ signature: String, in source: String) throws -> String {
        try XCTUnwrap(MacKeyCommandLintTests.body(of: signature, in: source), "no '\(signature)'")
    }

    private static func region(_ source: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), "no '\(start)'")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex),
                               "no '\(end)' after '\(start)'")
        return String(source[from.lowerBound..<to.lowerBound])
    }

    /// `haptic` is emitted once in `code`, before `action`.
    private func assertEmitsOnce(_ haptic: String, before action: String, in code: String,
                                 _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let emit = "TransportHaptics.emit(\(haptic))"
        XCTAssertEqual(code.components(separatedBy: "TransportHaptics.emit").count - 1, 1,
                       "\(name): one haptic, never two: \(code)", file: file, line: line)
        guard let emitted = code.range(of: emit) else {
            return XCTFail("\(name) should emit \(haptic): \(code)", file: file, line: line)
        }
        guard let acted = code.range(of: action) else {
            return XCTFail("\(name) should still \(action): \(code)", file: file, line: line)
        }
        XCTAssertLessThan(emitted.lowerBound, acted.lowerBound, "\(name): the haptic comes first",
                          file: file, line: line)
    }

    // MARK: - press

    func testThePlayerBarPresses() throws {
        let bar = try Self.source("Reader/PlayerBarView.swift")
        assertEmitsOnce(".press", before: "playback.skip(seconds: seconds)",
                        in: try Self.body("private func skip(_ seconds: TimeInterval) {", in: bar), "Back/Forward 15")
        assertEmitsOnce(".press", before: "showContents = true",
                        in: try Self.body("private func openContents() {", in: bar), "the chapter line")
        XCTAssertTrue(bar.contains("onOpenContents: openContents,"), "the chapter line opens Contents through it")
        XCTAssertFalse(bar.contains("onOpenContents: { showContents = true }"), "no silent way into Contents")
        let chip = try Self.body("private var listeningChip: some View {", in: bar)
        assertEmitsOnce(".press", before: "showListening = true", in: chip, "the voice chip")
        // Both skips run through skip(_:), so a dimmed Forward 15, whose
        // button never runs its action, stays silent.
        XCTAssertEqual(bar.components(separatedBy: "Button { skip(seconds) }").count - 1, 1, "one skip button builder")
    }

    func testTheReaderPresses() throws {
        let screen = try Self.source("Reader/ReaderScreen.swift")
        let item = try XCTUnwrap(screen.range(of: "ToolbarItem(placement: .topBarTrailing) {"), "Aa's bar item")
        let aa = String(screen[item.upperBound...].prefix(400))
        assertEmitsOnce(".press", before: "showAppearanceSheet.toggle()", in: aa, "Aa")

        let handle = try Self.body("private func handle(_ chip: ReaderChip) {", in: screen)
        XCTAssertEqual(handle.components(separatedBy: "TransportHaptics.emit").count - 1, 3,
                       "one haptic per chip case: \(handle)")
        for (chip, haptic, action) in [(".undoJump:", ".place", "playback.undoJump()"),
                                       (".moreClassics:", ".press", "router.showBookshelfFromReader()"),
                                       (".followVoice, .theEnd:", ".press", "followChipTaps &+= 1")] {
            let start = try XCTUnwrap(handle.range(of: "case \(chip)"), chip)
            let rest = String(handle[start.upperBound...])
            let next = rest.range(of: "case ")?.lowerBound ?? rest.endIndex
            assertEmitsOnce(haptic, before: action, in: String(rest[..<next]), chip)
        }
    }

    func testEverySheetsCloseButtonPresses() throws {
        let chrome = try Self.source("Theme/SheetGrabber.swift")
        assertEmitsOnce(".press", before: "dismiss()",
                        in: try Self.body("private var closeButton: some View {", in: chrome), "SheetHeader's close")
    }

    func testTheSleepChipPresses() throws {
        let chip = try Self.source("Reader/SleepChip.swift")
        assertEmitsOnce(".press", before: "sleepTimer.select(option)",
                        in: try Self.body("private func choose(_ option: SleepTimer.Option) {", in: chip), "a choice")
        let binding = try Self.body("private func selection(_ option: SleepTimer.Option) -> Binding<Bool> {", in: chip)
        XCTAssertTrue(binding.contains("set: { _ in choose(option) }"), binding)
        XCTAssertTrue(chip.contains("choose(.off)"), "Off is a choice too")
        XCTAssertEqual(chip.components(separatedBy: "sleepTimer.select(").count - 1, 1, "every choice goes through choose")
        assertEmitsOnce(".press", before: "sleepTimer.addFifteenMinutes()",
                        in: try Self.body("private var extendButton: some View {", in: chip), "+15 min")
    }

    func testAVoiceRowPressesAndNeverPlays() throws {
        let view = try Self.source("Settings/ListeningView.swift")
        let row = try Self.body("private func voiceRow(_ voice: TtsVoice) -> some View {", in: view)
        assertEmitsOnce(".press", before: "playback.selectVoice(voice)", in: row, "a voice row")
        XCTAssertFalse(row.contains(".play)"), "an audition is no play")
    }

    func testTheLibraryPresses() throws {
        let library = try Self.source("Library/LibraryView.swift")
        assertEmitsOnce(".press", before: "router.showSettings()",
                        in: try Self.body("private var settingsButton: some View {", in: library), "the gear")
        let menu = try Self.body("private var addMenu: some View {", in: library)
        let items = try Self.region(menu, from: "ForEach(LibraryAddMenuItem.allCases", to: "} label: {")
        assertEmitsOnce(".press", before: "choose(item)", in: items, "an add menu item")
        let paste = try Self.region(menu, from: "// The clipboard's text as a book", to: "} label: {")
        assertEmitsOnce(".press", before: "pasteText()", in: paste, "Paste text")

        let empty = try Self.source("Library/EmptyLibraryView.swift")
        let link = try Self.region(empty, from: "private func link(", to: "} label: {")
        assertEmitsOnce(".press", before: "action()", in: link, "More classics and Add a file")
        // The paste control is the system's own: its tap stays the system's.
        let control = try Self.region(empty, from: "private func pasteControl(", to: "/// R3-06")
        XCTAssertFalse(control.contains("TransportHaptics"), control)
    }

    // MARK: - preset, as the pinch

    func testTheAppearanceStepperAndSegmentsTickLikeThePinch() throws {
        let sheet = try Self.source("Reader/AppearanceSheet.swift")
        let step = try Self.region(sheet, from: "private func stepButton(", to: "} label: {")
        assertEmitsOnce(".preset", before: "step(bigger: bigger)", in: step, "a stepper half")
        let segment = try Self.region(sheet, from: "private func appearanceSegment(", to: "} label: {")
        XCTAssertTrue(segment.contains("if !selected { TransportHaptics.emit(.preset) }"),
                      "a segment ticks only when it changes the scheme: \(segment)")
        assertEmitsOnce(".preset", before: "select(preference)", in: segment, "an Appearance segment")
        // VoiceOver's steps on the size readout stay silent.
        let readout = try Self.region(sheet, from: ".accessibilityAdjustableAction { direction in",
                                      to: ".accessibilityIdentifier(\"appearance.textSize.value\")")
        XCTAssertFalse(readout.contains("TransportHaptics"), readout)
        XCTAssertFalse(sheet.contains("TransportHaptics.emit(.press)"), "a setting ticks as the pinch does, never presses")
    }

    // MARK: - place

    /// A sentence tap and a Contents pick each answer once, after the jump
    /// that decides between play and place.
    func testPlaceMovesAnswerOnceAfterTheirJump() throws {
        let screen = try Self.source("Reader/ReaderScreen.swift")
        let tap = try Self.body("static func playFromSentence(_ id: Int, on playback: PlaybackController) {", in: screen)
        XCTAssertTrue(tap.contains("TransportHaptics.emit(playback.userPlayAction != plays ? .play : .place)"), tap)
        XCTAssertEqual(tap.components(separatedBy: "TransportHaptics.emit").count - 1, 1, tap)
        let jump = try XCTUnwrap(tap.range(of: "playback.jump(to: id, origin: .sentence)"), tap)
        let haptic = try XCTUnwrap(tap.range(of: "TransportHaptics.emit("), tap)
        XCTAssertLessThan(jump.lowerBound, haptic.lowerBound, "the jump decides the haptic")

        let bar = try Self.source("Reader/PlayerBarView.swift")
        assertEmitsOnce(".place", before: "playback.undoJump()",
                        in: try Self.body("private func undoJump() {", in: bar), "Undo jump's named action")
    }

    // MARK: - one event per control

    /// Controls that already answered keep only their own event.
    func testControlsThatAlreadyEmitKeepTheirOneEvent() throws {
        let bar = try Self.source("Reader/PlayerBarView.swift")
        let toggle = try Self.body("private func togglePlayback() {", in: bar)
        XCTAssertEqual(toggle.components(separatedBy: "TransportHaptics.emit").count - 1, 1, toggle)
        XCTAssertTrue(toggle.contains("TransportHaptics.emitToggle(isActive: playback.isActive)"), toggle)
        for name in ["private func retry() {", "private func backFiveMinutes() {"] {
            let code = try Self.body(name, in: bar)
            XCTAssertEqual(code.components(separatedBy: "TransportHaptics.emit").count - 1, 1, code)
            XCTAssertTrue(code.contains("TransportHaptics.emit(.play)"), code)
        }
        let scrub = try Self.region(bar, from: ".onEnded { value in", to: "private var touchDownGesture")
        XCTAssertEqual(scrub.components(separatedBy: "TransportHaptics.emit").count - 1, 1, scrub)
        XCTAssertTrue(scrub.contains("TransportHaptics.emit(.scrubRelease)"), scrub)

        let listening = try Self.source("Settings/ListeningView.swift")
        let preset = try Self.region(listening, from: "private func presetButton(", to: "} label: {")
        XCTAssertEqual(preset.components(separatedBy: "TransportHaptics.emit").count - 1, 1, preset)
        XCTAssertTrue(preset.contains("TransportHaptics.emit(.preset)"), preset)
    }

    /// The press and the place come only from the hand's taps in these
    /// files: no unattended path (lock screen, headphones, shortcuts, the
    /// sleep timer's stop, the controller, imports) and nothing in the
    /// Mac's own tree, whose root plays no haptics at all.
    func testPressAndPlaceComeOnlyFromTheHandsTaps() throws {
        let sources = try SourceTree.appSources()
        XCTAssertEqual(SourceTree.files(containing: "TransportHaptics.emit(.press)", in: sources),
                       ["Library/EmptyLibraryView.swift", "Library/LibraryView.swift",
                        "Reader/PlayerBarView.swift", "Reader/ReaderScreen.swift", "Reader/SleepChip.swift",
                        "Settings/ListeningView.swift", "Theme/SheetGrabber.swift"])
        XCTAssertEqual(SourceTree.files(containing: "TransportHaptics.emit(.place)", in: sources),
                       ["Reader/PlayerBarView.swift", "Reader/ReaderScreen.swift"], "Undo jump")
        XCTAssertEqual(SourceTree.files(containing: " ? .play : .place)", in: sources),
                       ["Reader/ContentsSheet.swift", "Reader/ReaderScreen.swift"], "a pick and a sentence tap")
        for path in ["NowPlaying/NowPlayingManager.swift", "Intents/ShortcutActions.swift",
                     "Reader/SleepTimer.swift", "Playback/PlaybackController.swift", "Import/DocumentImporter.swift"] {
            guard let text = sources[path] else { continue }
            // A literal event; the controller's injected hook,
            // `TransportHaptics.emit($0)`, carries only .finished (below).
            XCTAssertFalse(text.contains("TransportHaptics.emit(."), "\(path) is unattended")
        }
        let controller = try XCTUnwrap(sources["Playback/PlaybackController.swift"])
        XCTAssertEqual(controller.components(separatedBy: "emitHaptic(.").count - 1, 1, "only .finished")
        XCTAssertTrue(controller.contains("emitHaptic(.finished)"))

        let mac = sources.filter { $0.key.hasPrefix(SourceTree.macPrefix) }
        XCTAssertEqual(SourceTree.files(containing: "TransportHaptics.emit", in: mac), [],
                       "the Mac's own views emit nothing")
        XCTAssertEqual(SourceTree.files(containing: ".playsTransportHaptics()", in: sources)
                        .filter { $0 != "Playback/TransportHaptics.swift" }, ["App/AloudApp.swift"],
                       "one player, at the iPhone's root; the Mac attaches none")
    }
}
