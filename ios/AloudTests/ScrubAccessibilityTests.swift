import Darwin
import SwiftUI
import XCTest
@testable import Aloud

/// R12c and R17 as VoiceOver meets them: the scrub is one adjustable
/// element labelled "Position", its value is the playhead's spoken position
/// (never a sentence index), and each adjust is a `.scrub` jump to a
/// chapter start that keeps play/pause and offers Undo jump.
///
/// Hosted in a window with the AX runtime's automation switched on, so
/// SwiftUI builds its accessibility tree. Only a host that still vends no
/// tree at all skips; a tree without the element fails. Silent: the muted
/// rig, autoplay suppressed, paused throughout.
@MainActor
final class ScrubAccessibilityTests: XCTestCase {

    /// Three chapters: sentences 0–1, 2–4 and 5.
    private static let pages = [1, 1, 2, 2, 2, 3]

    private var host: AccessibilityHost?
    private var modelDirectory: URL?
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreAccessibility = AccessibilityRuntime.enable()
    }

    override func tearDown() {
        host?.close()
        host = nil
        if let modelDirectory { try? FileManager.default.removeItem(at: modelDirectory) }
        restoreAccessibility?()
        restoreAccessibility = nil
        super.tearDown()
    }

    /// The bar over the three-chapter book, paused at `sentence`.
    private func hostBar(pausedAt sentence: Int) -> (rig: PlaybackTestRig, navigation: ReaderNavigation,
                                                     document: LibraryDocument) {
        let rig = PlaybackTestRig(sentences: Self.pages.count, autoplaySuppressed: true)
        let content = PlaybackTestRig.makeContent(hash: "scrub-a11y", count: Self.pages.count,
                                                  wordsPerSentence: 4, pages: Self.pages)
        let document = PlaybackTestRig.makeDocument(hash: "scrub-a11y", sentences: Self.pages.count,
                                                    progressSentence: sentence)
        rig.controller.load(document: document, content: content)
        let navigation = ReaderNavigation(content: content, kind: .text)

        // An expensive path and an empty directory: nothing is ever
        // downloaded, and the offer stays hidden on an unsupported device.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrubAccessibilityTests-\(UUID().uuidString)", isDirectory: true)
        modelDirectory = directory
        let defaults = PlaybackTestRig.freshDefaults()
        let manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: true),
                                   installDirectory: directory, defaults: defaults)
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: false, now: { 0 })

        host = AccessibilityHost(
            PlayerBarView(document: document, content: content, navigation: navigation)
                .environmentObject(rig.controller)
                .environmentObject(offer)
                .environmentObject(manager)
                .environmentObject(SleepTimer()),
            keepAlive: [rig, manager, offer])
        return (rig, navigation, document)
    }

    private func findScrub() async throws -> NSObject {
        try await XCTUnwrap(host).require("player.scrub")
    }

    private func spokenPosition(_ sentence: Int, _ navigation: ReaderNavigation,
                                _ rig: PlaybackTestRig, _ document: LibraryDocument) -> String {
        navigation.positionLine(at: sentence, rate: rig.controller.rate,
                                documentTitle: document.title).accessibilityLabel
    }

    func testIncrementJumpsToTheNextChapterStart() async throws {
        let (rig, navigation, document) = hostBar(pausedAt: 1)
        let scrub = try await findScrub()

        XCTAssertTrue(scrub.accessibilityTraits.contains(.adjustable), "the scrub should be adjustable")
        XCTAssertEqual(scrub.accessibilityLabel, "Position")
        XCTAssertEqual(scrub.accessibilityValue, spokenPosition(1, navigation, rig, document))
        XCTAssertTrue(scrub.accessibilityHint?.isEmpty ?? true, "no custom hint: \(scrub.accessibilityHint ?? "")")

        #if DEBUG
        TransportHaptics.shared.resetLog()
        #endif
        scrub.accessibilityIncrement()

        let moved = await rig.waitUntil(2) { rig.controller.currentSentence == 2 }
        XCTAssertTrue(moved, "increment should land on chapter 2's start, got \(rig.controller.currentSentence)")
        XCTAssertEqual(rig.controller.status, .paused, "a scrub step keeps play/pause")
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 1, "a scrub step offers Undo jump")
        XCTAssertEqual(rig.controller.undoableJump?.toSentence, 2)
        #if DEBUG
        XCTAssertEqual(TransportHaptics.shared.logText, "", "VoiceOver scrub steps play no haptic")
        #endif

        // VoiceOver reads the new value after an adjust.
        let expected = spokenPosition(2, navigation, rig, document)
        let updated = await rig.waitUntil(2) {
            self.host?.find("player.scrub")?.accessibilityValue == expected
        }
        XCTAssertTrue(updated, "the value should follow the playhead to \(expected)")
    }

    func testDecrementFromInsideAChapterGoesToItsStart() async throws {
        let (rig, _, _) = hostBar(pausedAt: 3)
        let scrub = try await findScrub()

        scrub.accessibilityDecrement()

        let moved = await rig.waitUntil(2) { rig.controller.currentSentence == 2 }
        XCTAssertTrue(moved, "decrement from 3 should land on its chapter's start, got \(rig.controller.currentSentence)")
        XCTAssertEqual(rig.controller.status, .paused)
    }

    /// P008: the thumb and the touch-down feedback are decoration. The
    /// scrub is still one adjustable "Position" element, and nothing else
    /// in the bar answers to that name.
    func testTheThumbAddsNoElement() async throws {
        _ = hostBar(pausedAt: 1)
        let scrub = try await findScrub()
        XCTAssertTrue(scrub.accessibilityTraits.contains(.adjustable))
        let positions = try XCTUnwrap(host).all(labelled: "Position")
        XCTAssertEqual(positions.count, 1, "one Position element, got \(positions.count)")
    }
}

