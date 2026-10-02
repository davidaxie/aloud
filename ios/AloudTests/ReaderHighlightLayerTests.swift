import XCTest
import SwiftUI
import UIKit
@testable import Aloud

/// The follow-along highlight drawn beneath the text (PRD R6): its geometry,
/// and the contract that moving it never edits `textStorage`.
final class ReaderHighlightLayerTests: XCTestCase {

    private typealias Segment = ReaderHighlightLayer.Segment

    // MARK: - Geometry

    func testSentencePathIsOneShapeAcrossLines() {
        let lines = [
            Segment(frame: CGRect(x: 24, y: 100, width: 300, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 24, y: 129, width: 180, height: 29), baseline: 22),
        ]
        let path = ReaderHighlightLayer.sentencePath(lines)
        XCTAssertNotNil(path)
        // Outset 3pt horizontally and 1pt vertically around the union.
        let box = path?.boundingBoxOfPath ?? .null
        XCTAssertEqual(box.minX, 21, accuracy: 0.001)
        XCTAssertEqual(box.minY, 99, accuracy: 0.001)
        XCTAssertEqual(box.width, 306, accuracy: 0.001)
        XCTAssertEqual(box.height, 60, accuracy: 0.001)
        // The gap between lines is filled: the point between the two rows is inside.
        XCTAssertTrue(path?.contains(CGPoint(x: 100, y: 129)) ?? false)
    }

    func testEmptySegmentsDrawNothing() {
        XCTAssertNil(ReaderHighlightLayer.sentencePath([]))
        XCTAssertNil(ReaderHighlightLayer.markPath([], gutterX: 24))
        XCTAssertNil(ReaderHighlightLayer.underlinePath([]))
    }

    func testMarginMarkSitsInTheGutterSpanningTheLines() {
        let lines = [
            Segment(frame: CGRect(x: 40, y: 200, width: 300, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 40, y: 229, width: 300, height: 29), baseline: 22),
        ]
        let box = ReaderHighlightLayer.markPath(lines, gutterX: 40)?.boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 40 - 10 - 2, y: 202, width: 2, height: 54))
    }

    func testUnderlineSitsBelowTheBaselineOfEachPiece() {
        let pieces = [
            Segment(frame: CGRect(x: 250, y: 100, width: 60, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 24, y: 129, width: 30, height: 29), baseline: 22),
        ]
        let box = ReaderHighlightLayer.underlinePath(pieces)?.boundingBoxOfPath
        // First piece: y = 100 + 22 + 2; second ends at 129 + 22 + 2 + 1.5.
        XCTAssertEqual(box?.minY, 124)
        XCTAssertEqual(box?.maxY, 154.5)
    }

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
