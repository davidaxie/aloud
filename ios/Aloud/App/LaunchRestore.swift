import Foundation

/// The reader that was showing when Aloud last closed, kept in one
/// UserDefaults slot as the stack changes, so a relaunch can put the listener
/// back in the book. Injectable so tests never touch the standard defaults.
struct LastReaderStore {

    static let key = "aloud.session.lastReader.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UUID? {
        defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:))
    }

    func save(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}

/// Launch: back where the listener was. A book whose reader was showing when
/// Aloud closed opens again, paused at its saved sentence (with the usual
/// rewind after a rest), so one Play continues; Aloud never starts speaking
/// by itself. From the Library, the Library comes back, with the book on the
/// Continue card, and a Play from the lock screen, headphones or media keys
/// continues it (`NowPlayingManager.onPlayWithNoBook`).
enum LaunchRestore {

    /// The reader on top of `path`, if any.
    static func readerID(in path: [LibraryRouter.Route]) -> UUID? {
        guard case .reader(let id)? = path.last else { return nil }
        return id
    }

    /// The reader to reopen at launch: the last one showing, while its book
    /// is still on the shelf and not Finished (a finished book's place is
    /// its end, and the Library offers what's next).
    static func readerToReopen(lastReaderID: UUID?, documents: [LibraryDocument], enabled: Bool) -> UUID? {
        guard enabled, let id = lastReaderID,
              let document = documents.first(where: { $0.id == id }), !document.isFinished else { return nil }
        return id
    }

    /// Off in hosted unit tests (the iPhone's run inside the real app), and
    /// in UI-test launches unless they ask with `-uitest-restore-session`.
    static var isEnabled: Bool {
        isEnabled(xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                  uiTestLaunch: UITestHooks.isUITestLaunch,
                  restoreRequested: UITestHooks.restoreSession)
    }

    static func isEnabled(xcTestLoaded: Bool, uiTestLaunch: Bool, restoreRequested: Bool) -> Bool {
        if uiTestLaunch { return restoreRequested }
        return !xcTestLoaded
    }
}
