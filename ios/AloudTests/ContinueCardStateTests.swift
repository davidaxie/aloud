import SwiftUI
import XCTest
@testable import Aloud

/// R18 and the R11 mirror: what the Continue card shows and says for each
/// state. Pure copy rules, plus one measured layout and one source lint;
/// nothing plays.
final class ContinueCardStateTests: XCTestCase {

    private let hero = UUID()
    private let other = UUID()

    private func book(progress: Double = 0.43, wordCount: Int = 20_842) -> LibraryDocument {
        LibraryDocument(id: hero, title: "Gatsby", fileName: "gatsby.txt",
                        addedAt: Date(timeIntervalSince1970: 0),
                        lastOpenedAt: Date(timeIntervalSince1970: 1_000_000),
                        pageCount: 1, sentenceCount: 100, progressSentence: 43,
                        progressFraction: progress, contentHash: "hash", kind: .text,
                        author: "F. Scott Fitzgerald", wordCount: wordCount)
    }

    private let allStatuses: [PlayerStatus] = [.idle, .buffering, .playing, .paused, .ended, .error]

    // MARK: - Effective status

    func testPendingLoadReadsAsBuffering() {
        for status in allStatuses {
            for loaded in [nil, other, hero] {
                XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: loaded,
                                                                status: status, pendingID: hero),
                               .buffering, "pending wins over \(status), loaded \(String(describing: loaded))")
            }
        }
    }

    func testABookTheControllerDoesNotHoldReadsAsPaused() {
        for status in allStatuses {
            for loaded in [nil, other] {
                for pending in [nil, other] {
                    XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: loaded,
                                                                    status: status, pendingID: pending),
                                   .paused, "\(status) belongs to another book")
                }
            }
        }
    }

    func testTheLoadedBookPassesItsStatusThrough() {
        for status in allStatuses {
            for pending in [nil, other] {
                XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: hero,
                                                                status: status, pendingID: pending),
                               status)
            }
        }
    }

    // MARK: - Label, value, hint

    func testLabelLeadsWithTheEyebrowAndNamesTheAuthor() {
        XCTAssertEqual(ContinueListeningCopy.eyebrow, "Continue listening")
        XCTAssertEqual(ContinueListeningCopy.label(title: "Gatsby", author: "F. Scott Fitzgerald"),
                       "Continue listening, Gatsby, F. Scott Fitzgerald")
        XCTAssertEqual(ContinueListeningCopy.label(title: "Gatsby", author: nil), "Continue listening, Gatsby")
        XCTAssertEqual(ContinueListeningCopy.label(title: "Gatsby", author: ""), "Continue listening, Gatsby")
    }

    func testValueSaysPlayingOnlyWhileSpeaking() {
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: true, spokenSubtitle: "X"), "playing, X")
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: false, spokenSubtitle: "X"), "X")
    }

    func testHint() {
        XCTAssertEqual(ContinueListeningCopy.hint(isSpeaking: false, opensPlaying: true), "Resumes playing")
        XCTAssertEqual(ContinueListeningCopy.hint(isSpeaking: true, opensPlaying: false), "Opens the book")
        XCTAssertEqual(ContinueListeningCopy.hint(isSpeaking: false, opensPlaying: false), "",
                       "a book that opens paused promises nothing")
    }

    /// The loaded book stays the hero when Finished, but it opens paused at
    /// its end (R24), so its hint promises no playback, as its grid card's
    /// doesn't.
    @MainActor
    func testAFinishedHeroDoesNotPromisePlayback() {
        let rig = PlaybackTestRig()
        let finished = PlaybackTestRig.makeDocument(hash: "done", sentences: 12,
                                                    progressSentence: 11, progressFraction: 1.0)
        XCTAssertTrue(finished.isFinished)
        for status in [PlayerStatus.idle, .paused, .ended] {
            let isSpeaking = PlayButtonState(status: status, isPreparingVoice: false,
                                             reduceMotion: false).glyph == .pause
            XCTAssertEqual(ContinueListeningCopy.hint(isSpeaking: isSpeaking,
                                                      opensPlaying: rig.controller.opensPlaying(finished)),
                           "", "a Finished book, \(status)")
            XCTAssertEqual(ContinueListeningCopy.hint(isSpeaking: isSpeaking,
                                                      opensPlaying: rig.controller.opensPlaying(rig.document)),
                           "Resumes playing", "an unfinished book, \(status)")
        }
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Subtitle precedence

    func testStopOutranksTheOfferAndTheEstimate() {
        let document = book()
        for offer in [false, true] {
            for state in [ModelManager.ModelState.notInstalled, .failed(.notEnoughSpace)] {
                XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: .sleepTimer,
                                                              offersNaturalVoice: offer, modelState: state),
                               "Paused by sleep timer")
                XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: document, rate: 1,
                                                                    stop: .headphonesDisconnected,
                                                                    offersNaturalVoice: offer, modelState: state),
                               "Paused, headphones disconnected")
            }
        }
        for reason in StopReason.allCases {
            XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: reason,
                                                          offersNaturalVoice: true, modelState: .notInstalled),
                           reason.text)
            XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: reason,
                                                                offersNaturalVoice: true, modelState: .notInstalled),
                           reason.spokenText)
        }
    }

    func testOfferOutranksTheEstimate() {
        let document = book()
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil, offersNaturalVoice: true,
                                                      modelState: .notInstalled),
                       NaturalVoiceCopy.offer)
        let spoken = ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                          offersNaturalVoice: true, modelState: .notInstalled)
        XCTAssertEqual(spoken, PlaybackCopy.spoken(NaturalVoiceCopy.offer))
        XCTAssertFalse(spoken.contains("·"), "VoiceOver never hears a middle dot: \(spoken)")
    }

    /// R21: a Download with too little space leaves the offer visible, and
    /// the offer row then reads the space line. The card reads it too, never
    /// advertising the download that just failed, and names the voice: with
    /// no Download beside it, a bare "Not enough space" read as if the book
    /// or its storage were the problem.
    func testAfterASpaceFailureTheOfferReadsTheSpaceLine() {
        let document = book()
        let lacking = ModelManager.ModelState.failed(.notEnoughSpace)
        let offers = NaturalVoiceOffer.isVisible(listenedSeconds: NaturalVoiceOffer.listenThreshold, answer: nil,
                                                 deviceSupported: true, modelState: lacking)
        XCTAssertTrue(offers, "the offer stays up after a failed space check")
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil,
                                                      offersNaturalVoice: offers, modelState: lacking),
                       "Natural voice · not enough space · need 705 MB free")
        let spoken = ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                          offersNaturalVoice: offers, modelState: lacking)
        XCTAssertEqual(spoken, "Natural voice, not enough space, need 705 MB free")
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: false, spokenSubtitle: spoken),
                       "Natural voice, not enough space, need 705 MB free")
        XCTAssertEqual(ContinueListeningCopy.label(title: document.title, author: document.author) + ", " + spoken,
                       "Continue listening, Gatsby, F. Scott Fitzgerald, Natural voice, not enough space, need 705 MB free",
                       "VoiceOver hears whose space is short")
        // Download found room: the plain offer again.
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil,
                                                      offersNaturalVoice: true, modelState: .notInstalled),
                       NaturalVoiceCopy.offer)
    }

    /// The chapter line's row and the card read one rule (R5, R21), so the
    /// space line can't drift between them: neither writes it out itself.
    func testTheOfferRowAndTheCardShareOneOfferLine() throws {
        let paths = ["TTS/NaturalVoiceOfferRow.swift", "Library/ContinueListeningCard.swift"]
        let sources = try SourceTree.sources(only: paths)
        for path in paths {
            let code = try XCTUnwrap(sources[path], path).split(separator: "\n")
                .map { $0.components(separatedBy: "//")[0] }
                .joined(separator: "\n")
            XCTAssertTrue(code.contains("NaturalVoiceCopy.offerLine(modelState:"), "\(path) should read the shared line")
            for inline in ["failureLine(", ".notEnoughSpace"] {
                XCTAssertFalse(code.contains(inline), "\(path) writes the offer's rule out itself ('\(inline)')")
            }
        }
    }

    /// The space line is the card's longest subtitle. From xLarge on a 375pt
    /// phone (a 335pt card) it takes three lines beside the cover and the
    /// circle; a two-line limit cut it to "…need 705 MB f…".
    @MainActor
    func testTheSpaceLineWrapsToAThirdLineInsteadOfTruncating() {
        func height(subtitle: String) -> CGFloat {
            let card = ShelfHeroCard(eyebrow: ContinueListeningCopy.eyebrow,
                                     title: "The Strange Case of Dr Jekyll and Mr Hyde", subtitle: subtitle) {
                Color.clear
            } accessory: {
                Color.clear.frame(width: Theme.PlayCircle.compactDiameter, height: Theme.PlayCircle.compactDiameter)
            }
            .environment(\.dynamicTypeSize, .xLarge)
            return UIHostingController(rootView: card)
                .sizeThatFits(in: CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude))
                .height
        }
        let twoLines = height(subtitle: NaturalVoiceCopy.offer)
        let space = height(subtitle: NaturalVoiceCopy.offerLine(modelState: .failed(.notEnoughSpace)))
        XCTAssertGreaterThan(space, twoLines + 8, "the space line should get a third line, not an ellipsis")
    }

    func testEstimateWhenNothingOutranksIt() {
        let document = book()
        // No offer: the estimate, whatever the model is doing.
        for state in [ModelManager.ModelState.notInstalled, .failed(.notEnoughSpace), .installed] {
            XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil,
                                                          offersNaturalVoice: false, modelState: state),
                           "1 hr 12 min left")
            XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                                offersNaturalVoice: false, modelState: state),
                           "1 hour 12 minutes left")
        }
        // Every estimate runs at the app-wide speed.
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 2, stop: nil, offersNaturalVoice: false,
                                                      modelState: .notInstalled),
                       document.listeningSubtitle(rate: 2))
    }

    /// The whole value as VoiceOver reads it while the book speaks (R18).
    func testSpeakingValueReadsPlayingThenTheSubtitle() {
        let spoken = ContinueListeningCopy.spokenSubtitle(for: book(), rate: 1, stop: nil, offersNaturalVoice: false,
                                                          modelState: .notInstalled)
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: true, spokenSubtitle: spoken),
                       "playing, 1 hour 12 minutes left")
    }
}
