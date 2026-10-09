import SwiftUI

/// The natural-voice offer as it sits in the reader's chapter line (R5):
/// "Natural voice · 353 MB, once" with [Download] and [Not now]. After a
/// Download that found too little space it reads "Natural voice · not
/// enough space · need 707 MB free" (R21) until Download finds room or Not
/// now answers. On the Mac its type follows the reader's chrome band (M18),
/// as the line it replaces does.
struct NaturalVoiceOfferRow: View {

    @EnvironmentObject private var offer: NaturalVoiceOffer
    @EnvironmentObject private var manager: ModelManager
    /// `.standard` on the iPhone, where the band changes nothing.
    @Environment(\.chromeScale) private var chromeScale

    private let onOpenContents: () -> Void
    /// Where the copy's and buttons' ink sits in their 44pt rows: the chapter
    /// line's own `rowAlignment` (the iPhone bar's `.bottom`), so a crossfade
    /// to or from the line it replaces never moves the ink. Only the ink
    /// moves; the rows and their hit areas stay as they are.
    private let rowAlignment: VerticalAlignment

    @State private var isConfirmingCellular = false
    /// Names this row to the manager, so a cellular question answered after
    /// the first path lands opens this row's prompt and no other surface's.
    @State private var promptAsker = UUID()

    init(onOpenContents: @escaping () -> Void, rowAlignment: VerticalAlignment = .center) {
        self.onOpenContents = onOpenContents
        self.rowAlignment = rowAlignment
    }

    /// Each 44pt row's frame alignment: centred across, on `rowAlignment`.
    private var inkAlignment: Alignment { Alignment(horizontal: .center, vertical: rowAlignment) }

    var body: some View {
        // One line only while the whole copy fits beside the buttons;
        // otherwise the copy wraps above them. A one-line row that truncated
        // ("Natural voice · 353 M…") cut the size and the "once" promise from
        // xLarge on 375 and 390pt phones, and earlier at larger sizes.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: rowAlignment, spacing: Theme.Space.xs) {
                offerText(wraps: false)
                Spacer(minLength: Theme.Space.xs)
                buttons
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                offerText(wraps: true)
                // Under the copy, whose row already keeps the slot's air at
                // the accessibility sizes; beside it, each row keeps its own.
                buttons
                    .environment(\.rowInkHeadroom, false)
            }
        }
        .naturalVoiceCellularPrompt(isPresented: $isConfirmingCellular, asker: promptAsker)
    }

    /// The Continue card's rule too, so both surfaces read the same line.
    private var line: String {
        NaturalVoiceCopy.offerLine(modelState: manager.state, need: manager.spaceNeeded)
    }

    /// The offer takes the chapter line's place, so its text still opens
    /// Contents: chapters and search stay one tap away until the offer is
    /// answered.
    private func offerText(wraps: Bool) -> some View {
        Button(action: onOpenContents) {
            Text(line)
                .font(Theme.font(.subhead, scale: chromeScale))
                .foregroundStyle(Theme.text)
                // Never truncated: at its full width on one line (the row
                // only picks this form when that fits), else wrapped.
                .fixedSize(horizontal: !wraps, vertical: wraps)
                .multilineTextAlignment(.leading)
                .rowInk(rowAlignment)
                .frame(minHeight: 44, alignment: inkAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The player bar stops this row's type at the chips' cap.
        .largeContentViewerIfAvailable { Text(line) }
        .accessibilityHint("Opens contents and search")
        .accessibilityIdentifier("naturalVoice.offer")
    }

    private var buttons: some View {
        HStack(alignment: rowAlignment, spacing: Theme.Space.xs) {
            Button {
                // Checks the space again; still too little keeps the line.
                if manager.requestDownload(asker: promptAsker) == .needsCellularConfirmation {
                    isConfirmingCellular = true
                }
            } label: {
                // Text only, never filled: Play keeps the one accent fill.
                Text(NaturalVoiceCopy.download)
                    .font(Theme.font(.callout, scale: chromeScale).weight(.semibold))
                    .foregroundStyle(Theme.accentStrong)
                    .rowInk(rowAlignment)
                    .frame(minWidth: 44, minHeight: 44, alignment: inkAlignment)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .largeContentViewerIfAvailable { Text(NaturalVoiceCopy.download) }
            .accessibilityHint(NaturalVoiceCopy.privacyLine)
            .accessibilityInputLabels([Text("Download"), Text("Download natural voice")])
            .accessibilityIdentifier("naturalVoice.offer.download")

            Button {
                offer.notNow()
            } label: {
                Text(NaturalVoiceCopy.notNow)
                    .font(Theme.font(.callout, scale: chromeScale))
                    .foregroundStyle(Theme.textMuted)
                    .rowInk(rowAlignment)
                    .frame(minWidth: 44, minHeight: 44, alignment: inkAlignment)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .largeContentViewerIfAvailable { Text(NaturalVoiceCopy.notNow) }
            .accessibilityIdentifier("naturalVoice.offer.notNow")
        }
    }
}

extension View {
    /// The one metered-download confirmation (`ModelManager.cellularPrompt`).
    /// Every Download button that gets `.needsCellularConfirmation` presents
    /// this, and so does the manager's late `cellularQuestion` for `asker`,
    /// the id the button passed to `requestDownload(asker:)`.
    func naturalVoiceCellularPrompt(isPresented: Binding<Bool>, asker: UUID? = nil) -> some View {
        modifier(NaturalVoiceCellularPrompt(isPresented: isPresented, asker: asker))
    }
}

private struct NaturalVoiceCellularPrompt: ViewModifier {

    @EnvironmentObject private var manager: ModelManager

    @Binding var isPresented: Bool
    let asker: UUID?

    /// Asked now (the path was known at the tap), or by the first path
    /// for this surface. Any answer or dismissal clears both.
    private var isAsking: Binding<Bool> {
        let mine = ModelManager.CellularQuestion(asker: asker)
        return Binding(get: { isPresented || manager.cellularQuestion == mine },
                       set: { asking in
                           guard !asking else { return }
                           isPresented = false
                           if manager.cellularQuestion == mine { manager.clearCellularQuestion() }
                       })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(manager.cellularPrompt,
                                isPresented: isAsking,
                                titleVisibility: .visible) {
                Button(NaturalVoiceCopy.download) { manager.startDownload(allowingCellular: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(manager.cellularPromptMessage)
            }
    }
}
