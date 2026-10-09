import SwiftUI

/// The Licenses page's own copy, beside the entries' text.
enum LicensesCopy {

    /// What a card's push row speaks (R3-18): the license it shows, then
    /// whose it is, as two components share the Apache text and the row
    /// would otherwise speak the same as its twin.
    static func licenseRowLabel(for entry: LicensesView.Entry) -> String {
        "\(entry.license), \(entry.id)"
    }

    /// The push row's Voice Control names: the component's license first,
    /// so each card's row answers to a name no other row has, then the
    /// license as shown.
    static func licenseRowInputLabels(for entry: LicensesView.Entry) -> [String] {
        ["\(entry.id) license", entry.license]
    }

    /// A source row: the link's host and path, no scheme.
    static func source(_ url: URL) -> String {
        "Source \u{00B7} " + shortForm(of: url)
    }

    /// `url` as the row shows it: host and path, without the scheme or a
    /// trailing slash.
    static func shortForm(of url: URL) -> String {
        var text = (url.host ?? "") + url.path
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Static licenses & acknowledgements page (pushed from Settings).
///
/// Each component's card keeps its name, its one heading, and its note,
/// and at its foot, below a hairline, a row named for its license that
/// pushes the full text (bundled under Resources/Licenses, pushed as
/// `LicenseTextView`) and a real link to the component's source, marked as
/// leaving the app: the only accent text on the page (R3-18).
struct LicensesView: View {

    @Environment(\.colorScheme) private var colorScheme

    // The page's text is internal, not private: the Mac's About Aloud builds
    // its Credits from it (`MacAboutCredits`), so the two can't disagree.
    struct Entry: Identifiable {
        let id: String        // component name
        let license: String
        let detail: String
        /// Where the component's source lives.
        let source: URL
        /// The license's full text, a .txt in the bundle's Licenses folder.
        let textResource: String?
    }

    /// The bundle folder the license texts ship in (project.yml, both apps).
    static let licensesFolder = "Licenses"

    /// `entry`'s bundled license text, nil when it has none or it's missing.
    static func licenseTextURL(for entry: Entry, in bundle: Bundle = .main) -> URL? {
        guard let name = entry.textResource else { return nil }
        return bundle.url(forResource: name, withExtension: "txt", subdirectory: licensesFolder)
    }

    static let intro = "Aloud is built on open-source software."

    // A non-breaking hyphen keeps the project's name on one line; one
    // Apache text covers sherpa-onnx and the Kokoro model.
    static let entries: [Entry] = [
        Entry(id: "sherpa-onnx",
              license: "Apache License 2.0",
              detail: "On-device neural text-to-speech runtime by the k2\u{2011}fsa "
                    + "project. Copyright the sherpa-onnx contributors.",
              source: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!,
              textResource: "Apache-2.0"),
        Entry(id: "ONNX Runtime",
              license: "MIT License",
              detail: "Cross-platform inference engine. "
                    + "Copyright \u{00A9} Microsoft Corporation.",
              source: URL(string: "https://github.com/microsoft/onnxruntime")!,
              textResource: "onnxruntime-MIT"),
        // R25: the privacy promise lives only in the Settings footer (and the
        // empty state), so this card states facts, not a second promise.
        // Its source is the export the app downloads (ModelManager).
        Entry(id: "Kokoro voice model",
              license: "Apache License 2.0",
              detail: "kokoro-multi-lang-v1_0 neural speech model, downloaded on request. "
                    + "Velvet, Anchor and Ember are Aloud\u{2019}s own mixes of its voices.",
              source: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0")!,
              textResource: "Apache-2.0"),
        // "natural voice" is the user's word for Kokoro everywhere else.
        Entry(id: "espeak-ng",
              license: "GPL-3.0",
              detail: "Grapheme-to-phoneme engine used by the natural voice. "
                    + "Aloud bundles espeak-ng phoneme data and links the "
                    + "espeak-ng library via sherpa-onnx; the corresponding "
                    + "source is available at github.com/espeak-ng/espeak-ng.",
              source: URL(string: "https://github.com/espeak-ng/espeak-ng")!,
              textResource: "espeak-ng-GPL-3.0"),
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
                        cardHeading(for: entry)
                        Text(entry.detail)
                            .font(Theme.font(.footnote))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        cardFoot(for: entry)
                    }
                    .modifier(LicenseCard())
                }

                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(Self.classicsTitle)
                        .font(Theme.font(.body).weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
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
                    .accessibilityAddTraits(.isHeader)
                    // The bar caps text scaling; at accessibility sizes a
                    // long press shows the title large instead.
                    .largeContentViewerIfAvailable()
            }
        }
    }

    /// The component's name alone (R3-18): the license is named once, by
    /// the row that pushes its text. Each card's name is a heading, so the
    /// rotor steps card to card.
    private func cardHeading(for entry: Entry) -> some View {
        Text(entry.id)
            .font(Theme.font(.body).weight(.semibold))
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(.isHeader)
    }
}