/// P008's touch feedback: the thumb sits on the fill's end inside the track,
/// a held track grows, and the touch-down gesture's travel is never a seek.
final class ScrubThumbTests: XCTestCase {

    func testTheThumbCentresOnTheFillsEndInsideTheTrack() {
        XCTAssertEqual(ScrubThumb.offset(fill: 100, diameter: 12, width: 300), 94)
        XCTAssertEqual(ScrubThumb.offset(fill: 4, diameter: 12, width: 300), 0, "kept inside at the start")
        XCTAssertEqual(ScrubThumb.offset(fill: 300, diameter: 20, width: 300), 280, "kept inside at the end")
        XCTAssertEqual(ScrubThumb.offset(fill: 0, diameter: 20, width: 10), 0, "a track narrower than the thumb")
    }

    func testAHeldTrackGrows() {
        XCTAssertEqual(ScrubThumb.trackHeight, 4)
        XCTAssertEqual(ScrubThumb.pressedTrackHeight, 8)
        XCTAssertEqual(ScrubThumb.diameter, 12)
        XCTAssertEqual(ScrubThumb.pressedDiameter, 20)
    }

    /// The feedback starts on touch-down, but a touch that never travels 8pt
    /// sideways is no seek (R17): no preview, no jump, no tick, no Undo.
    func testTouchDownTravelIsNeverASeek() {
        XCTAssertEqual(ScrubGesture.touchDownDistance, 0)
        for travel in [0, 3, 7.9] as [CGFloat] {
            XCTAssertFalse(ScrubGesture.isSeek(translation: CGSize(width: travel, height: 0)), "\(travel)pt")
            XCTAssertNil(ScrubDrag.next(after: nil, translation: CGSize(width: travel, height: 30),
                                        current: { 0...9 }, target: { $0.lowerBound }))
        }
        let latch = ScrubReleaseSpan()
        XCTAssertNil(latch.release(translation: CGSize(width: 2, height: 0), current: { 0...9 }),
                     "lifting without travel seeks nothing")
    }
}

/// R17's Contents grouping as VoiceOver meets it: a Part/Book heading is a
/// header above its chapters (XCUITest can't see the header trait, so it is
/// checked here), the current chapter is selected, and a row is a `.chapter`
/// jump that keeps play/pause and offers Undo jump (R15).
@MainActor
final class ContentsSheetAccessibilityTests: XCTestCase {

