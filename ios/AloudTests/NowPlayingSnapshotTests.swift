import MediaPlayer
import XCTest
@testable import Aloud

/// R23's rules on the pure snapshot: artist, chapter album, a 1x timeline
/// over the scrub span whose remaining time matches the app's, and scrubs
/// that land on sentence starts. No controller, no system info center.
@MainActor
final class NowPlayingSnapshotTests: XCTestCase {

    private static let title = "Rig"
    /// Three chapters of three sentences. nonisolated: a default argument
    /// reads it.
    private nonisolated static let chapterPages = [0, 0, 0, 1, 1, 1, 2, 2, 2]

    private func makeNavigation(pages: [Int]? = NowPlayingSnapshotTests.chapterPages, count: Int = 9,
                                wordsPerSentence: Int = 4, kind: DocKind = .text) -> ReaderNavigation {
        let content = PlaybackTestRig.makeContent(hash: "np-snapshot", count: count,
                                                  wordsPerSentence: wordsPerSentence, pages: pages)
        return ReaderNavigation(content: content, kind: kind)
    }

    private func snapshot(_ navigation: ReaderNavigation?, at sentence: Int, author: String? = nil,
                          status: PlayerStatus = .paused, rate: Double = 1,
                          sentenceElapsed: TimeInterval = 0) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: Self.title, author: author, navigation: navigation, sentence: sentence,
                           status: status, rate: rate, sentenceElapsed: sentenceElapsed)
    }

    /// 1x seconds for `words` at the shared 165 wpm.
    private func seconds(_ words: Int) -> TimeInterval { Double(words) / 165 * 60 }

    // MARK: - Artist

    func testTheArtistIsTheAuthorOrAloud() {
        XCTAssertEqual(NowPlayingSnapshot.fallbackArtist, "Aloud")
        XCTAssertEqual(NowPlayingSnapshot.artist(for: "Jane Austen"), "Jane Austen")
        XCTAssertEqual(NowPlayingSnapshot.artist(for: "  Jane Austen \n"), "Jane Austen")
        for blank in [nil, "", "   "] as [String?] {
            XCTAssertEqual(NowPlayingSnapshot.artist(for: blank), "Aloud", "\(String(describing: blank))")
        }
        XCTAssertEqual(snapshot(nil, at: 0, author: "Jane Austen").artist, "Jane Austen")
        XCTAssertEqual(snapshot(nil, at: 0).nowPlayingInfo[MPMediaItemPropertyArtist] as? String, "Aloud")
    }

    // MARK: - Album

    func testTheAlbumIsTheChapterLinesTitle() {
        let navigation = makeNavigation()
        for sentence in 0..<9 {
            let expected = navigation.positionLine(at: sentence, rate: 1, documentTitle: Self.title).title
            let shot = snapshot(navigation, at: sentence)
            XCTAssertEqual(shot.album, expected, "sentence \(sentence)")
            XCTAssertEqual(shot.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] as? String, expected)
        }
    }

    func testNoAlbumWithoutChapters() {
        for (name, navigation) in [("chapterless text", makeNavigation(pages: nil)),
                                   ("a PDF", makeNavigation(kind: .pdf))] {
            for sentence in [0, 4, 8] {
                let shot = snapshot(navigation, at: sentence)
                XCTAssertNil(shot.album, "\(name) at \(sentence)")
                XCTAssertNil(shot.nowPlayingInfo[MPMediaItemPropertyAlbumTitle], "\(name) at \(sentence)")
            }
        }
    }

    /// Chapters of 2, 5 and 2 sentences, so the duration changes too.
    func testAlbumSpanAndDurationSwitchAtTheChapterBoundary() throws {
        let navigation = makeNavigation(pages: [0, 0, 1, 1, 1, 1, 1, 2, 2])
        let before = snapshot(navigation, at: 1)
        let after = snapshot(navigation, at: 2)
        XCTAssertNotEqual(before.album, after.album)
        XCTAssertEqual(before.span, 0...1)
        XCTAssertEqual(after.span, 2...6)
        XCTAssertEqual(try XCTUnwrap(before.duration), seconds(8), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(after.duration), seconds(20), accuracy: 1e-9)
    }

    // MARK: - Timeline

    func testTheTimelineIsTheScrubSpanAtOneX() throws {
        for (name, navigation) in [("chaptered text", makeNavigation()), ("chapterless text", makeNavigation(pages: nil)),
                                   ("a PDF", makeNavigation(kind: .pdf))] {
            for sentence in 0..<9 {
                let label = "\(name) at \(sentence)"
                let shot = snapshot(navigation, at: sentence, rate: 1.5)
                let span = navigation.scrubSpan(at: sentence)
                XCTAssertEqual(shot.span, span, label)
                let words = navigation.wordsRemaining(from: span.lowerBound, through: span.upperBound)
                XCTAssertEqual(try XCTUnwrap(shot.duration, label), seconds(words), accuracy: 1e-9, label)
                XCTAssertEqual(try XCTUnwrap(shot.elapsed, label),
                               navigation.secondsIntoSpan(of: sentence, in: span, rate: 1), accuracy: 1e-9, label)
                XCTAssertNotNil(shot.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration], label)
                XCTAssertNotNil(shot.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime], label)
            }
        }
        // PDFs and chapterless text span the whole document.
        XCTAssertEqual(snapshot(makeNavigation(pages: nil), at: 4).span, 0...8)
        XCTAssertEqual(snapshot(makeNavigation(kind: .pdf), at: 4).span, 0...8)
    }

    /// Real seconds heard become media seconds at the rate: 2 s at 1.5x
    /// is 3 s of 1x time.
    func testTheHeardPartAddsAtTheRate() throws {
        let navigation = makeNavigation(wordsPerSentence: 10)   // 3.6 s a sentence at 1x
        let span = navigation.scrubSpan(at: 4)
        let start = navigation.secondsIntoSpan(of: 4, in: span, rate: 1)
        let shot = snapshot(navigation, at: 4, status: .playing, rate: 1.5, sentenceElapsed: 2)
        XCTAssertEqual(try XCTUnwrap(shot.elapsed), start + 3, accuracy: 1e-9)
    }

    func testAHugeHeardPartStopsAtTheNextSentence() throws {
        let navigation = makeNavigation(wordsPerSentence: 10)
        let span = navigation.scrubSpan(at: 4)
        let nextStart = navigation.secondsIntoSpan(of: 5, in: span, rate: 1)
        for heard in [1_000.0, 1e9, .infinity, .nan] {
            let shot = snapshot(navigation, at: 4, status: .playing, rate: 2, sentenceElapsed: heard)
            let elapsed = try XCTUnwrap(shot.elapsed, "\(heard)")
            XCTAssertLessThanOrEqual(elapsed, nextStart + 1e-9, "\(heard)")
            XCTAssertGreaterThanOrEqual(elapsed, navigation.secondsIntoSpan(of: 4, in: span, rate: 1), "\(heard)")
        }
        // The last sentence of the span stops at the span's end.
        let last = snapshot(navigation, at: 5, status: .playing, rate: 1, sentenceElapsed: 1_000)
        XCTAssertEqual(try XCTUnwrap(last.elapsed), try XCTUnwrap(last.duration), accuracy: 1e-9)
    }

    func testTheEndReadsTheWholeSpanAndRateZero() throws {
        let navigation = makeNavigation()
        let ended = snapshot(navigation, at: 8, status: .ended, rate: 1.5)
        XCTAssertEqual(try XCTUnwrap(ended.elapsed), try XCTUnwrap(ended.duration))
        XCTAssertEqual(ended.playbackRate, 0)
    }

    func testOnlyPlayingOrBufferingReportsTheRate() {
        let navigation = makeNavigation()
        for status in [PlayerStatus.idle, .paused, .ended, .error] {
            XCTAssertEqual(snapshot(navigation, at: 4, status: status, rate: 1.5).playbackRate, 0, "\(status)")
        }
        let playing = snapshot(navigation, at: 4, status: .playing, rate: 1.5)
        XCTAssertEqual(playing.playbackRate, 1.5)
        XCTAssertEqual(playing.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(playing.nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
    }

    /// A sentence still buffering is a start on its way (L025): the system
    /// hears the playing rate, as the app's circle shows Pause, and the push
    /// when its audio starts differs, so the clock re-anchors at the heard time.
    func testABufferingSentenceReportsThePlayingRateAndReanchorsWhenItStarts() throws {
        let navigation = makeNavigation()
        let buffering = snapshot(navigation, at: 4, status: .buffering, rate: 1.5)
        let playing = snapshot(navigation, at: 4, status: .playing, rate: 1.5)
        XCTAssertEqual(buffering.playbackRate, 1.5)
        XCTAssertEqual(buffering.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(try XCTUnwrap(buffering.elapsed), try XCTUnwrap(playing.elapsed), accuracy: 1e-9)
        XCTAssertNotEqual(buffering, playing, "the start's push would be skipped as unchanged")
    }

    /// Before navigation is built the push is identity only.
    func testWithoutNavigationOnlyIdentity() {
        let shot = snapshot(nil, at: 4, author: "Jane Austen", status: .playing, rate: 1.5)
        XCTAssertNil(shot.album)
        XCTAssertNil(shot.span)
        XCTAssertNil(shot.duration)
        XCTAssertNil(shot.elapsed)
        XCTAssertEqual(Set(shot.nowPlayingInfo.keys),
                       [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist,
                        MPNowPlayingInfoPropertyPlaybackRate, MPNowPlayingInfoPropertyDefaultPlaybackRate])
        XCTAssertEqual(shot.nowPlayingInfo[MPMediaItemPropertyTitle] as? String, Self.title)
    }

    // MARK: - Scrubbing

    func testAScrubLandsOnTheNearestSentenceStart() {
        let navigation = makeNavigation()
        for chapterStart in [0, 3, 6] {
            let span = navigation.scrubSpan(at: chapterStart)
            for sentence in span {
                let start = navigation.secondsIntoSpan(of: sentence, in: span, rate: 1)
                XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: start, in: span, navigation: navigation),
                               sentence, "start of \(sentence)")
                guard sentence < span.upperBound else { continue }
                let next = navigation.secondsIntoSpan(of: sentence + 1, in: span, rate: 1)
                let midpoint = (start + next) / 2
                XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: midpoint - 0.01, in: span, navigation: navigation),
                               sentence, "just before the midpoint after \(sentence)")
                XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: midpoint + 0.01, in: span, navigation: navigation),
                               sentence + 1, "just past the midpoint after \(sentence)")
            }
        }
    }

    func testAScrubOutsideTheSpanClamps() throws {
        let navigation = makeNavigation()
        let span = navigation.scrubSpan(at: 4)
        let duration = try XCTUnwrap(snapshot(navigation, at: 4).duration)
        XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: -5, in: span, navigation: navigation), span.lowerBound)
        XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: .nan, in: span, navigation: navigation), span.lowerBound)
        XCTAssertEqual(NowPlayingSnapshot.sentence(atElapsed: duration * 3, in: span, navigation: navigation),
                       span.upperBound)
    }

    // MARK: - Acceptance on a real classic

    /// R23 on Pride and Prejudice: at 1x, 1.5x and 2x the lock screen's
    /// remaining time is the chapter line's within a minute, the artist is
    /// the author and the album is the chapter. Slow (it extracts the whole
    /// book); skipped when the book isn't bundled.
    func testPrideAndPrejudiceMatchesTheChapterLine() async throws {
        guard let book = BookshelfCatalog.load(from: .main).first(where: { $0.gutenbergID == 1342 }),
              let url = BookshelfCatalog.bundledURL(for: book) else {
            throw XCTSkip("Pride and Prejudice isn't bundled in this build")
        }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: book.title, progress: nil)
        let navigation = ReaderNavigation(content: content, kind: .text)
        let count = content.sentences.count
        XCTAssertGreaterThan(count, 100)

        for rate in [1, 1.5, 2] {
            for sentence in stride(from: 0, to: count, by: 50) {
                let words = content.sentences[sentence].wordCount
                var heardSeconds: [TimeInterval] = [0]
                if words <= 60 { heardSeconds.append(Double(words) / (165 * rate) * 60 / 2) }
                for heard in heardSeconds {
                    let label = "sentence \(sentence) at \(rate)x, \(heard) s in"
                    let shot = NowPlayingSnapshot(title: book.title, author: book.author, navigation: navigation,
                                                  sentence: sentence, status: .playing, rate: rate,
                                                  sentenceElapsed: heard)
                    guard let duration = shot.duration, let elapsed = shot.elapsed else {
                        XCTFail("no timeline: \(label)")
                        continue
                    }
                    let line = navigation.positionLine(at: sentence, rate: rate, documentTitle: book.title)
                    let inApp = Double(try XCTUnwrap(line.minutesLeft, label)) * 60
                    XCTAssertLessThanOrEqual(abs((duration - elapsed) / rate - inApp), 60, label)
                }
            }
        }

        let middle = NowPlayingSnapshot(title: book.title, author: book.author, navigation: navigation,
                                        sentence: count / 2, status: .paused, rate: 1.5, sentenceElapsed: 0)
        XCTAssertEqual(middle.artist, "Jane Austen")
        let album = try XCTUnwrap(middle.album)
        XCTAssertNotNil(album.range(of: "^chapter", options: [.regularExpression, .caseInsensitive]), album)
    }
}
