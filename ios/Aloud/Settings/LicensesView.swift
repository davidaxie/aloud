import SwiftUI

/// Static licenses & acknowledgements page (pushed from Settings → About).
struct LicensesView: View {

    private struct Entry: Identifiable {
        let id: String        // component name
        let license: String
        let detail: String
    }

    private static let entries: [Entry] = [
        Entry(id: "sherpa-onnx",
              license: "Apache License 2.0",
              detail: "On-device neural text-to-speech runtime by the k2-fsa "
                    + "project. Copyright the sherpa-onnx contributors."),
        Entry(id: "ONNX Runtime",
              license: "MIT License",
              detail: "Cross-platform inference engine. "
                    + "Copyright (c) Microsoft Corporation."),
        Entry(id: "Kokoro voice model",
              license: "Apache License 2.0",
              detail: "kokoro-multi-lang-v1_0 neural speech model, downloaded "
                    + "on request and stored on this device only."),
        Entry(id: "espeak-ng",
              license: "GPL-3.0",
              detail: "Grapheme-to-phoneme engine used by the neural voice. "
                    + "Aloud bundles espeak-ng phoneme data and links the "
                    + "espeak-ng library via sherpa-onnx; the corresponding "
                    + "source is available from the espeak-ng project."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Aloud is built on open-source software.")
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.textMuted)

                ForEach(Self.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.id)
                                .font(Theme.ui(16, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(entry.license)
                                .font(Theme.ui(12, weight: .medium))
                                .foregroundStyle(Theme.accentStrong)
                        }
                        Text(entry.detail)
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.line, lineWidth: 0.5))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundled classics")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("The classic books on the bookshelf are public-domain "
                       + "texts from Project Gutenberg (gutenberg.org), lightly "
                       + "formatted for listening. Project Gutenberg is a "
                       + "registered trademark; the texts themselves are free "
                       + "of U.S. copyright.")
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.line, lineWidth: 0.5))
            }
            .padding(20)
        }
        .background(Theme.bgTint.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Licenses")
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}
