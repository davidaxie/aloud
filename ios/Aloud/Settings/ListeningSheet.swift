import SwiftUI

/// R8: the reader's one voice and speed sheet; picks are app-wide (R7).
///
/// It opens at 60% of the screen, so the page and its highlighted
/// sentence stay in view above it while voices are auditioned, as the Mac's
/// capped popover leaves the page in view (P034). A fixed fraction, never
/// the content's height, so the first frame is the last: nothing snaps as
/// the content is measured.
///
/// Below the accessibility sizes the speed controls stay pinned under the
/// title and only the voice list scrolls, opened at the selected voice, so
/// speed and voice are in view together (`ListeningView(pinsSpeed:)`); at
/// those sizes the whole view scrolls as one. A swipe on the list scrolls
/// it at either height (`presentationContentInteraction(.scrolls)`); a
/// drag on the grabber or the title resizes the sheet.
///
/// Two detents, so `sheetChrome` keeps the system drag indicator (the
/// control VoiceOver resizes the sheet with) and the SheetGrabber steps
/// aside. The scrim stays: a tap above the sheet closes it.
///
/// The reader learns how much of the screen the sheet covers
/// (`coveredHeight`), so calm follow measures its band above the sheet
/// rather than above the player bar: the spoken sentence glides into the strip of page left in view,
/// and a voice picked here is heard over a sentence that can be seen.
struct ListeningSheet: View {
    /// Where the sheet opens: the page keeps the top 40% of the screen.
    static let openingDetent: PresentationDetent = .fraction(0.6)
    static let detents: Set<PresentationDetent> = [openingDetent, .large]
    /// How long the sheet's top edge holds still before the reader hears of
    /// it, so a drag between detents never re-aims following every frame.
    static let restingDelay: Duration = .milliseconds(150)

    /// The sheet's full height, safe areas included, as it last rested at
    /// its opening detent, nil once the sheet has gone. The sheet stands on
    /// the window's bottom edge, so the reader takes its top edge from
    /// there. The full list keeps it: the page is out of view there, and
    /// coming back down then moves nothing.
    @Binding private var coveredHeight: CGFloat?
    @State private var detent: PresentationDetent = ListeningSheet.openingDetent
    /// The height as last measured, moving or not.
    @State private var measuredHeight: CGFloat?

    init(coveredHeight: Binding<CGFloat?> = .constant(nil)) {
        _coveredHeight = coveredHeight
    }

    /// The height the reader may be told of: only at the opening detent.
    private var restingHeight: CGFloat? {
        detent == Self.openingDetent ? measuredHeight : nil
    }

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

            ListeningView(pinsSpeed: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A size, never a window position: the sheet is hosted apart from
        // the reader, and its position read in the window was taken before
        // iOS finished raising it, so the reader never heard where it came
        // to rest and the spoken sentence stayed under it. Its size is
        // SwiftUI's own layout, current from the first frame.
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height.rounded()
                } action: { height in
                    measuredHeight = height
                }
        }
        .task(id: restingHeight) {
            // Told only once the sheet holds still at the opening detent.
            guard let restingHeight else { return }
            try? await Task.sleep(for: Self.restingDelay)
            guard !Task.isCancelled, coveredHeight != restingHeight else { return }
            coveredHeight = restingHeight
        }
        .onDisappear { coveredHeight = nil }
        .sheetChrome(Self.detents, selection: $detent)
        // This sheet only: its list scrolls rather than growing the sheet.
        .presentationContentInteraction(.scrolls)
    }
}
