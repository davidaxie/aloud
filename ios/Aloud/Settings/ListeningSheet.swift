import SwiftUI

/// R8: the reader's one voice and speed sheet; opens at a content-sized
/// detent, scrolled to the selected voice; picks are app-wide (R7).
///
/// One detent, so `sheetChrome` hides the system indicator and the
/// SheetGrabber draws. When the content outgrows the screen the detent tops
/// out and the list scrolls.
struct ListeningSheet: View {
    /// Seeded near the default-size installed layout (eleven natural voices)
    /// so the first frame barely moves.
    @State private var headerHeight: CGFloat = 56
    @State private var contentHeight: CGFloat = 764

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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerHeight = height
            }

            ListeningView(onContentHeight: { contentHeight = $0 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheetChrome([.height(headerHeight + contentHeight)])
    }
}
