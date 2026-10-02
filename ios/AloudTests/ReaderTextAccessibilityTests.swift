import XCTest
import SwiftUI
import UIKit
@testable import Aloud

/// R12a on the reading column itself: one VoiceOver element with Chapters
/// (Pages), Paragraphs and Sentences rotors, a "Play from here" action, a
/// double-tap and magic tap, all through spy closures. Nothing is built at
/// open, so a 60,000-sentence book installs as fast as a short one.
@MainActor
final class ReaderTextAccessibilityTests: XCTestCase {

    private final class Spy {
        var played: [Int] = []
        var magicTaps = 0
    }

    /// Sentences on the given pages (one chapter per page for text), three
    /// sentences per paragraph.
    private func content(pages: [Int], hash: String = "a11y") -> DocContent {
        let sentences = pages.enumerated().map { index, page in
            Sentence(id: index, text: "Sentence \(index) reads aloud.", para: index / 3, page: page)
        }
        let paragraphs = stride(from: 0, to: pages.count, by: 3).map { start in
            Paragraph(id: start / 3, sentenceIDs: start..<min(start + 3, pages.count), page: pages[start])
        }
        return DocContent(title: "A11y", pageCount: pages.max() ?? 0, sentences: sentences,
                          paragraphs: paragraphs, contentHash: hash)
    }

    private func parent(_ content: DocContent, kind: DocKind = .text, navigation: ReaderNavigation?,
                        spy: Spy) -> ReaderTextView {
        ReaderTextView(content: content, isChapterBook: kind == .text, navigation: navigation,
                       fontSize: 19, activeSentence: 0, activeWord: -1,
                       voiceOffscreen: .constant(nil), textUnderTopBar: .constant(false),
                       onTapSentence: { spy.played.append($0) },
                       onMagicTap: { spy.magicTaps += 1 })
    }

