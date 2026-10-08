import AppKit
import XCTest
@testable import Aloud

/// The one keyboard table (M11): no two commands share a key, every title
/// comes from the menu copy table, and the plain keys are exactly the five
/// the router owns.
final class MacShortcutsTests: XCTestCase {

    func testNoTwoCommandsShareAKey() {
        var owners: [MacShortcut: MacCommand] = [:]
        for command in MacCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            if let other = owners[shortcut] {
                XCTFail("\(command) and \(other) both use \(shortcut.symbol)")
            }
            owners[shortcut] = command
        }
    }

    func testEveryTitleIsInTheCopyTable() {
        for command in MacCommand.allCases {
            XCTAssertTrue(MacMenuCopy.all.contains(command.title), "\(command): \(command.title)")
            XCTAssertFalse(command.help.isEmpty, "\(command) has no tooltip")
        }
        // The titles the state swaps in, too.
        for title in [MacMenuCopy.pause, MacMenuCopy.tryAgain, MacMenuCopy.listenAgain, MacMenuCopy.previousPage,
                      MacMenuCopy.nextPage, MacMenuCopy.hideContents, MacMenuCopy.endOfChapter,
                      MacMenuCopy.endOfBook, MacMenuCopy.off] {
            XCTAssertTrue(MacMenuCopy.all.contains(title), title)
        }
    }

    /// Menus use title case: every word but the short joining ones starts
    /// upper case. And the Mac's copy never names a phone gesture or device.
    func testMenuTitlesAreTitleCaseAndDeviceNeutral() {
        // "as" too: Mark as Finished, as Apple's title case writes it.
        let lowercaseWords: Set<String> = ["a", "an", "and", "as", "from", "of", "the", "to"]
        for title in MacMenuCopy.all {
            let words = title.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() where index == 0 || !lowercaseWords.contains(word) {
                guard let first = word.first, first.isLetter else { continue }
                XCTAssertTrue(first.isUppercase, "\"\(title)\": \"\(word)\"")
            }
            for banned in ["Import", "tap", "Tap", "swipe", "Swipe", "iPhone", "iOS"] {
                XCTAssertFalse(title.contains(banned), "\"\(title)\" says \(banned)")
            }
        }
    }

    func testPlainKeysAreExactlySpaceArrowsAndBrackets() {
        let plain = Set(MacCommand.allCases.filter(\.isPlainKey).compactMap(\.shortcut?.key))
        XCTAssertEqual(plain, [.space, .leftArrow, .rightArrow, .character("["), .character("]")])
        XCTAssertEqual(Set(MacCommand.allCases.filter(\.isPlainKey)),
                       [.playPause, .back15, .forward15, .slower, .faster])
    }

    /// The keys a text field also edits with go to the field first.
    func testTextKeysDeferToEditableText() {
        XCTAssertEqual(Set(MacCommand.allCases.filter(\.defersToEditableText)),
                       [.playPause, .back15, .forward15, .slower, .faster,
                        .previousChapter, .nextChapter, .deleteBook])
    }

    /// The PRD's keys, spelled as a menu spells them.
    func testTheTableMatchesThePRD() {
        let expected: [MacCommand: String] = [
            .playPause: "Space", .back15: "←", .forward15: "→", .previousChapter: "⌘←", .nextChapter: "⌘→",
            .faster: "]", .slower: "[", .followVoice: "⌘J", .undoJump: "⌘Z", .find: "⌘F",
            .toggleContents: "⌃⌘S", .biggerText: "⌘+", .smallerText: "⌘-", .back: "⌘[",
            .addFromFiles: "⌘O", .addClassic: "⇧⌘O", .deleteBook: "⌘⌫", .settings: "⌘,",
            .closeWindow: "⌘W", .fullScreen: "⌃⌘F", .minimize: "⌘M", .hide: "⌘H", .quit: "⌘Q",
        ]
        for (command, symbol) in expected {
            XCTAssertEqual(command.shortcut?.symbol, symbol, "\(command)")
        }
        XCTAssertNil(MacCommand.voiceAndSpeed.shortcut)
        XCTAssertEqual(MacCommand.back15.help, "Back 15 seconds (←)")
    }

    func testEveryAppCommandHasAMenu() {
        for command in MacCommand.allCases where !command.isSystem {
            XCTAssertTrue(MacMenu.allCases.contains(command.menu), "\(command)")
        }
        XCTAssertEqual(MacCommand.allCases.filter { $0.menu == .playback }.count, 10)
    }

    // MARK: - Speech never stays in a menu

    /// The backstop removes the Speech submenu and any loose Speech item,
    /// and never the menu around them.
    @MainActor
    func testSpeechPrunerTakesOnlySpeech() {
        func item(_ title: String, _ action: String?) -> NSMenuItem {
            NSMenuItem(title: title, action: action.map(NSSelectorFromString), keyEquivalent: "")
        }
        let speech = NSMenu(title: "Speech")
        speech.addItem(item("Start Speaking", "startSpeaking:"))
        speech.addItem(item("Stop Speaking", "stopSpeaking:"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", "copy:"))
        edit.addItem(item("Start Speaking", "startSpeaking:"))   // loose, beside Copy
        let speechParent = item("Speech", nil)
        speechParent.submenu = speech
        edit.addItem(.separator())
        edit.addItem(speechParent)
        let main = NSMenu(title: "Main")
        let editParent = item("Edit", nil)
        editParent.submenu = edit
        main.addItem(editParent)

        MacMenuPruner.removeSpeech(from: main)

        XCTAssertEqual(main.items.map(\.title), ["Edit"], "Edit stays")
        XCTAssertEqual(edit.items.filter { !$0.isSeparatorItem }.map(\.title), ["Copy"])
        XCTAssertTrue(MacMenuPruner.isSpeechOnly(speech))
        XCTAssertFalse(MacMenuPruner.isSpeechOnly(edit))
    }

    // MARK: - Events

    /// Brackets typed with ⌥ or ⇧ (German ⌥5 and ⌥6, Russian ⇧ for [)
    /// still step the speed, by the bracket the key types. A ⌥ key that
    /// types something else, or ⌘ held, is no speed step.
    func testBracketsTypedWithOptionStillStepTheSpeed() {
        XCTAssertEqual(MacCommand.plainCommand(for: Self.typed("[", ignoring: "5", code: 23, flags: .option)), .slower)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.typed("]", ignoring: "6", code: 22, flags: .option)), .faster)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.typed("[", ignoring: "[", code: 50, flags: .shift)), .slower)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.typed("[", ignoring: "5", code: 23, flags: [.option, .shift])),
                       .slower, "French: ⌥⇧5")
        XCTAssertNil(MacCommand.command(for: Self.typed("\u{2018}", ignoring: "]", code: 30, flags: .option)),
                     "US ⌥] types a quote")
        XCTAssertNil(MacCommand.command(for: Self.typed("[", ignoring: "5", code: 23, flags: [.option, .command])))
        XCTAssertNil(MacCommand.command(for: Self.typed("[", ignoring: "5", code: 23, flags: [.option, .control])))
    }

    /// ⌘= is Make Text Bigger's second key, never shown and no one else's.
    func testCommandEqualsIsBiggerTextsSecondKey() {
        XCTAssertEqual(MacCommand.alternateCommand(for: Self.key("=", code: 24, flags: .command)), .biggerText)
        XCTAssertNil(MacCommand.alternateCommand(for: Self.key("=", code: 24)))
        XCTAssertNil(MacCommand.alternateCommand(for: Self.key("+", code: 24, flags: [.command, .shift])))
        let alternates = MacCommand.allCases.compactMap(\.alternateShortcut)
        XCTAssertEqual(alternates, [MacShortcut(key: .character("="), modifiers: .command)])
        for alternate in alternates {
            XCTAssertNil(MacCommand.command(for: alternate), "\(alternate.symbol) is no other command's key")
        }
    }

    func testEventsMapToTheirCommands() {
        XCTAssertEqual(MacCommand.plainCommand(for: Self.key(" ", code: 49)), .playPause)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.arrow(left: true)), .back15)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.arrow(left: false)), .forward15)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.key("[", code: 33)), .slower)
        XCTAssertEqual(MacCommand.plainCommand(for: Self.key("]", code: 30)), .faster)
        XCTAssertEqual(MacCommand.command(for: Self.arrow(left: true, flags: .command)), .previousChapter)
        XCTAssertEqual(MacCommand.command(for: Self.key("o", code: 31, flags: [.command, .shift])), .addClassic)
        XCTAssertEqual(MacCommand.command(for: Self.key("[", code: 33, flags: .command)), .back)
        // Held modifiers make a plain key something else.
        XCTAssertNil(MacCommand.plainCommand(for: Self.arrow(left: true, flags: .command)))
        XCTAssertNil(MacCommand.plainCommand(for: Self.key(" ", code: 49, flags: .shift)))
        XCTAssertNil(MacCommand.command(for: Self.key("q", code: 12)))
    }

    static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [],
                    window: NSWindow? = nil, repeats: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code)!
    }

    /// A key whose layout types `characters` with `flags` held, where the
    /// bare key reads `ignoring` (German ⌥6 types "]", reads "6").
    static func typed(_ characters: String, ignoring: String, code: UInt16,
                      flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!
    }

    /// An arrow carries the function and keypad flags by itself.
    static func arrow(left: Bool, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        let scalar = UnicodeScalar(left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey)!
        return key(String(Character(scalar)), code: left ? 123 : 124,
                   flags: flags.union([.function, .numericPad]), window: window)
    }
}
