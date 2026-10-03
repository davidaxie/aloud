import AppKit

/// Aloud > About Aloud (M20, mac-ux §3.12): the standard About panel, with
/// the app's version and build, and Credits built from the Licenses page's
/// own text (`LicensesView`), so the iPhone's page and the Mac's panel can't
/// disagree. The Mac's Settings has no Licenses tab; the acknowledgements
/// live here.
///
/// The Credits follow the page: its opening line, then each component's
/// name, license and note, then the Classics' Project Gutenberg note, in
/// the Mac ramp's sizes with the page's weights. The colors are the
/// system's label colors: the panel draws its own ground, not paper, and a
/// run with no color would stay black in Dark Mode.
@MainActor
enum MacAboutCredits {

    /// The Aloud menu's first item, in the menus' title case. No key.
    static let menuTitle = MacMenuCopy.about

    /// Brings the panel forward (AppKit keeps one).
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
    }

    /// The Credits, and the version and build from `bundle`'s Info.plist.
    /// AppKit would read the same keys; named here, they're the ones shown.
    static func options(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits()]
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            options[.applicationVersion] = version
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            options[.version] = build
        }
        return options
    }

    /// The Credits, one centered paragraph per line of the Licenses page.
    static func credits() -> NSAttributedString {
        var paragraphs: [(text: String, part: Part)] = [(LicensesView.intro, .note)]
        for entry in LicensesView.entries {
            paragraphs += [(entry.id, .name), (entry.license, .license), (entry.detail, .note)]
        }
        paragraphs += [(LicensesView.classicsTitle, .name), (LicensesView.classicsNote, .note)]

        let credits = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let end = index < paragraphs.count - 1 ? "\n" : ""
            credits.append(NSAttributedString(string: paragraph.text + end, attributes: paragraph.part.attributes))
        }
        return credits
    }

    /// A line's part on the Licenses page, and how the page sets it: a
    /// semibold body name, a caption license, footnote notes.
    private enum Part {
        case name, license, note

        var attributes: [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            // A name opens a card.
            style.paragraphSpacingBefore = self == .name ? Theme.Space.sm : 0
            return [.font: font, .foregroundColor: color, .paragraphStyle: style]
        }

        private var font: NSFont {
            switch self {
            case .name: return .systemFont(ofSize: PlatformTypeRamp.basePoints(.body), weight: .semibold)
            case .license: return .monospacedDigitSystemFont(ofSize: PlatformTypeRamp.basePoints(.caption), weight: .medium)
            case .note: return .systemFont(ofSize: PlatformTypeRamp.basePoints(.footnote))
            }
        }

        /// The page's text and muted text.
        private var color: NSColor {
            self == .name ? .labelColor : .secondaryLabelColor
        }
    }
}