    private func makeColumn(_ content: DocContent, kind: DocKind = .text, spy: Spy = Spy())
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let navigation = ReaderNavigation(content: content, kind: kind)
        let coordinator = ReaderTextView.Coordinator(parent: parent(content, kind: kind,
                                                                    navigation: navigation, spy: spy))
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.install(on: textView)
        coordinator.rebuild(content: content, fontSize: 19)
        textView.layoutIfNeeded()
        coordinator.setActiveSentence(0, scroll: false)
        return (coordinator, textView)
    }

    private func rotor(_ name: String, on textView: UITextView) throws -> UIAccessibilityCustomRotor {
        try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == name }, "no \(name) rotor")
    }

    private func step(_ rotor: UIAccessibilityCustomRotor,
                      _ direction: UIAccessibilityCustomRotor.Direction = .next)
        -> UIAccessibilityCustomRotorItemResult? {
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = direction
        return rotor.itemSearchBlock(predicate)
    }

    // MARK: - Rotors

    func testRotorsRunCoarseToFine() {
        let chaptered = content(pages: [1, 1, 1, 2, 2, 2])
        XCTAssertEqual(makeColumn(chaptered).textView.accessibilityCustomRotors?.map(\.name),
                       ["Chapters", "Paragraphs", "Sentences"])

        let chapterless = content(pages: [1, 1, 1, 1], hash: "one-chapter")
        XCTAssertEqual(makeColumn(chapterless).textView.accessibilityCustomRotors?.map(\.name),
                       ["Paragraphs", "Sentences"])

        let pdf = content(pages: [1, 1, 2, 2, 3, 3], hash: "pdf")
        XCTAssertEqual(makeColumn(pdf, kind: .pdf).textView.accessibilityCustomRotors?.map(\.name),
                       ["Pages", "Paragraphs", "Sentences"])
    }

    func testSentenceRotorStepsThenPlayFromHere() throws {
        let spy = Spy()
        let book = content(pages: [1, 1, 1, 2, 2, 2])
        let (coordinator, textView) = makeColumn(book, spy: spy)
        let expected = ReaderTextView.Coordinator.makeAttributedString(content: book, fontSize: 19,
                                                                       isChapterBook: true).sentenceRanges
        let sentences = try rotor("Sentences", on: textView)

        for sentence in 0..<3 {
            let result = try XCTUnwrap(step(sentences), "step \(sentence)")
            XCTAssertTrue(result.targetElement === textView, "the column is the one element")
            let range = try XCTUnwrap(result.targetRange)
            let location = textView.offset(from: textView.beginningOfDocument, to: range.start)
            let length = textView.offset(from: range.start, to: range.end)
            XCTAssertEqual(NSRange(location: location, length: length), expected[sentence],
                           "the first step starts at the playhead, then one sentence per flick")
        }
        XCTAssertEqual(coordinator.accessibilitySentence, 2)
        XCTAssertEqual(textView.accessibilityLabel, book.sentences[2].text)
        XCTAssertNil(textView.accessibilityValue, "the value never carries the book or an index")
        XCTAssertNil(textView.accessibilityAttributedValue)

        let actions = textView.accessibilityCustomActions ?? []
        XCTAssertEqual(actions.map(\.name), ["Play from here"])
        let playFromHere = try XCTUnwrap(actions.first)
        XCTAssertEqual(playFromHere.actionHandler?(playFromHere), true)
        XCTAssertEqual(spy.played, [2], "plays the rotor's sentence")
        XCTAssertNil(coordinator.accessibilitySentence, "playing forgets the rotor position")

        XCTAssertTrue(textView.accessibilityActivate())
        XCTAssertEqual(spy.played, [2, 0], "a double-tap with no rotor position plays the playhead's sentence")
    }

    func testChapterRotorLandsOnChapterStarts() throws {
        let book = content(pages: [1, 1, 1, 2, 2, 2])
        let (coordinator, textView) = makeColumn(book)
        let chapters = try rotor("Chapters", on: textView)
        XCTAssertNotNil(step(chapters))
        XCTAssertEqual(coordinator.accessibilitySentence, 0, "the chapter holding the playhead")
        XCTAssertNotNil(step(chapters))
        XCTAssertEqual(coordinator.accessibilitySentence, 3, "the next chapter's first sentence")
        XCTAssertNil(step(chapters), "nothing past the last chapter")
        XCTAssertNotNil(step(chapters, .previous))
        XCTAssertEqual(coordinator.accessibilitySentence, 0)
    }

    func testLosingFocusForgetsTheRotorPosition() throws {
        let book = content(pages: [1, 1, 1, 2, 2, 2])
        let (coordinator, textView) = makeColumn(book)
        let paragraphs = try rotor("Paragraphs", on: textView)
        XCTAssertNotNil(step(paragraphs))
        XCTAssertNotNil(step(paragraphs))
        XCTAssertEqual(coordinator.accessibilitySentence, 3)

        textView.accessibilityElementDidLoseFocus()
        XCTAssertNil(coordinator.accessibilitySentence)
        XCTAssertEqual(textView.accessibilityLabel, book.sentences[0].text, "back to the playhead's sentence")
    }

    func testMagicTapHintAndVoiceControlName() {
        let spy = Spy()
        let (coordinator, textView) = makeColumn(content(pages: [1, 1, 1]), spy: spy)
        // The view holds its coordinator weakly, as UIKit delegates do; in
        // the app SwiftUI keeps it alive, so the test must too.
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(textView.accessibilityPerformMagicTap())
            XCTAssertEqual(spy.magicTaps, 1)
            XCTAssertEqual(spy.played, [], "magic tap toggles, it never jumps")
            XCTAssertEqual(textView.accessibilityUserInputLabels, ["Text"])
            XCTAssertEqual(textView.accessibilityHint, "Plays from this sentence")
            XCTAssertEqual(textView.accessibilityIdentifier, "reader.text")
        }
    }

    // MARK: - Cost at open

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    /// The fastest of three installs, and the first label read of the last.
    private func openCost(sentences count: Int) -> (install: TimeInterval, firstLabel: TimeInterval) {
        let book = content(pages: Array(repeating: 1, count: count), hash: "cost-\(count)")
        var install = TimeInterval.infinity
        var firstLabel = TimeInterval.infinity
        for _ in 0..<3 {
            let coordinator = ReaderTextView.Coordinator(parent: parent(book, navigation: nil, spy: Spy()))
            let textView = ReaderUITextView(usingTextLayoutManager: true)
            textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
            install = min(install, elapsed { coordinator.install(on: textView) })
            coordinator.setActiveSentence(count / 2, scroll: false)
            var label: String?
            // The label closure holds the coordinator weakly.
            withExtendedLifetime(coordinator) {
                firstLabel = elapsed { label = textView.accessibilityLabel }
            }
            XCTAssertEqual(label, book.sentences[count / 2].text)
        }
        return (install, firstLabel)
    }

    /// Install only: it takes no content. What a rebuild adds for VoiceOver
    /// is held by testARebuiltLongBookHoldsNothingPerSentence.
    func testNothingIsBuiltAtOpen() {
        _ = openCost(sentences: 10)   // warm up UIKit and accessibility
        let short = openCost(sentences: 100)
        let pepys = openCost(sentences: 60_000)
        XCTAssertLessThan(abs(pepys.install - short.install), 0.005,
                          "install builds nothing from the content (100: \(short.install) s, 60,000: \(pepys.install) s)")
        XCTAssertLessThan(pepys.firstLabel, 0.001, "the first label read is one array lookup")
    }

    private func fastest(of runs: Int, _ work: () -> Void) -> TimeInterval {
        (0..<runs).map { _ in elapsed(work) }.min() ?? .infinity
    }

    /// The fastest of five first steps, each from the playhead as if
    /// VoiceOver had just focused the column.
    private func firstStepCost(_ name: String, on textView: ReaderUITextView) throws -> TimeInterval {
        let rotor = try rotor(name, on: textView)
        return fastest(of: 5) {
            textView.accessibilityElementDidLoseFocus()
            XCTAssertNotNil(step(rotor), "\(name) steps")
        }
    }

    /// Every stored collection reachable from the coordinator, by property
    /// path, with its element count. Skips `parent`: that is the book itself,
    /// handed in by SwiftUI, not something the column built. Ranges and
    /// strings aren't element storage, so only arrays, dictionaries and sets
    /// count.
    private func heldCollections(of coordinator: ReaderTextView.Coordinator) -> [String: Int] {
        var found: [String: Int] = [:]
        var visited: Set<ObjectIdentifier> = []
        func walk(_ value: Any, path: String, depth: Int) {
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .optional:
                if let wrapped = mirror.children.first { walk(wrapped.value, path: path, depth: depth) }
                return
            case .collection, .dictionary, .set:
                found[path] = (value as? any Collection)?.count ?? mirror.children.count
                return
            case .class:
                guard visited.insert(ObjectIdentifier(value as AnyObject)).inserted else { return }
            case .struct, .tuple, .enum:
                break
            default:
                return
            }
            guard depth < 4 else { return }
            var level: Mirror? = mirror
            while let current = level {
                for child in current.children {
                    let label = child.label ?? "_"
                    if depth == 0, label == "parent" { continue }
                    walk(child.value, path: "\(path).\(label)", depth: depth + 1)
                }
                level = current.superclassMirror
            }
        }
        walk(coordinator, path: "coordinator", depth: 0)
        return found
    }

    /// R12's "Pepys adds under 100 ms": what a rebuild sets up for VoiceOver
    /// (everything but the string, which is the column itself) holds nothing
    /// per sentence. Still one element and the same three rotors, nothing
    /// per sentence or paragraph stored on the coordinator or its view, a
    /// rotor list that costs the same for any book, and a first step that
    /// searches the book's own starts instead of walking a list built up
    /// front. testAPepysRebuildMakesNothingPerSentenceBeyondItsText counts
    /// and times the rest.
    func testARebuiltLongBookHoldsNothingPerSentence() throws {
        // One chapter per 10 (short) or 1,000 (Pepys) sentences.
        let short = content(pages: (0..<100).map { $0 / 10 + 1 }, hash: "rebuilt-100")
        let pepys = content(pages: (0..<60_000).map { $0 / 1_000 + 1 }, hash: "rebuilt-60000")
        let shortColumn = makeColumn(short)
        let pepysColumn = makeColumn(pepys)

        // The rotors hold the coordinators weakly.
        try withExtendedLifetime([shortColumn.coordinator, pepysColumn.coordinator]) {
            for (book, column) in [(short, shortColumn), (pepys, pepysColumn)] {
                let count = book.sentences.count
                XCTAssertNil(column.textView.accessibilityElements, "\(count): the column is one element")
                XCTAssertEqual(column.textView.accessibilityCustomRotors?.map(\.name),
                               ["Chapters", "Paragraphs", "Sentences"], "\(count): three rotors, never one per item")
            }

            let navigation = ReaderNavigation(content: pepys, kind: .text)
            let list = fastest(of: 5) { _ = ReaderRotor.available(content: pepys, navigation: navigation) }
            XCTAssertLessThan(list, 0.001, "the rotor list never reads the sentences (\(list) s)")

            for name in ["Chapters", "Paragraphs", "Sentences"] {
                let shortStep = try firstStepCost(name, on: shortColumn.textView)
                let pepysStep = try firstStepCost(name, on: pepysColumn.textView)
                XCTAssertLessThan(pepysStep - shortStep, 0.005,
                                  "\(name): a first step costs the same in any book (100: \(shortStep) s, 60,000: \(pepysStep) s)")
            }

            // After the rebuild and the first steps, so a rotor list built up
            // front or cached on first use is caught either way. Pepys has
            // 20,000 paragraphs and 60 chapters, so 1,000 items means per
            // sentence or per paragraph.
            let held = heldCollections(of: pepysColumn.coordinator)
            XCTAssertEqual(held["coordinator.sentenceRanges"], 60_000,
                           "the walk should see the coordinator's own range table, got \(held)")
            let perItem = held.filter { $0.key != "coordinator.sentenceRanges" && $0.value >= 1_000 }
            XCTAssertEqual(perItem, [:], "the column stores nothing per sentence besides its range table")
        }
    }

    /// A column installed but never built, as SwiftUI first hands it over.
    private func installedColumn(_ book: DocContent, navigation: ReaderNavigation?)
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let coordinator = ReaderTextView.Coordinator(parent: parent(book, navigation: navigation, spy: Spy()))
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.install(on: textView)
        return (coordinator, textView)
    }

    /// What a rebuild does beyond its text, on fresh installed columns.
    /// `made`: the VoiceOver objects the whole rebuild makes, less what
    /// building the same string and handing it to an identical column makes.
    /// `afterText`: the fastest of three timings of what rebuild runs once
    /// the view has its text. That window holds the rotor list and makeRotor
    /// but never the string, so no large timing is subtracted from another.
    private func beyondText(_ book: DocContent) -> (made: RebuildProbe.Counts, afterText: TimeInterval) {
        let navigation = ReaderNavigation(content: book, kind: .text)
        var textMade = RebuildProbe.Counts()
        autoreleasepool {
            let bare = installedColumn(book, navigation: navigation)
            withExtendedLifetime(bare.coordinator) {
                textMade = RebuildProbe.counting {
                    bare.textView.attributedText = ReaderTextView.Coordinator.makeAttributedString(
                        content: book, fontSize: 19, isChapterBook: true,
                        traits: bare.textView.traitCollection).string
                }
            }
        }
        var wholeMade = RebuildProbe.Counts()
        var afterText = TimeInterval.infinity
        for _ in 0..<3 {
            autoreleasepool {
                let column = installedColumn(book, navigation: navigation)
                withExtendedLifetime(column.coordinator) {
                    RebuildProbe.textHandedOver = nil
                    var finished: UInt64 = 0
                    let made = RebuildProbe.counting {
                        column.coordinator.rebuild(content: book, fontSize: 19)
                        finished = DispatchTime.now().uptimeNanoseconds
                    }
                    wholeMade = wholeMade.most(made)
                    if let handedOver = RebuildProbe.textHandedOver, finished >= handedOver {
                        afterText = min(afterText, TimeInterval(finished - handedOver) / 1_000_000_000)
                    }
                }
            }
        }
        return (wholeMade.less(textMade), afterText)
    }

    /// R12's "Pepys adds under 100 ms", without timing the string. A
    /// VoiceOver item built up front for each sentence, paragraph or chapter,
    /// in rebuild or in makeRotor, even one held only in a rotor's closure,
    /// has to make rotor items, elements or text ranges. The probe counts
    /// those exactly, so a 60,000-sentence rebuild must make exactly what a
    /// 100-sentence one does. Anything else rebuild runs after the text is
    /// timed on its own against R12's 100 ms. Ordinary runs come in far under that.
    func testAPepysRebuildMakesNothingPerSentenceBeyondItsText() throws {
        let short = content(pages: (0..<100).map { $0 / 10 + 1 }, hash: "rebuild-probe-100")
        let pepys = content(pages: (0..<60_000).map { $0 / 1_000 + 1 }, hash: "rebuild-probe-60000")
        try RebuildProbe.install()
        defer { RebuildProbe.uninstall() }

        // Positive controls: the probe sees the one item, range and two
        // positions a rotor step makes, and an element made in Swift, so a
        // probe that stopped counting fails here and never passes vacuously.
        let control = makeColumn(short)
        try withExtendedLifetime(control.coordinator) {
            let sentences = try rotor("Sentences", on: control.textView)
            let stepMade = RebuildProbe.counting { XCTAssertNotNil(step(sentences)) }
            XCTAssertEqual(stepMade.rotorItems, 1, "the probe should count a rotor step's item, got \(stepMade)")
            XCTAssertGreaterThanOrEqual(stepMade.textRanges, 1, "and its text range, got \(stepMade)")
            XCTAssertGreaterThanOrEqual(stepMade.positions, 2, "and the range's two ends, got \(stepMade)")
            let elementMade = RebuildProbe.counting {
                _ = UIAccessibilityElement(accessibilityContainer: control.textView)
            }
            XCTAssertEqual(elementMade.elements, 1, "the probe should count an element, got \(elementMade)")
        }

        _ = beyondText(short)   // warm up fonts, colors, TextKit and UIKit's first-use objects
        let shortBeyond = beyondText(short)
        let pepysBeyond = beyondText(pepys)
        XCTAssertEqual(pepysBeyond.made, shortBeyond.made,
                       "beyond its text, a rebuild makes no VoiceOver object per sentence, paragraph or chapter "
                           + "(100 sentences: \(shortBeyond.made); 60,000: \(pepysBeyond.made))")
        XCTAssertLessThan(pepysBeyond.afterText, 0.1,
                          "after its text, a Pepys rebuild runs under 100 ms (\(pepysBeyond.afterText) s; "
                              + "100 sentences: \(shortBeyond.afterText) s; infinity means the probe never "
                              + "saw rebuild hand the view its text)")
    }
}

