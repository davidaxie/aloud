import XCTest
@testable import Aloud
#if os(iOS)
import UIKit
#endif

/// R3-03: the iPhone's system paste control, hosted. The UI tests tap it
/// through the simulator, where a synthesized tap may never reach a secure
/// control; these hold its size and its hand-off to the importer without
/// one. The Mac has no control (it pastes with ⌘V), so the suite is the
/// iPhone's alone.
@MainActor
final class PlatformPasteControlTests: XCTestCase {
    #if os(iOS)

    /// The system draws the control out of process and reports no size: the
    /// row sizes it to its label, measured in the links' callout face, or it
    /// draws a blank square that won't paste. Never under 44 pt.
    func testTheLabelSizeHoldsTheWholeWordAndATarget() {
        let control = UIPasteControl(configuration: UIPasteControl.Configuration())
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let size = PlatformPasteControl.labelSize(of: control, traits: traits)
        let font = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traits)
        let title = control.accessibilityLabel ?? PasteTextAction.controlTitle
        let text = (title as NSString).size(withAttributes: [.font: font])
        XCTAssertGreaterThanOrEqual(size.height, 44, "a 44 pt target")
        XCTAssertGreaterThanOrEqual(size.width, ceil(text.width) + 2 * Theme.Space.sm,
                                    "the whole label and the links' side padding")
        let english = (PasteTextAction.controlTitle as NSString).size(withAttributes: [.font: font])
        XCTAssertGreaterThanOrEqual(size.width, ceil(english.width) + 2 * Theme.Space.sm)

        let large = PlatformPasteControl.labelSize(
            of: control, traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThan(large.width, size.width, "it grows with the text size, as the links do")
    }

    /// A paste's text reaches onPaste on the main actor, even when the
    /// coordinator is gone before the read finishes: SwiftUI can rebuild
    /// the row, and the control's target with it, while the providers load.
    func testAPasteDeliversItsTextOnTheMainActor() async {
        let delivered = expectation(description: "onPaste")
        let box = Box()
        #if DEBUG
        let callsBefore = PasteControlProbe.shared.pasteCalls
        #endif
        weak var released: PlatformPasteControl.Coordinator?
        do {
            let coordinator = PlatformPasteControl.Coordinator(onPaste: { strings in
                box.onMain = Thread.isMainThread
                box.strings = strings
                delivered.fulfill()
            })
            released = coordinator
            coordinator.paste(itemProviders: [NSItemProvider(object: "A note\n\nText" as NSString)])
        }
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(box.strings, ["A note\n\nText"])
        XCTAssertEqual(box.onMain, true, "handed over on the main actor")
        XCTAssertNil(released, "delivered with nothing holding the coordinator")
        #if DEBUG
        XCTAssertEqual(PasteControlProbe.shared.pasteCalls, callsBefore + 1, "the UI tests' probe counts the call")
        #endif
    }

    /// A paste with nothing to read adds nothing: onPaste is never called,
    /// and onEmpty is, so the row looks at the clipboard again.
    func testAnEmptyPasteNeverCallsOnPaste() async {
        let pasted = expectation(description: "onPaste")
        pasted.isInverted = true
        let emptied = expectation(description: "onEmpty")
        let coordinator = PlatformPasteControl.Coordinator(onPaste: { _ in pasted.fulfill() },
                                                           onEmpty: { emptied.fulfill() })
        coordinator.paste(itemProviders: [])
        await fulfillment(of: [emptied, pasted], timeout: 1)
    }

    /// An empty string, the only thing a provider held, is no text either.
    func testAnEmptyStringIsNoText() async {
        let pasted = expectation(description: "onPaste")
        pasted.isInverted = true
        let emptied = expectation(description: "onEmpty")
        let coordinator = PlatformPasteControl.Coordinator(onPaste: { _ in pasted.fulfill() },
                                                           onEmpty: { emptied.fulfill() })
        coordinator.paste(itemProviders: [NSItemProvider(object: "" as NSString)])
        await fulfillment(of: [emptied, pasted], timeout: 5)
    }

    private final class Box {
        var strings: [String] = []
        var onMain: Bool?
    }

    #endif
}
