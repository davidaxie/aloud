import SwiftUI

/// Static licenses & acknowledgements page (pushed from Settings).
struct LicensesView: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // The page's text is internal, not private: the Mac's About Aloud builds
    // its Credits from it (`MacAboutCredits`), so the two can't disagree.
    struct Entry: Identifiable {
        let id: String        // component name
        let license: String
        let detail: String
    }

    static let intro = "Aloud is built on open-source software."

    static let entries: [Entry] = [
        Entry(id: "sherpa-onnx",
              license: "Apache License 2.0",
              detail: "On-device neural text-to-speech runtime by the k2-fsa "
                    + "project. Copyright the sherpa-onnx contributors."),
        Entry(id: "ONNX Runtime",
              license: "MIT License",
              detail: "Cross-platform inference engine. "
                    + "Copyright (c) Microsoft Corporation."),
        // R25: the privacy promise lives only in the Settings footer (and the
        // empty state), so this card states facts, not a second promise.
        Entry(id: "Kokoro voice model",
              license: "Apache License 2.0",
              detail: "kokoro-multi-lang-v1_0 neural speech model, downloaded on request. "
                    + "Velvet, Anchor and Ember are Aloud's own mixes of its voices."),
        // "natural voice" is the user's word for Kokoro everywhere else.
        Entry(id: "espeak-ng",
              license: "GPL-3.0",
              detail: "Grapheme-to-phoneme engine used by the natural voice. "
                    + "Aloud bundles espeak-ng phoneme data and links the "
                    + "espeak-ng library via sherpa-onnx; the corresponding "
                    + "source is available from the espeak-ng project."),
    ]

    static let classicsTitle = "Bundled classics"
    // R25: the screen users know is titled Classics; "bookshelf" is a code
    // name, never copy.
    static let classicsNote = "The Classics are public-domain texts from Project "
        + "Gutenberg (gutenberg.org), lightly formatted for "
        + "listening. Project Gutenberg is a registered "
        + "trademark; the texts themselves are free of U.S. "
        + "copyright."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text(Self.intro)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(Theme.textMuted)

                ForEach(Self.entries) { entry in
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        nameAndLicense(for: entry)
                        Text(entry.detail)
                            .font(Theme.font(.footnote))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .modifier(LicenseCard())
                }

                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(Self.classicsTitle)
                        .font(Theme.font(.body).weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(Self.classicsNote)
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(LicenseCard())
            }
            .padding(Theme.Space.screenGutter)
        }
        .shelfScrollEdge(ground: Theme.bgTint)
        .background(Theme.bgTint.ignoresSafeArea())
        .inlineTitleOnPhone()
        // The bar's system content (back chevron, title rendering) follows
        // the app's scheme, not the phone's: under an in-app Dark override
        // on a Light phone it otherwise drew dark-on-dark.
        .toolbarColorSchemeOnPhone(colorScheme)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Licenses")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    // The bar caps text scaling; at accessibility sizes a
                    // long press shows the title large instead.
                    .largeContentViewerIfAvailable()
            }
        }
    }

    /// Component name with its license badge trailing — or, at accessibility
    /// sizes, the badge on its own line under the name: side by side, the
    /// two split the card's width and wrapped a character per line at AX5.
    @ViewBuilder
    private func nameAndLicense(for entry: Entry) -> some View {
        let name = Text(entry.id)
            .font(Theme.font(.body).weight(.semibold))
            .foregroundStyle(Theme.text)
        let license = Text(entry.license)
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.accentStrong)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                name
                license
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                name
                Spacer()
                license
            }
        }
    }
}

/// One acknowledgement card: surface ground, continuous corners, 1 pt border.
private struct LicenseCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        content
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.Stroke.borderColor,
                                        lineWidth: Theme.Stroke.borderWidth))
    }
}