// MARK: - Rebuild probe

/// Counts, while armed, every rotor item, accessibility element, text range
/// and text position UIKit makes. It also notes when a text view last
/// finished taking its attributed text.
/// A per-item VoiceOver build can't avoid all four: an item needs a range,
/// a range needs two positions, and an element is the other way to expose a
/// sentence. Each hook replaces one Objective-C method for the length of a
/// test and forwards to the original with raw pointers. No retain or release
/// is added, so the initializers' consumed `self` and +1 results pass
/// through untouched.
private enum RebuildProbe {

    struct Counts: Equatable, CustomStringConvertible {
        var rotorItems = 0
        var elements = 0
        var textRanges = 0
        var positions = 0

        var description: String {
            "\(rotorItems) rotor items, \(elements) elements, \(textRanges) text ranges, \(positions) positions"
        }

        func most(_ other: Counts) -> Counts {
            Counts(rotorItems: max(rotorItems, other.rotorItems), elements: max(elements, other.elements),
                   textRanges: max(textRanges, other.textRanges), positions: max(positions, other.positions))
        }

        func less(_ other: Counts) -> Counts {
            Counts(rotorItems: rotorItems - other.rotorItems, elements: elements - other.elements,
                   textRanges: textRanges - other.textRanges, positions: positions - other.positions)
        }
    }

