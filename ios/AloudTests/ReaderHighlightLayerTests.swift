import XCTest
import SwiftUI
import UIKit
@testable import Aloud

/// The follow-along highlight's iOS host beneath the text (PRD R6): moving it
/// never edits `textStorage`. Its geometry is `HighlightLayersTests`.
final class ReaderHighlightLayerTests: XCTestCase {

    // MARK: - No textStorage edits

    private final class EditCounter: NSObject, NSTextStorageDelegate {
        var edits = 0
        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            edits += 1
        }
    }

    @MainActor
    func testMovingTheHighlightNeverEditsTextStorage() {
        let sentences = (0..<12).map {
            Sentence(id: $0, text: "Sentence number \($0) is here for the test.", para: $0 / 3, page: 1)
        }
        let paragraphs = (0..<4).map { Paragraph(id: $0, sentenceIDs: ($0 * 3)..<($0 * 3 + 3), page: 1) }
        let content = DocContent(title: "T", pageCount: 1, sentences: sentences,
                                 paragraphs: paragraphs, contentHash: "h")
        let parent = ReaderTextView(content: content, fontSize: 19, activeSentence: 0,
                                    activeWord: -1,
                                    voiceOffscreen: .constant(nil),
                                    textUnderTopBar: .constant(false),
                                    onTapSentence: { _ in })
        let coordinator = ReaderTextView.Coordinator(parent: parent)
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.textView = textView
        coordinator.rebuild(content: content, fontSize: 19)
        textView.layoutIfNeeded()

        let counter = EditCounter()
        textView.textStorage.delegate = counter
        coordinator.setActiveSentence(3, scroll: false)
        coordinator.setActiveWord(0)
        coordinator.setActiveWord(2)
        coordinator.setActiveSentence(7, scroll: false)
        coordinator.setActiveWord(-1)
        XCTAssertEqual(counter.edits, 0, "highlight moves must not edit textStorage")
        XCTAssertEqual(textView.highlightLayer.superview, textView)
    }
}
