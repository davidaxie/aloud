import XCTest

/// VoiceOver stops on what means something and reads what the eye can't:
/// decorative SF Symbols are hidden (each was an extra "Waveform, image" or
/// "Search, image" stop), and a search result cut short on screen still
/// reads its whole sentence.
final class VoiceOverStopLintTests: XCTestCase {

    /// The text from `start` up to (not including) the first `end` after
    /// it, whitespace collapsed so a reformat doesn't trip the lint.
    private func region(of path: String, from start: String, to end: String) throws -> String {
        let sources = try SourceTree.sources(only: [path])
        let source = try XCTUnwrap(sources[path], "no \(path)")
        let from = try XCTUnwrap(source.range(of: start), "no '\(start)' in \(path)")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex),
                               "no '\(end)' after '\(start)' in \(path)")
        return source[from.lowerBound..<to.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The natural-voice card's tile, in the promo, in-flight and installed
    /// states. "Natural voice installed" says what the hidden checkmark and
    /// tile show.
    func testTheNaturalVoiceTileIsHidden() throws {
        let icon = try region(of: "TTS/ModelDownloadView.swift", from: "private var icon: some View",
                              to: "private func progressBar(")
        XCTAssertTrue(icon.contains("Image(systemName: \"waveform\")"), icon)
        XCTAssertTrue(icon.contains(".accessibilityHidden(true)"), "the waveform tile should be hidden: \(icon)")
    }

    /// The field names itself ("Search this book"), so the glyph before it
    /// adds nothing.
    func testTheSearchFieldGlyphIsHidden() throws {
        let glyph = try region(of: "Reader/ContentsSheet.swift", from: "Image(systemName: \"magnifyingglass\")",
                               to: "TextField(\"Search this book\"")
        XCTAssertTrue(glyph.contains(".accessibilityHidden(true)"), "the magnifying glass should be hidden: \(glyph)")
    }

    /// The row shows a few words before the hit behind an ellipsis, and at
    /// most three or five lines; VoiceOver gets the sentence whole, typeset.
    func testASearchResultReadsItsWholeSentence() throws {
        let label = try region(of: "Reader/ContentsSheet.swift", from: "emphasized(snippet)",
                               to: "Text(location)")
        XCTAssertTrue(label.contains(".accessibilityLabel(ReaderTypography.typeset(match.text))"),
                      "the result should read its whole sentence: \(label)")
    }
}
