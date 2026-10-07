import AppKit
import SwiftUI

/// The Settings window (⌘, and Aloud > Settings…; R21, M10, M17, mac-ux
/// §3.12): exactly two toolbar tabs, each the same view a reader popover
/// holds, so every preference keeps one home. "Voice & speed" is the shared
/// `ListeningView` with the natural-voice card in every state, so Michael
/// can be installed before a flight, closed by the privacy line; "Text &
/// appearance" is `MacTextAppearanceView`. 500 wide, each tab's height
/// fitting its content, on the paper in light and dark (`MacAppearance`
/// sets `NSApp.appearance`, which reaches this window too).
///
/// Keyboard: the tabs are the window's toolbar items, and every control in
/// a tab is a system or shared control in the window's key view loop, so
/// Tab walks it under keyboard navigation. No tab-switching keys of its own:
/// every key comes from the one `MacShortcuts` table.
///
/// Licenses and the version are not here. On the Mac they belong to Aloud >
/// About Aloud, whose Credits are built from the `LicensesView` text
/// (mac-ux §3.12; `MacAboutCredits`, phase 4), so there is no third tab.
struct MacSettingsView: View {

    static let width: CGFloat = 500

    @State private var selection = MacSettingsTab.listening

    var body: some View {
        TabView(selection: $selection) {
            ForEach(MacSettingsTab.allCases) { tab in
                page(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(width: Self.width)
        .modifier(MacWindowPaper())
        .background(MacSettingsWindowConfigurator())
    }

    @ViewBuilder
    private func page(for tab: MacSettingsTab) -> some View {
        switch tab {
        case .listening: MacSettingsVoiceTab()
        case .appearance: MacSettingsAppearanceTab()
        }
    }
}

/// The two tabs, in toolbar order, with the shared row titles verbatim.
enum MacSettingsTab: String, CaseIterable, Identifiable {
    case listening, appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .listening: return ListeningCopy.title
        case .appearance: return AppearanceCopy.title
        }
    }

    var systemImage: String {
        switch self {
        case .listening: return "waveform"
        case .appearance: return "textformat.size"
        }
    }

    /// The tab's page, as UI tests find it.
    var accessibilityIdentifier: String { "settings.tab.\(rawValue)" }
}

/// "Voice & speed": the shared Listening view, with the natural-voice card
/// shown installed too (size on disk, Remove Download…), as the iPhone's
/// Settings page shows it. The list fits its content up to a cap and
/// scrolls beyond, which only the eleven installed voices reach; the privacy
/// line sits below it, so it closes the tab however the list scrolls.
struct MacSettingsVoiceTab: View {

    /// The list's tallest: with the window's toolbar and the privacy line,
    /// the tab still fits a 1280 × 800 display. The not-installed list
    /// (the card with its before-you-fly line, the System row and "Add
    /// voices in System Settings…") fits under it unscrolled.
    static let maxListHeight: CGFloat = 600

    /// Seeded near the not-installed layout so the first frame barely moves.
    @State private var contentHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            MacSettingsHairline()
            ListeningView(showsInstalledModel: true, onContentHeight: { contentHeight = $0 })
                .frame(height: Self.listHeight(content: contentHeight))
            Text(PrivacyCopy.line)
                .font(Theme.font(.aside))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.lg)
                .accessibilityIdentifier("settings.privacy")
        }
        .frame(width: MacSettingsView.width)
        .background(Theme.bg)
        // No neutral gray behind any scrolling content.
        .scrollContentBackground(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MacSettingsTab.listening.accessibilityIdentifier)
    }

    /// The list's height: its content, up to the cap.
    static func listHeight(content: CGFloat) -> CGFloat {
        max(min(content, maxListHeight), 0)
    }
}

/// "Text & appearance": the Aa popover's three controls, in a column
/// centered in the window rather than stretched across it.
struct MacSettingsAppearanceTab: View {

    static let columnWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            MacSettingsHairline()
            MacTextAppearanceView()
                .frame(width: Self.columnWidth)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity)
        }
        .frame(width: MacSettingsView.width)
        .background(Theme.bg)
        .scrollContentBackground(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MacSettingsTab.appearance.accessibilityIdentifier)
    }
}

/// The rule under the tabs. The window draws no titlebar separator; Aloud
/// draws its own hairline, as the main window does.
private struct MacSettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .hairlineHeight()
            .accessibilityHidden(true)
    }
}

/// The Settings window's AppKit side, `MacWindowConfigurator`'s counterpart:
/// paper behind the tabs from the first frame, no titlebar separator, no
/// window tabs, and the identifier UI tests find it by. It leaves the size
/// to the scene, which fits each tab.
struct MacSettingsWindowConfigurator: NSViewRepresentable {

    /// What UI tests find the window by.
    static let accessibilityIdentifier = "aloud.window.settings"

    func makeNSView(context: Context) -> MacWindowConfigurator.WindowAccessorView {
        let view = MacWindowConfigurator.WindowAccessorView()
        view.onWindow = { window in Self.configure(window) }
        return view
    }

    func updateNSView(_ view: MacWindowConfigurator.WindowAccessorView, context: Context) {}

    @MainActor
    static func configure(_ window: NSWindow) {
        window.setAccessibilityIdentifier(accessibilityIdentifier)
        window.backgroundColor = NSColor(Theme.bg)
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
    }
}
