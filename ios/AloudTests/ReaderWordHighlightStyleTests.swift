import UIKit
import XCTest
@testable import Aloud

/// Pins the color-only contract of the reader's word tint: with the pref ON
/// the active word differs from body text by `.foregroundColor` alone (the
/// font is the very same object — zero layout impact); with the pref OFF the
/// storage keeps exactly its baseline attributes (body run + sentence pill).
final class ReaderWordHighlightStyleTests: XCTestCase {

    private let bodyFont = UIFont(name: "Georgia", size: 19) ?? .systemFont(ofSize: 19)
    private let bodyColor = UIColor.darkText
    private let accentColor = UIColor.orange
    private let sentenceBg = UIColor.yellow

    /// Body-attributed sentence with a sentence-pill background over all of it,
    /// mirroring what `ReaderTextView.makeAttributedString` + the sentence
    /// highlight produce.
    private func makeStorage() -> (storage: NSMutableAttributedString, word: NSRange) {
        let text = "The quick fox runs."
        let storage = NSMutableAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: bodyColor,
        ])
        storage.addAttribute(.backgroundColor, value: sentenceBg,
                             range: NSRange(location: 0, length: storage.length))
        return (storage, (text as NSString).range(of: "quick"))
    }

    private func attributes(_ storage: NSAttributedString,
                            at location: Int) -> [NSAttributedString.Key: Any] {
        storage.attributes(at: location, effectiveRange: nil)
    }

    // MARK: - Pref ON: color-only

    func testEnabledTintsOnlyColor_FontIsSameObjectAsBody() {
        let (storage, word) = makeStorage()
        let before = attributes(storage, at: word.location)

        let applied = ReaderWordHighlightStyle.apply(
            in: storage, clearing: nil, applying: word, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)
        XCTAssertEqual(applied, word)

        let after = attributes(storage, at: word.location)
        // No new attribute kinds may appear on the word run.
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        // The font is the identical object — not a bold/semibold variant.
        XCTAssertTrue(after[.font] as? UIFont === bodyFont,
                      "word tint must not touch the font")
        // No metric-affecting attributes may ever be introduced.
        XCTAssertNil(after[.kern])
        XCTAssertNil(after[.tracking])
        XCTAssertNil(after[.expansion])
        // Only the color differs; the sentence pill survives.
        XCTAssertEqual(after[.foregroundColor] as? UIColor, accentColor)
        XCTAssertEqual(after[.backgroundColor] as? UIColor, sentenceBg)

        // Text outside the word is untouched.
        let outside = attributes(storage, at: 0)
        XCTAssertEqual(outside[.foregroundColor] as? UIColor, bodyColor)
        XCTAssertTrue(outside[.font] as? UIFont === bodyFont)
    }

    func testAdvancingWordMovesTintAndRestoresBodyColor() {
        let (storage, word) = makeStorage()
        let next = (storage.string as NSString).range(of: "fox")

        _ = ReaderWordHighlightStyle.apply(
            in: storage, clearing: nil, applying: word, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)
        let applied = ReaderWordHighlightStyle.apply(
            in: storage, clearing: word, applying: next, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)
        XCTAssertEqual(applied, next)

        let oldWord = attributes(storage, at: word.location)
        XCTAssertEqual(oldWord[.foregroundColor] as? UIColor, bodyColor)
        XCTAssertTrue(oldWord[.font] as? UIFont === bodyFont)
        let newWord = attributes(storage, at: next.location)
        XCTAssertEqual(newWord[.foregroundColor] as? UIColor, accentColor)
        XCTAssertTrue(newWord[.font] as? UIFont === bodyFont)
    }

    func testClearingRestoresBaselineExactly() {
        let (storage, word) = makeStorage()
        let baseline = storage.copy() as! NSAttributedString

        _ = ReaderWordHighlightStyle.apply(
            in: storage, clearing: nil, applying: word, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)
        let applied = ReaderWordHighlightStyle.apply(
            in: storage, clearing: word, applying: nil, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)

        XCTAssertNil(applied)
        XCTAssertTrue(storage.isEqual(to: baseline),
                      "clearing the tint must restore the exact baseline attributes")
    }

    // MARK: - Pref OFF: inert

    func testDisabledAppliesNothingBeyondSentenceBackground() {
        let (storage, word) = makeStorage()
        let baseline = storage.copy() as! NSAttributedString

        let applied = ReaderWordHighlightStyle.apply(
            in: storage, clearing: nil, applying: word, enabled: false,
            bodyColor: bodyColor, accentColor: accentColor)

        XCTAssertNil(applied, "no range may be tinted while the pref is off")
        XCTAssertTrue(storage.isEqual(to: baseline),
                      "with the pref off the storage keeps only body attributes + sentence bg")
    }

    func testDisableWhileTintedClearsTheTint() {
        let (storage, word) = makeStorage()
        let baseline = storage.copy() as! NSAttributedString

        _ = ReaderWordHighlightStyle.apply(
            in: storage, clearing: nil, applying: word, enabled: true,
            bodyColor: bodyColor, accentColor: accentColor)
        // Pref flips off mid-word: the coordinator clears with enabled: false.
        let applied = ReaderWordHighlightStyle.apply(
            in: storage, clearing: word, applying: word, enabled: false,
            bodyColor: bodyColor, accentColor: accentColor)

        XCTAssertNil(applied)
        XCTAssertTrue(storage.isEqual(to: baseline))
    }
}
