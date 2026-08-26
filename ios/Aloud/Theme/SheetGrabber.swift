import SwiftUI

/// The app's bottom-sheet grabber: one capsule, drawn the same way in every
/// sheet. It replaces the system drag indicator, which `.sheetChrome(_:)`
/// hides — the two ship together so a sheet can't end up showing both (the
/// speed sheet once did) or neither.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Theme.lineStrong)
            .frame(width: 36, height: 4)
            .padding(.top, 10)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Standard sheet presentation: the given detents with the system drag
    /// indicator hidden, because the sheet draws its own `SheetGrabber`.
    func sheetChrome(_ detents: Set<PresentationDetent>) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.hidden)
    }
}
