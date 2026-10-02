import XCTest

/// R22/R23 source lints for Now Playing: one writer of the system's state,
/// the scrubber on, no hard-coded artist, and lock-screen art drawn by the
/// SwiftUI cover rather than a hand-made UIKit picture. Skips when the host
/// can't read the tree. (The widgets and Live Activity lint lives in
/// ShortcutsLintTests.)
final class NowPlayingLintTests: XCTestCase {

    func testOneOwnerOfTheSystemsNowPlayingState() throws {
        let sources = try SourceTree.sources()
        for needle in ["MPNowPlayingInfoCenter", "MPRemoteCommandCenter"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), ["NowPlaying/NowPlayingManager.swift"],
                           "'\(needle)' belongs only to the manager")
        }
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
