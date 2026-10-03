import XCTest

/// R22/R23 source lints for Now Playing: one writer of the system's state,
/// the scrubber on, no hard-coded artist, and lock-screen art drawn by the
/// SwiftUI cover rather than a hand-made UIKit picture. Skips when the host
/// can't read the tree. (The widgets and Live Activity lint lives in
/// ShortcutsLintTests.)
final class NowPlayingLintTests: XCTestCase {

    func testOneOwnerOfTheSystemsNowPlayingState() throws {
        let sources = try SourceTree.sources()
        // The seam's Mac half sets the info center's playback state (macOS's
        // media keys read it); only the manager reaches the seam.
        XCTAssertEqual(SourceTree.files(containing: "MPNowPlayingInfoCenter", in: sources),
                       ["NowPlaying/NowPlayingManager.swift", "Platform/PlatformNowPlaying.swift"],
                       "the info center belongs only to the manager and its seam")
        XCTAssertEqual(SourceTree.files(containing: "MPRemoteCommandCenter", in: sources),
                       ["NowPlaying/NowPlayingManager.swift"], "remote commands belong only to the manager")
        XCTAssertEqual(SourceTree.files(containing: "PlatformNowPlaying.", in: sources),
                       ["NowPlaying/NowPlayingManager.swift"], "only the manager calls the seam")
    }

    func testTheScrubberIsOn() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.occurrences(of: "changePlaybackPositionCommand.isEnabled = true", in: sources), 1)
        XCTAssertEqual(SourceTree.occurrences(of: "changePlaybackPositionCommand.isEnabled = false", in: sources), 0)
    }

    /// The artist is the author (or the snapshot's fallback), never a literal.
    func testTheArtistIsNeverALiteral() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.occurrences(of: "MPMediaItemPropertyArtist: \"", in: sources), 0)
    }

    func testTheArtIsTheSwiftUICover() throws {
        let nowPlaying = try SourceTree.sources(only: ["NowPlaying"])
        XCTAssertEqual(SourceTree.files(containing: "UIGraphicsImageRenderer", in: nowPlaying), [])
        XCTAssertEqual(SourceTree.files(containing: "systemFont(ofSize", in: nowPlaying), [])
        XCTAssertEqual(SourceTree.files(containing: "ImageRenderer", in: nowPlaying),
                       ["NowPlaying/NowPlayingArtwork.swift"])
        XCTAssertEqual(SourceTree.files(containing: "\"ALOUD\"", in: nowPlaying), [])
        let manager = try XCTUnwrap(nowPlaying["NowPlaying/NowPlayingManager.swift"])
        XCTAssertTrue(manager.contains("NowPlayingArtwork.artwork(for:)"), "the manager renders the one cover")
    }
}
