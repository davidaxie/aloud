import Foundation

/// Where the library lives on disk. (S6)
enum PlatformPaths {
    #if os(iOS)
    /// Documents/Library, where the library has always been, so no install
    /// ever migrates. The store creates it on first use.
    static var libraryRoot: URL {
        documents.appendingPathComponent("Library", isDirectory: true)
    }

    /// Documents/Inbox, where iOS drops another app's Open-in copies. The
    /// importer clears what an add that never finished left there (F036).
    static var openInInbox: URL? {
        documents.appendingPathComponent("Inbox", isDirectory: true)
    }

    #if DEBUG
    /// Documents: the UI-test fixtures go into its Inbox, the folder iOS
    /// drops Open-in copies into.
    static var fixtureRoot: URL {
        documents
    }
    #endif

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    #elseif os(macOS)
    /// Application Support/Aloud/Library, inside the sandbox container,
    /// out of the listener's way. The store creates it on first use.
    static var libraryRoot: URL {
        appFolder.appendingPathComponent("Library", isDirectory: true)
    }

    /// None: nothing drops copies on a Mac. Its intake stages its own
    /// under Documents/Inbox and sweeps them itself (`MacFileIntake`).
    static var openInInbox: URL? {
        nil
    }

    #if DEBUG
    /// Application Support/Aloud: the UI-test fixtures go into its Inbox,
    /// beside the library, never into the listener's own folders.
    static var fixtureRoot: URL {
        appFolder
    }
    #endif

    private static var appFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aloud", isDirectory: true)
    }
    #endif
}
