import SwiftUI

/// R8: the reader's one voice and speed sheet; picks are app-wide (R7).
///
/// It opens at 60% of the screen, so the page and its highlighted
/// sentence stay in view above it while voices are auditioned, as the Mac's
/// capped popover leaves the page in view (P034). The list scrolls inside,
/// opened at the selected voice, and a drag up takes the sheet to the full
/// list. A fixed fraction, never the content's height, so the first frame
/// is the last: nothing snaps as the content is measured.
///
/// Two detents, so `sheetChrome` keeps the system drag indicator (the
/// control VoiceOver resizes the sheet with) and the SheetGrabber steps
/// aside. The scrim stays: a tap above the sheet closes it.
struct ListeningSheet: View {
    /// Where the sheet opens: the page keeps the top 40% of the screen.
    static let openingDetent: PresentationDetent = .fraction(0.6)
    static let detents: Set<PresentationDetent> = [openingDetent, .large]

    @State private var detent: PresentationDetent = ListeningSheet.openingDetent

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the scroll view: the title never scrolls away.
            VStack(spacing: Theme.Space.xs) {
                SheetGrabber()
                // Wraps, centered inside the gutters, rather than truncating
                // at the largest sizes or while the detent is still moving.
                Text(ListeningCopy.title)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.sheetGutter)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("listening.title")
            }
            .padding(.bottom, Theme.Space.xs)

            ListeningView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheetChrome(Self.detents, selection: $detent)
    }
}
