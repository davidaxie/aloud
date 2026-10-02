import XCTest

/// Source lints for the player bar, its chapter line and Contents (R11,
/// R15, R17, R20). Reads the checkout through SourceTree; skips when the
/// test host can't see it.
final class PlayerBarLintTests: XCTestCase {

    /// The busy state is PlayCircleFace's ring (R20), and the scrub preview
    /// never names a sentence number (R17); the scrub is a jump, never a raw
    /// seek, and never a tap-to-teleport (R15, R17).
    func testPlayerBarHasNoSpinnerSentenceNumbersOrRawSeeks() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        for needle in ["ProgressView", "Sentence \\(", "seek(to:", "minimumDistance: 0"] {
            XCTAssertFalse(bar.contains(needle), "PlayerBarView.swift should not contain '\(needle)'")
        }
    }

    /// SwiftUI resets @GestureState before onEnded runs, so a scrub release
    /// that reads `drag` there always falls back to the playhead's chapter:
    /// when the voice crossed a chapter mid-drag, the jump missed the
    /// previewed spot (R17). The release reads the span the drag's frames
    /// froze in the ScrubReleaseSpan latch instead. A gesture can't be
    /// driven from a test, so this pins the source; ScrubReleaseSpan's rules
    /// are in ReaderScrubTests.
    func testScrubReleaseNeverReadsTheResetGestureState() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        let onEnded = try XCTUnwrap(Self.closure(after: ".onEnded", in: bar), "the scrub's onEnded is gone")
        let code = Self.code(onEnded)
        let reads = try NSRegularExpression(pattern: "\\$?\\bdrag\\b")
        XCTAssertNil(reads.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                     "onEnded reads the @GestureState drag, which SwiftUI has already reset:\n\(code)")
        XCTAssertTrue(code.contains("releaseSpan"), "the release should seek in the span its drag froze")
    }

    /// The latch copies the preview's gesture state in the same `.updating`
    /// call that sets it. That state restarts at nil on every drag, so one
    /// the system cancelled (an alert, Siri, a call: no onEnded) can't lend
    /// its span to the next. Keyed by the drag's start x instead, a later
    /// drag from the same point reused the stale chapter (R17).
    func testScrubReleaseFollowsThePreviewsGestureState() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        let updating = try XCTUnwrap(Self.closure(after: ".updating($drag)", in: bar), "the scrub's updating is gone")
        XCTAssertTrue(Self.code(updating).contains("releaseSpan.track(state)"),
                      "each drag frame should hand its gesture state to the release:\n\(updating)")
        XCTAssertFalse(Self.code(bar).contains("startLocation"),
                       "the scrub should never tell drags apart by where they started")
    }

    /// `source` without its line comments.
    private static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    /// The text of the first `{ … }` block after `marker`, braces balanced.
    private static func closure(after marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let open = source[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Contents picks are jumps (R15), so each one offers Undo jump.
    func testContentsJumpsInsteadOfSeeking() throws {
        let sources = try SourceTree.sources(only: ["Reader/ContentsSheet.swift"])
        let contents = try XCTUnwrap(sources["Reader/ContentsSheet.swift"])
        XCTAssertFalse(contents.contains("seek(to:"), "ContentsSheet.swift should jump, not seek")
        XCTAssertTrue(contents.contains("origin: .chapter"))
        XCTAssertTrue(contents.contains("origin: .searchResult"))
    }

    /// R20 removed the UIKit-generator haptics API; TransportHaptics.emit is
    /// the only way to play one.
    func testNoLegacyHapticCalls() throws {
        let sources = try SourceTree.sources()
        for needle in ["TransportHaptics.tap", "selectionChanged"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), [],
                           "'\(needle)' should be gone from ios/Aloud")
        }
    }

    /// An error is one stopped reason among six (R11): the message slot has
    /// no case of its own for it.
    func testReaderMessageHasNoPlaybackErrorCase() throws {
        let sources = try SourceTree.sources()
        let message = try XCTUnwrap(sources["Reader/ReaderMessage.swift"])
        XCTAssertFalse(message.contains("case playbackError"), "ReaderMessage keeps errors in .stopped(_:)")
        XCTAssertEqual(SourceTree.files(containing: "ReaderMessage.playbackError", in: sources), [])
    }
}