    private var host: AccessibilityHost?
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreAccessibility = AccessibilityRuntime.enable()
    }

    override func tearDown() {
        host?.close()
        host = nil
        restoreAccessibility?()
        restoreAccessibility = nil
        super.tearDown()
    }

    /// "BOOK ONE: 1805" alone on page 0 folds into CHAPTER I (page 1);
    /// CHAPTER II is page 2. Pages count from 0, so rows display from 1.
    private static func groupedContent() -> DocContent {
        let lines: [(text: String, page: Int)] = [
            ("BOOK ONE: 1805", 0),
            ("CHAPTER I", 1), ("Well, Prince, so Genoa and Lucca are now just family estates.", 1),
            ("CHAPTER II", 2), ("Anna Pavlovna had had a cough for some days.", 2),
        ]
        let sentences = lines.enumerated().map { index, line in
            Sentence(id: index, text: line.text, para: index, page: line.page)
        }
        let paragraphs = lines.enumerated().map { index, line in
            Paragraph(id: index, sentenceIDs: index..<(index + 1), page: line.page)
        }
        return DocContent(title: "Grouped", pageCount: 3, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "contents-a11y")
    }

    func testSectionHeaderSelectionAndRowJump() async throws {
        let rig = PlaybackTestRig(sentences: 5, autoplaySuppressed: true)
        let content = Self.groupedContent()
        let navigation = ReaderNavigation(content: content, kind: .text)
        XCTAssertEqual(navigation.sections.first?.title, "BOOK ONE: 1805", "fixture should group")
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "contents-a11y", sentences: 5,
                                                                   progressSentence: 2),
                            content: content)

        let host = AccessibilityHost(
            ContentsSheet(content: content, navigation: navigation)
                .environmentObject(rig.controller),
            keepAlive: [rig])
        self.host = host
        let header = try await host.require("contents.section.0")
        XCTAssertTrue(header.accessibilityTraits.contains(.header), "a section title is a header")
        XCTAssertEqual(header.accessibilityLabel, "BOOK ONE: 1805")

        let current = try await host.require("chapters.row.2")
        let next = try await host.require("chapters.row.3")
        XCTAssertTrue(current.accessibilityTraits.contains(.selected), "the playhead's chapter is selected")
        XCTAssertFalse(next.accessibilityTraits.contains(.selected))

        _ = next.accessibilityActivate()
        let moved = await rig.waitUntil(2) { rig.controller.currentSentence == 3 }
        XCTAssertTrue(moved, "a row should jump to its chapter's start, got \(rig.controller.currentSentence)")
        XCTAssertEqual(rig.controller.status, .paused, "a Contents pick keeps play/pause")
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 2, "a Contents pick offers Undo jump")
    }
}

/// The view glue the hosted tests above exercise, held in source as well:
/// in a host that builds no accessibility tree they skip, and nothing else
/// reaches the scrub's adjustable action or the section header's trait.
/// (The step itself, `adjustmentTarget`, and the `.scrub` jump's Undo are
/// unit-tested in ReaderScrubTests and UndoJumpTests.)
final class ScrubAccessibilityLintTests: XCTestCase {

    /// The text from `start` up to (not including) the first `end` after
    /// it, whitespace collapsed so a reformat doesn't trip the lint.
    private func region(of source: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), "no '\(start)'")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex),
                               "no '\(end)' after '\(start)'")
        return source[from.lowerBound..<to.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// R12c: increment steps forward, decrement back, each a `.scrub` jump
    /// (keeps play/pause, offers Undo), with no haptic.
    func testTheScrubsAdjustableActionStepsByChapterAsAScrubJump() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        let action = try region(of: bar, from: ".accessibilityAdjustableAction",
                                to: ".accessibilityIdentifier(\"player.scrub\")")
        XCTAssertFalse(action.contains(".accessibilityIdentifier("),
                       "the adjustable action belongs to player.scrub")
        for needle in ["navigation.adjustmentTarget(", "forward: direction == .increment",
                       "jump(to:", "origin: .scrub"] {
            XCTAssertTrue(action.contains(needle), "the scrub's adjustable action should contain '\(needle)': \(action)")
        }
        for needle in ["origin: .sentence", "seek(to:", "TransportHaptics", "direction == .decrement"] {
            XCTAssertFalse(action.contains(needle), "the scrub's adjustable action should not contain '\(needle)'")
        }
    }

    /// R17: a Part/Book title in Contents is a VoiceOver header.
    func testContentsSectionTitlesAreHeaders() throws {
        let sources = try SourceTree.sources(only: ["Reader/ContentsSheet.swift"])
        let contents = try XCTUnwrap(sources["Reader/ContentsSheet.swift"])
        let header = try region(of: contents, from: "func sectionHeader(",
                                to: ".accessibilityIdentifier(\"contents.section.")
        XCTAssertTrue(header.contains(".accessibilityAddTraits(.isHeader)"),
                      "a section title should carry the header trait: \(header)")
    }
}

/// A SwiftUI view in a real window, and lookups in the accessibility tree
/// SwiftUI builds for it. `keepAlive` holds the models the view observes.
/// Shared with PlayerBarLayoutTests, which measures the bar through it.
@MainActor
final class AccessibilityHost {

