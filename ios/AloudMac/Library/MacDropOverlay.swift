import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a valid drag over the window shows (mac-ux §2): a 2 pt accent inset
/// border around the content and the one label "Drop to add" in the middle.
/// Nothing at all otherwise; there is no "drop files here" caption, because
/// the border appears exactly when it matters. It never takes a click.
struct MacDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 2)
            .padding(Theme.Space.xs)
            .overlay { label }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.dropOverlay")
    }

    private var label: some View {
        Text("Drop to add")
            .font(Theme.font(.subhead))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth)
            )
    }
}

/// The window-wide drop target. It validates before it lights up: a drag
/// with no PDF or plain-text file gets the system's not-allowed cursor and
/// no border. A drop hands its file URLs, in the order dragged, to `onDrop`
/// (the intake), which leaves out anything else in a mixed drag.
struct MacFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: @MainActor ([URL]) -> Void

    /// A Finder drag names its files, not their types, so `hasItemsConforming`
    /// can't tell a PDF from a photo. The names on the drag pasteboard can,
    /// by the intake's own rule.
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
            && Self.draggedFileURLs().contains(where: MacFileIntake.isAddable)
    }

    /// The file URLs the drag in progress carries. Only their names are read;
    /// the files themselves open on the drop.
    private static func draggedFileURLs() -> [URL] {
        NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    /// A copy: the file stays where it was.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            onDrop(urls)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
