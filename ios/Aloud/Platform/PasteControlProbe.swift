#if DEBUG
import SwiftUI

// R3-03: the iPhone's paste control probe, DEBUG only and in a file of its
// own, so PlatformPasteControl.swift ships as ordinary code. The iPhone's
// alone: the Mac pastes with ⌘V and has no control to count.

#if os(iOS)
/// How many times the system has handed the paste control a paste
/// (`PlatformPasteControl.Coordinator.paste(itemProviders:)`) since launch,
/// for the UI tests' failure messages: 0 after a tap means the tap never
/// reached the secure control; more means the hand-off to the importer is
/// where to look.
@MainActor
final class PasteControlProbe: ObservableObject {
    static let shared = PasteControlProbe()

    @Published private(set) var pasteCalls = 0

    func recordPaste() { pasteCalls += 1 }
}

/// `PasteControlProbe`'s count as a 1×1 element, `debug.pasteCalls.<n>`,
/// on the Library alone, where the control is (LibraryView): in a UI-test
/// launch only, and never in the way of a touch. The count lives in the
/// identifier only, as the reader's sentence probe keeps its index, so no
/// value on any screen ends in a number.
struct PasteCallsProbe: View {
    @ObservedObject private var probe = PasteControlProbe.shared

    var body: some View {
        if UITestHooks.isUITestLaunch {
            // The constant label keeps SwiftUI from dropping an element
            // that has nothing visible to say.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Paste calls")
                .accessibilityIdentifier("debug.pasteCalls.\(probe.pasteCalls)")
                .allowsHitTesting(false)
        }
    }
}
#endif
#endif
