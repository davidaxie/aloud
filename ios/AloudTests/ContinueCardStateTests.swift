import SwiftUI
import XCTest
@testable import Aloud

/// R18 and the R11 mirror: what the Continue card shows and says for each
/// state. Pure copy rules, plus one measured layout and one source lint;
/// nothing plays.
final class ContinueCardStateTests: XCTestCase {

    private let hero = UUID()
    private let other = UUID()

    private func book(progress: Double = 0.43, wordCount: Int = 20_842,
                      author: String? = "F. Scott Fitzgerald") -> LibraryDocument {
        LibraryDocument(id: hero, title: "Gatsby", fileName: "gatsby.txt",
                        addedAt: Date(timeIntervalSince1970: 0),
                        lastOpenedAt: Date(timeIntervalSince1970: 1_000_000),
                        pageCount: 1, sentenceCount: 100, progressSentence: 43,
                        progressFraction: progress, contentHash: "hash", kind: .text,
                        author: author, wordCount: wordCount)
    }

    private let allStatuses: [PlayerStatus] = [.idle, .buffering, .playing, .paused, .ended, .error]

    // MARK: - Effective status

    func testPendingLoadReadsAsBuffering() {
        for status in allStatuses {
            for loaded in [nil, other, hero] {
                XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: loaded,
                                                                status: status, pendingID: hero, stop: nil),
                               .buffering, "pending wins over \(status), loaded \(String(describing: loaded))")
            }
        }
    }

    func testABookTheControllerDoesNotHoldReadsAsPaused() {
        for status in allStatuses {
            for loaded in [nil, other] {
                for pending in [nil, other] {
                    XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: loaded,
                                                                    status: status, pendingID: pending, stop: nil),
                                   .paused, "\(status) belongs to another book")
                }
            }
        }
    }

    func testTheLoadedBookPassesItsStatusThrough() {
        for status in allStatuses {
            for pending in [nil, other] {
                XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: hero,
                                                                status: status, pendingID: pending, stop: nil),
                               status)
            }
        }
    }

    /// The card's subtitle says "Playback stopped" for a playback error's
    /// stop; its circle said "Play, paused" beside it once a skip left the
    /// loaded book paused, or a relaunch restored the stop on a book the
    /// controller doesn't hold, while the reader bars and the Mac's
    /// Playback menu said Try again (I002, I014). One rule now for all.
    func testAPlaybackErrorStopKeepsTheCardOnTryAgain() {
        for (loaded, status) in [(hero, PlayerStatus.paused), (hero, .idle), (hero, .error),
                                 (nil, .idle), (other, .playing)] {
            let card = ContinuePlayback.effectiveStatus(documentID: hero, loadedID: loaded, status: status,
                                                        pendingID: nil, stop: .playbackError)
            let state = PlayButtonState(status: card, isPreparingVoice: false, reduceMotion: false)
            XCTAssertEqual(state.glyph, .retry, "\(status), loaded \(String(describing: loaded))")
            XCTAssertEqual(state.label, "Try again")
        }
        // The loaded book as the reader bar shows it: the same status.
        for status in [PlayerStatus.idle, .buffering, .playing, .paused, .ended, .error] {
            for stop in [nil] + StopReason.allCases.map(Optional.some) {
                XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: hero, status: status,
                                                                pendingID: nil, stop: stop),
                               PlayButtonState.circleStatus(status, stop: stop),
                               "\(status), \(String(describing: stop))")
            }
        }
        // Playing again, the end of the book and a circle load keep their own faces.
        for status in [PlayerStatus.playing, .buffering, .ended] {
            XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: hero, status: status,
                                                            pendingID: nil, stop: .playbackError), status)
        }
        XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: nil, status: .idle,
                                                        pendingID: hero, stop: .playbackError), .buffering)
        // Every other stop sits beside a plain Play circle, as before.
        for stop in StopReason.allCases where stop != .playbackError {
            XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: hero, status: .paused,
                                                            pendingID: nil, stop: stop), .paused, "\(stop)")
            XCTAssertEqual(ContinuePlayback.effectiveStatus(documentID: hero, loadedID: nil, status: .idle,
                                                            pendingID: nil, stop: stop), .paused, "\(stop)")
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

    /// The card says "playing" only while the voice is heard, as its circle
    /// does: a circle load, a first clip or a Kokoro warm-up shows the Pause
    /// glyph too, in silence.
    func testOnlyAudiblePlaybackCountsAsSpeaking() {
        func state(_ status: PlayerStatus, preparing: Bool = false) -> PlayButtonState {
            PlayButtonState(status: status, isPreparingVoice: preparing, reduceMotion: false)
        }
        XCTAssertTrue(ContinueListeningCopy.isSpeaking(state(.playing)))
        XCTAssertEqual(state(.buffering).glyph, .pause, "buffering shows Pause")
        XCTAssertFalse(ContinueListeningCopy.isSpeaking(state(.buffering)), "buffering is silent")
        XCTAssertFalse(ContinueListeningCopy.isSpeaking(state(.buffering, preparing: true)))
        for status in [PlayerStatus.idle, .paused, .ended, .error] {
            XCTAssertFalse(ContinueListeningCopy.isSpeaking(state(status)), "\(status)")
        }
        // The hero while its circle loads the book.
        let id = UUID()
        let pending = PlayButtonState(status: ContinuePlayback.effectiveStatus(documentID: id, loadedID: nil,
                                                                               status: .idle, pendingID: id, stop: nil),
                                      isPreparingVoice: false, reduceMotion: false)
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: ContinueListeningCopy.isSpeaking(pending),
                                                   spokenSubtitle: "1 hour left"),
                       "1 hour left", "never \"playing\" while it loads")
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
                       "Natural voice · not enough space · need 707 MB free")
        let spoken = ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                          offersNaturalVoice: offers, modelState: lacking)
        XCTAssertEqual(spoken, "Natural voice, not enough space, need 707 MB free")
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: false, spokenSubtitle: spoken),
                       "Natural voice, not enough space, need 707 MB free")
        XCTAssertEqual(ContinueListeningCopy.label(title: document.title, author: document.author) + ", " + spoken,
                       "Continue listening, Gatsby, F. Scott Fitzgerald, Natural voice, not enough space, need 707 MB free",
                       "VoiceOver hears whose space is short")
        // H043: an earlier attempt staged model.onnx, so the check asked for
        // less, and the card names the check's own figure.
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil, offersNaturalVoice: offers,
                                                      modelState: lacking, spaceNeeded: 380_988_269),
                       "Natural voice · not enough space · need 381 MB free")
        XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil, offersNaturalVoice: offers,
                                                            modelState: lacking, spaceNeeded: 380_988_269),
                       "Natural voice, not enough space, need 381 MB free")
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
    /// circle; a two-line limit cut it to "…need 707 MB f…".
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

    /// Display Zoom on a 6.1-inch phone that offers the natural voice: a
    /// 320pt screen, a 280pt card, and a text column so narrow that the
    /// space line needs four or five lines. A three-line limit cut off the
    /// space it asks for, the part the listener can act on.
    @MainActor
    func testTheSpaceLineIsNeverCutOnANarrowCard() {
        func height(subtitle: String) -> CGFloat {
            let card = ShelfHeroCard(eyebrow: ContinueListeningCopy.eyebrow,
                                     title: "The Strange Case of Dr Jekyll and Mr Hyde", subtitle: subtitle) {
                Color.clear
            } accessory: {
                Color.clear.frame(width: Theme.PlayCircle.compactDiameter, height: Theme.PlayCircle.compactDiameter)
            }
            .environment(\.dynamicTypeSize, .xxxLarge)
            return UIHostingController(rootView: card)
                .sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
                .height
        }
        let threeLines = height(subtitle: "One\nTwo\nSix")
        let space = height(subtitle: NaturalVoiceCopy.offerLine(modelState: .failed(.notEnoughSpace)))
        XCTAssertGreaterThan(space, threeLines + 8, "the space line should wrap on, not end in an ellipsis")
    }

    func testEstimateWhenNothingOutranksIt() {
        let document = book()
        // No offer: the author and the estimate, whatever the model is
        // doing (R1-02), as the featured classic's line reads. VoiceOver
        // hears the estimate alone: the label already ends with the author.
        for state in [ModelManager.ModelState.notInstalled, .failed(.notEnoughSpace), .installed] {
            XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil,
                                                          offersNaturalVoice: false, modelState: state),
                           "F. Scott Fitzgerald \u{00B7} 1 hr 12 min left")
            XCTAssertEqual(ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                                offersNaturalVoice: false, modelState: state),
                           "1 hour 12 minutes left")
        }
        // Every estimate runs at the app-wide speed.
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: document, rate: 2, stop: nil, offersNaturalVoice: false,
                                                      modelState: .notInstalled),
                       "F. Scott Fitzgerald \u{00B7} " + document.listeningSubtitle(rate: 2))
    }

    /// R1-02: the line joins only the parts it has, so it never ends or
    /// starts on a dot: no author, an empty one, an unknown length, both.
    func testTheAuthorLineNeverDangles() {
        func line(_ document: LibraryDocument) -> String {
            ContinueListeningCopy.subtitle(for: document, rate: 1, stop: nil, offersNaturalVoice: false,
                                           modelState: .notInstalled)
        }
        XCTAssertEqual(line(book(author: nil)), "1 hr 12 min left")
        XCTAssertEqual(line(book(author: "")), "1 hr 12 min left")
        XCTAssertEqual(line(book(wordCount: 0)), "F. Scott Fitzgerald", "an unknown length")
        XCTAssertEqual(line(book(wordCount: 0, author: nil)), "", "nothing to say, no stray dot")
        XCTAssertEqual(line(book(progress: 1)), "F. Scott Fitzgerald \u{00B7} Finished")
        let unstarted = book(progress: 0, wordCount: 48_208)
        XCTAssertEqual(line(unstarted), "F. Scott Fitzgerald \u{00B7} " + unstarted.listeningSubtitle(rate: 1))
        for document in [book(author: nil), book(author: ""), book(wordCount: 0), book(wordCount: 0, author: nil)] {
            let text = line(document)
            XCTAssertFalse(text.hasPrefix("\u{00B7}") || text.hasSuffix("\u{00B7}") || text.hasPrefix(" "), text)
        }
        // A stop or the offer still replaces the whole line, author and all.
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: book(), rate: 1, stop: .sleepTimer,
                                                      offersNaturalVoice: false, modelState: .notInstalled),
                       StopReason.sleepTimer.text)
        XCTAssertEqual(ContinueListeningCopy.subtitle(for: book(), rate: 1, stop: nil,
                                                      offersNaturalVoice: true, modelState: .notInstalled),
                       NaturalVoiceCopy.offer)
    }

    /// R1-02: VoiceOver's line keeps to the estimate, never the author,
    /// which the card's label already ends with.
    func testTheSpokenLineLeavesTheAuthorToTheLabel() {
        for document in [book(), book(progress: 1), book(wordCount: 0), book(author: nil)] {
            let spoken = ContinueListeningCopy.spokenSubtitle(for: document, rate: 1, stop: nil,
                                                              offersNaturalVoice: false, modelState: .notInstalled)
            XCTAssertEqual(spoken, document.spokenListeningSubtitle(rate: 1))
            XCTAssertFalse(spoken.contains("Fitzgerald"), spoken)
        }
    }

    /// The whole value as VoiceOver reads it while the book speaks (R18).
    func testSpeakingValueReadsPlayingThenTheSubtitle() {
        let spoken = ContinueListeningCopy.spokenSubtitle(for: book(), rate: 1, stop: nil, offersNaturalVoice: false,
                                                          modelState: .notInstalled)
        XCTAssertEqual(ContinueListeningCopy.value(isSpeaking: true, spokenSubtitle: spoken),
                       "playing, 1 hour 12 minutes left")
    }
}