    private let window: UIWindow
    private let keepAlive: [AnyObject]

    init<Content: View>(_ view: Content, keepAlive: [AnyObject], width: CGFloat = 390) {
        self.keepAlive = keepAlive
        let controller = UIHostingController(rootView: view)
        // A scene-backed window, so SwiftUI renders and updates it as it
        // would on screen.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Waits for the element with `identifier` to appear in the tree.
    func element(_ identifier: String, timeout: TimeInterval = 2) async -> NSObject? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = find(identifier) { return found }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The element with `identifier`. Skips only when this host vends no
    /// accessibility tree at all; a tree without the element is a failure,
    /// so a dropped or renamed identifier can't pass as a skip. The first
    /// lookup allows for the AX runtime loading after automation turns on.
    func require(_ identifier: String, timeout: TimeInterval = 5) async throws -> NSObject {
        if let found = await element(identifier, timeout: timeout) { return found }
        guard vendsTree else { throw XCTSkip("This test host builds no SwiftUI accessibility tree") }
        throw MissingAccessibilityElement(identifier: identifier)
    }

    /// Whether the hosting view vends any accessibility element at all.
    var vendsTree: Bool {
        guard let root = window.rootViewController?.view else { return false }
        if let elements = root.accessibilityElements, !elements.isEmpty { return true }
        let count = root.accessibilityElementCount()
        return count > 0 && count != NSNotFound
    }

    func find(_ identifier: String) -> NSObject? {
        first { Self.identifier(of: $0) == identifier }
    }

    /// Every element whose label is `label`.
    func all(labelled label: String) -> [NSObject] {
        var found: [NSObject] = []
        _ = first { node in
            if node.accessibilityLabel == label, node.isAccessibilityElement { found.append(node) }
            return false
        }
        return found
    }

    /// The identifiers in `wanted` in the order a depth-first walk of the
    /// accessibility tree meets them: the order VoiceOver swipes through.
    func order(of wanted: Set<String>) -> [String] {
        guard let root = window.rootViewController?.view else { return [] }
        var order: [String] = []
        var visited = 0
        func visit(_ node: NSObject) {
            visited += 1
            guard visited < 5_000 else { return }
            if let identifier = Self.identifier(of: node), wanted.contains(identifier), !order.contains(identifier) {
                order.append(identifier)
            }
            if let elements = node.accessibilityElements {
                elements.compactMap { $0 as? NSObject }.forEach(visit)
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return order
    }

    /// A breadth-first walk over accessibility children and subviews.
    private func first(where matches: (NSObject) -> Bool) -> NSObject? {
        guard let root = window.rootViewController?.view else { return nil }
        var queue: [NSObject] = [root]
        var next = 0
        while next < queue.count, next < 5_000 {
            let node = queue[next]
            next += 1
            if matches(node) { return node }
            if let elements = node.accessibilityElements {
                queue.append(contentsOf: elements.compactMap { $0 as? NSObject })
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { queue.append(child) }
                    }
                }
            }
            if let view = node as? UIView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func identifier(of node: NSObject) -> String? {
        if let identified = node as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        guard node.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }
}

/// The tree is there, the element isn't: a real failure, never a skip.
private struct MissingAccessibilityElement: Error, CustomStringConvertible {
    let identifier: String
    var description: String { "The accessibility tree has no '\(identifier)'" }
}

/// SwiftUI builds its accessibility tree only for an assistive client, and
/// a unit-test host has none (XCUITest and VoiceOver turn this on in the
/// app). The AX runtime's own switches stand in for one, as KIF and
/// AccessibilitySnapshot do. Private API, in the test target only.
enum AccessibilityRuntime {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    private static let library: UnsafeMutableRawPointer? = {
        let path = "/usr/lib/libAccessibility.dylib"
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        return dlopen(root + path, RTLD_NOW) ?? dlopen(path, RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// Turns automation and app accessibility on; the closure puts back
    /// what was there, so no other test runs with them.
    static func enable() -> () -> Void {
        let switches = [("_AXSAutomationEnabled", "_AXSSetAutomationEnabled"),
                        ("_AXSApplicationAccessibilityEnabled", "_AXSApplicationAccessibilitySetEnabled")]
        var restores: [() -> Void] = []
        for (getterName, setterName) in switches {
            guard let get = symbol(getterName, as: Getter.self),
                  let set = symbol(setterName, as: Setter.self) else { continue }
            let before = get()
            set(1)
            restores.append { set(before) }
        }
        return { restores.forEach { $0() } }
    }
}