extension LicensesView {

    /// Below a hairline, the license's text and the source: two full-width
    /// 44 pt rows. The first is named for its license, in plain text with a
    /// chevron, as it pushes a page; only the source is accent, as a real
    /// link, with the faint arrow that says it leaves the app (R3-18).
    @ViewBuilder
    func cardFoot(for entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.Stroke.borderColor)
                .frame(height: Theme.Stroke.borderWidth)
                .padding(.vertical, Theme.Space.xs)
                .accessibilityHidden(true)
            if entry.textResource != nil {
                NavigationLink {
                    LicenseTextView(entry: entry)
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Text(entry.license)
                            .font(Theme.font(.subhead))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: Theme.Space.xs)
                        Image(systemName: "chevron.right")
                            .font(Theme.font(.footnote).weight(.semibold))
                            .foregroundStyle(Theme.textFaint)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Two cards share the Apache text: the row names whose it is,
                // so VoiceOver and Voice Control tell the two apart.
                .accessibilityLabel(LicensesCopy.licenseRowLabel(for: entry))
                .accessibilityInputLabels(LicensesCopy.licenseRowInputLabels(for: entry).map { Text($0) })
                .accessibilityIdentifier("licenses.text.\(entry.id)")
            }
            // No hint names a browser: the default one may be any.
            Link(destination: entry.source) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Text(LicensesCopy.source(entry.source))
                        .font(Theme.font(.subhead))
                        .foregroundStyle(Theme.accentStrong)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.xs)
                    // Faint, not accent: the address is the page's one
                    // link-coloured text.
                    Image(systemName: "arrow.up.forward")
                        .font(Theme.font(.footnote).weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("licenses.source.\(entry.id)")
        }
    }
}

/// One license's full text, pushed from its card: the component's name as
/// the bar's heading, the text in footnote on the Licenses page's bgTint,
/// selectable. The file's hard line breaks are reflowed into paragraphs
/// (`LicenseText.paragraphs(of:)`), so the column wraps it, not the file.
struct LicenseTextView: View {

    let entry: LicensesView.Entry

    @Environment(\.colorScheme) private var colorScheme
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(Theme.Space.screenGutter)
        }
        .shelfScrollEdge(ground: Theme.bgTint)
        .background(Theme.bgTint.ignoresSafeArea())
        .inlineTitleOnPhone()
        .toolbarColorSchemeOnPhone(colorScheme)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(entry.id)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("licenses.text.title")
                    .largeContentViewerIfAvailable()
            }
        }
        .task(id: entry.id) {
            guard let url = LicensesView.licenseTextURL(for: entry),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            paragraphs = LicenseText.paragraphs(of: text)
        }
    }
}

/// A plain-text license as paragraphs: split at blank lines, each
/// paragraph's hard-wrapped lines joined with a space.
enum LicenseText {
    static func paragraphs(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { block in
                block.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
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
