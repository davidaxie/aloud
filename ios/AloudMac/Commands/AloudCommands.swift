import SwiftUI

/// The menu bar, built from the one `MacShortcuts` table (M11, mac-ux §4).
/// Pruned to what Aloud does: no New, Open Recent, Save or Print; no
/// Spelling, Substitutions, Transformations or Speech (its first item would
/// speak past the muted engine); no toolbar or sidebar items; no empty
/// Help item. Added: About Aloud's credits, File (Add from Files…, Add a
/// Classic…), Edit (Undo Jump, Delete Book…, Find), View (Contents, text
/// size, Appearance, Back) and Playback, with its Sleep Timer submenu.
///
/// Plain keys (Space, ←, →, [, ]) are never key equivalents here:
/// `MacKeyRouter` dispatches them, so a search field still types them. Their
/// keys show in the tooltips (`MacCommand.help`).
struct AloudCommands: Commands {
    @ObservedObject var state: MacCommandState

    @FocusedValue(\.macFollowVoice) private var followVoice
    @FocusedValue(\.macDeleteBook) private var deleteBook
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppearancePreference.prefKey) private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some Commands {
        // Aloud: the standard panel, with the version and the Licenses
        // page's credits (M20). No key, as Apple's About items have none.
        CommandGroup(replacing: .appInfo) {
            Button(MacAboutCredits.menuTitle) { MacAboutCredits.show() }
        }

        // File, as one group: a commands builder takes ten at most.
        Group {
            CommandGroup(replacing: .newItem) {
                item(.addFromFiles)
                item(.addClassic)
            }
            CommandGroup(replacing: .saveItem) {
                Divider()
                item(.closeWindow)
            }
            CommandGroup(replacing: .printItem) {}
        }

        // Edit: Undo Jump only while its chip shows, ahead of the system's
        // Undo, which keeps the search fields' own undo.
        CommandGroup(before: .undoRedo) {
            if snapshot.isEnabled(.undoJump) {
                item(.undoJump)
                Divider()
            }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.deleteBook)
        }
        CommandGroup(replacing: .textEditing) {
            Menu(MacMenuCopy.findMenu) {
                item(.find)
            }
        }

        // View
        CommandGroup(replacing: .toolbar) {
            item(.toggleContents)
            Divider()
            item(.biggerText)
            item(.smallerText)
            Picker(MacMenuCopy.appearance, selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.label).tag(preference.rawValue)
                }
            }
            Divider()
            item(.back)
            Divider()
        }
        CommandGroup(replacing: .sidebar) {}

        // Help: the system's menu search only.
        CommandGroup(replacing: .help) {}

        CommandMenu(MacMenuCopy.playbackMenu) {
            item(.playPause)
            item(.back15)
            item(.forward15)
            Divider()
            item(.previousChapter)
            item(.nextChapter)
            item(.followVoice)
            Divider()
            item(.faster)
            item(.slower)
            item(.voiceAndSpeed)
            Divider()
            sleepTimerMenu
        }
    }

    private var snapshot: MacMenuSnapshot { state.snapshot }

    /// The actions with what only the menus can see: the focused screen's
    /// offers and the Settings window.
    private var actions: MacCommandActions {
        var actions = state.actions
        actions.followVoice = followVoice
        actions.deleteBook = deleteBook
        let openSettings = openSettings
        actions.openSettings = { openSettings() }
        return actions
    }

    /// One menu item from the table. A ⌘ key becomes its key equivalent; a
    /// plain key never does (the router owns those).
    @ViewBuilder
    private func item(_ command: MacCommand) -> some View {
        let button = Button(title(command)) { actions.perform(command) }
            .disabled(!isEnabled(command))
        if let shortcut = command.shortcut, !shortcut.isPlain {
            button.keyboardShortcut(shortcut.key.keyEquivalent, modifiers: shortcut.modifiers.eventModifiers)
        } else {
            button
        }
    }

    /// The focus-borne commands are known here, not in the snapshot.
    private func isEnabled(_ command: MacCommand) -> Bool {
        switch command {
        case .followVoice: return followVoice != nil
        case .deleteBook: return deleteBook != nil
        default: return snapshot.isEnabled(command)
        }
    }

    private func title(_ command: MacCommand) -> String {
        snapshot.title(command)
    }

    /// Playback ▸ Sleep Timer: the chip's options with a checkmark on the
    /// armed one, then Off while armed. Both bind to the one `SleepTimer`.
    private var sleepTimerMenu: some View {
        Menu(MacMenuCopy.sleepTimer) {
            ForEach(Array(zip(snapshot.sleepOptions, snapshot.sleepTitles)), id: \.0) { option, title in
                Toggle(title, isOn: Binding(
                    get: { snapshot.sleepSelection == option },
                    set: { if $0 { state.actions.selectSleep(option) } }))
            }
            if snapshot.sleepSelection != .off {
                Divider()
                Button(MacMenuCopy.off) { state.actions.selectSleep(.off) }
            }
        }
        .disabled(!snapshot.isEnabled(.sleepTimer))
    }
}

// MARK: - What a focused screen offers the menus

/// The reader's Follow the voice (⌘J), published by the reader while its
/// page can follow (phase 2). With none, the item is disabled.
struct MacFollowVoiceKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Delete Book… (⌘⌫), published by the focused Library card. With none,
/// the item is disabled and ⌘⌫ stays the text fields' own.
struct MacDeleteBookKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var macFollowVoice: MacFollowVoiceKey.Value? {
        get { self[MacFollowVoiceKey.self] }
        set { self[MacFollowVoiceKey.self] = newValue }
    }

    var macDeleteBook: MacDeleteBookKey.Value? {
        get { self[MacDeleteBookKey.self] }
        set { self[MacDeleteBookKey.self] = newValue }
    }
}