    struct InstallError: Error, CustomStringConvertible {
        let selector: String
        var description: String { "RebuildProbe: no method \(selector) to hook" }
    }

    nonisolated(unsafe) static var counts = Counts()
    nonisolated(unsafe) static var armed = false
    /// When a text view last returned from setAttributedText:.
    nonisolated(unsafe) static var textHandedOver: UInt64?

    private typealias ObjectToObject = @convention(c)
        (UnsafeRawPointer, Selector, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias TwoObjectsToObject = @convention(c)
        (UnsafeRawPointer, Selector, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias ObjectAndOffsetToObject = @convention(c)
        (UnsafeRawPointer, Selector, UnsafeRawPointer?, Int) -> UnsafeRawPointer?
    private typealias ObjectToVoid = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer?) -> Void

    nonisolated(unsafe) private static var replaced: [(method: Method, original: IMP)] = []
    nonisolated(unsafe) private static var rotorItemInit: TwoObjectsToObject?
    nonisolated(unsafe) private static var elementInit: ObjectToObject?
    nonisolated(unsafe) private static var textRangeFrom: TwoObjectsToObject?
    nonisolated(unsafe) private static var positionFrom: ObjectAndOffsetToObject?
    nonisolated(unsafe) private static var setAttributedText: ObjectToVoid?

    private static func method(_ owner: AnyClass, _ selector: String) throws -> Method {
        guard let method = class_getInstanceMethod(owner, NSSelectorFromString(selector)) else {
            throw InstallError(selector: "-[\(owner) \(selector)]")
        }
        return method
    }

    private static func replace(_ method: Method, with hook: IMP) {
        replaced.append((method, method_setImplementation(method, hook)))
    }

    /// Every method is found and every original stored before the first
    /// hook goes in, so a hook never runs without its original.
    static func install() throws {
        uninstall()
        let rotorItem = try method(UIAccessibilityCustomRotorItemResult.self, "initWithTargetElement:targetRange:")
        let element = try method(UIAccessibilityElement.self, "initWithAccessibilityContainer:")
        let textRange = try method(UITextView.self, "textRangeFromPosition:toPosition:")
        let position = try method(UITextView.self, "positionFromPosition:offset:")
        let attributedText = try method(UITextView.self, "setAttributedText:")
        rotorItemInit = unsafeBitCast(method_getImplementation(rotorItem), to: TwoObjectsToObject.self)
        elementInit = unsafeBitCast(method_getImplementation(element), to: ObjectToObject.self)
        textRangeFrom = unsafeBitCast(method_getImplementation(textRange), to: TwoObjectsToObject.self)
        positionFrom = unsafeBitCast(method_getImplementation(position), to: ObjectAndOffsetToObject.self)
        setAttributedText = unsafeBitCast(method_getImplementation(attributedText), to: ObjectToVoid.self)

        let rotorItemHook: TwoObjectsToObject = { item, selector, element, range in
            if RebuildProbe.armed { RebuildProbe.counts.rotorItems += 1 }
            return RebuildProbe.rotorItemInit?(item, selector, element, range)
        }
        let elementHook: ObjectToObject = { element, selector, container in
            if RebuildProbe.armed { RebuildProbe.counts.elements += 1 }
            return RebuildProbe.elementInit?(element, selector, container)
        }
        let textRangeHook: TwoObjectsToObject = { textView, selector, from, to in
            if RebuildProbe.armed { RebuildProbe.counts.textRanges += 1 }
            return RebuildProbe.textRangeFrom?(textView, selector, from, to)
        }
        let positionHook: ObjectAndOffsetToObject = { textView, selector, position, offset in
            if RebuildProbe.armed { RebuildProbe.counts.positions += 1 }
            return RebuildProbe.positionFrom?(textView, selector, position, offset)
        }
        let setAttributedTextHook: ObjectToVoid = { textView, selector, text in
            RebuildProbe.setAttributedText?(textView, selector, text)
            RebuildProbe.textHandedOver = DispatchTime.now().uptimeNanoseconds
        }
        replace(rotorItem, with: unsafeBitCast(rotorItemHook, to: IMP.self))
        replace(element, with: unsafeBitCast(elementHook, to: IMP.self))
        replace(textRange, with: unsafeBitCast(textRangeHook, to: IMP.self))
        replace(position, with: unsafeBitCast(positionHook, to: IMP.self))
        replace(attributedText, with: unsafeBitCast(setAttributedTextHook, to: IMP.self))
    }

    /// Puts every original back, last hooked first.
    static func uninstall() {
        for (method, original) in replaced.reversed() { method_setImplementation(method, original) }
        replaced = []
        armed = false
    }

    /// What `work` made, counted from zero.
    static func counting(_ work: () -> Void) -> Counts {
        counts = Counts()
        armed = true
        work()
        armed = false
        return counts
    }
}
