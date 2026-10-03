import Foundation

/// Where the library lives on disk. (S6)
enum PlatformPaths {
    #if os(iOS)
    /// Documents/Library, where the library has always been, so no install
    /// ever migrates. The store creates it on first use.
    static var libraryRoot: URL {
        documents.appendingPathComponent("Library", isDirectory: true)
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
    #endif
}
