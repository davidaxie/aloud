import SwiftUI
import XCTest
@testable import Aloud

/// Settings on the Mac (R21, M10, M17, mac-ux §3.12): exactly two tabs,
/// "Voice & speed" and "Text & appearance", each the same view a reader
/// popover holds, so each preference key is bound in one view, and no third
/// tab for licenses. The views are read through reflection: a view's
/// resolved `Body` type names what it holds, and its stored properties hold
/// any `@AppStorage` key. No window, no model, and no source files (a
/// sandboxed host can't read the checkout).
@MainActor
final class MacSettingsTests: XCTestCase {

    // MARK: - Two tabs

    func testExactlyTwoTabsWithTheSharedTitles() {
        XCTAssertEqual(MacSettingsTab.allCases, [.listening, .appearance])
        XCTAssertEqual(MacSettingsTab.allCases.map(\.title), [ListeningCopy.title, AppearanceCopy.title],
                       "the shared row titles, verbatim")
        XCTAssertEqual(MacSettingsTab.allCases.map(\.systemImage), ["waveform", "textformat.size"])
        XCTAssertEqual(MacSettingsTab.allCases.map(\.accessibilityIdentifier),
                       ["settings.tab.listening", "settings.tab.appearance"])
    }

    /// The window draws one page per tab, each once; licenses live in About
    /// Aloud, not in a third tab or inside a page.
    func testTheWindowHoldsEachPageOnceAndNoLicenses() {
        let window = Self.name(of: MacSettingsView.Body.self)
        XCTAssertFalse(window.hasPrefix("SwiftUI.AnyView"),
                       "bodies resolve to their own types (SWIFT_ENABLE_OPAQUE_TYPE_ERASURE stays off)")
        XCTAssertEqual(Self.count(MacSettingsVoiceTab.self, in: window), 1, window)
        XCTAssertEqual(Self.count(MacSettingsAppearanceTab.self, in: window), 1, window)
        for name in [window, Self.voicePage, Self.appearancePage] {
            XCTAssertEqual(Self.count(LicensesView.self, in: name), 0, "licenses are not a Settings tab")
        }
    }

    func testTheWindowIs500Wide() {
        XCTAssertEqual(MacSettingsView.width, 500)
        XCTAssertLessThan(MacSettingsAppearanceTab.columnWidth, MacSettingsView.width)
    }

    /// M17: the voice tab's one `ListeningView` keeps the natural-voice card
    /// in every state, installed too (size on disk, Remove Download…), so
    /// Michael can be installed before a flight; the privacy line closes
    /// the tab. Read from the tab's body (its `@State` at its seed value).
    func testTheVoiceTabShowsTheCardInEveryStateAndThePrivacyLine() {
        let body = MacSettingsVoiceTab().body
        let lists = Self.values(of: ListeningView.self, in: body)
        XCTAssertEqual(lists.count, 1, "one Listening view")
        let showsInstalled = lists.first.flatMap { list in
            Mirror(reflecting: list).children.first { $0.label == "showsInstalledModel" }?.value as? Bool
        }
        XCTAssertEqual(showsInstalled, true, "the card shows the installed state too")
        var visited = Set<ObjectIdentifier>()
        XCTAssertTrue(Self.strings(in: body, depth: 0, limit: 32, visited: &visited).contains(PrivacyCopy.line),
                      "the privacy line closes the tab")
    }

    /// The voice list fits its content and scrolls only past the cap.
    func testTheVoiceListFitsItsContentUpToTheCap() {
        XCTAssertEqual(MacSettingsVoiceTab.listHeight(content: 480), 480)
        XCTAssertEqual(MacSettingsVoiceTab.listHeight(content: 2000), MacSettingsVoiceTab.maxListHeight)
        XCTAssertEqual(MacSettingsVoiceTab.listHeight(content: -1), 0)
    }

    // MARK: - One home per preference

    /// Every preference the tabs hold, and the one view that binds it.
    private static let homes: [(key: String, view: Any.Type)] = [
        (AppModel.PrefKey.rate, ListeningView.self),
        (AppModel.PrefKey.voiceID, ListeningView.self),
        (AppModel.PrefKey.skipBrackets, ListeningView.self),
        (ReaderTextSize.prefKey, MacTextAppearanceView.self),
        (AppearancePreference.prefKey, MacTextAppearanceView.self),
        (AppModel.PrefKey.wordHighlight, MacTextAppearanceView.self),
    ]

    /// Each key's home view is in exactly one tab, once, and the other
    /// tab's view is not beside it.
    func testEachPreferenceKeyIsBoundInOneView() {
        XCTAssertEqual(Set(Self.homes.map(\.key)).count, Self.homes.count, "one home per key")
        for home in Self.homes {
            let tabs = [Self.voicePage, Self.appearancePage].map { Self.count(home.view, in: $0) }
            XCTAssertEqual(tabs.reduce(0, +), 1, "\(home.key): \(home.view) in one tab, once")
        }
        XCTAssertEqual(Self.count(ListeningView.self, in: Self.voicePage), 1)
        XCTAssertEqual(Self.count(MacTextAppearanceView.self, in: Self.appearancePage), 1)
    }

    /// R21: the reader's popovers hold the same views as the tabs, so a
    /// popover and Settings never bind a preference twice.
    func testThePopoversHoldTheSameViewsAsTheTabs() {
        let listening = Self.name(of: MacListeningPopover.Body.self)
        let appearance = Self.name(of: MacAppearancePopover.Body.self)
        XCTAssertEqual(Self.placements(of: ListeningView.self, in: listening), 1)
        XCTAssertEqual(Self.placements(of: MacTextAppearanceView.self, in: appearance), 1)
        XCTAssertEqual(Self.count(MacTextAppearanceView.self, in: listening), 0, "each popover hosts its own page only")
        XCTAssertEqual(Self.count(ListeningView.self, in: appearance), 0, "each popover hosts its own page only")
    }

    /// The `@AppStorage` keys are declared by their home alone. Settings,
    /// its pages and the popovers declare none and hold no binding of
    /// their own: they only host the views.
    func testOnlyTheHomeViewsDeclareStoredPreferences() {
        XCTAssertEqual(Self.preferenceKeys(in: MacTextAppearanceView()),
                       [ReaderTextSize.prefKey, AppearancePreference.prefKey])
        XCTAssertEqual(Self.preferenceKeys(in: ListeningView(showsInstalledModel: true)), [],
                       "voice, speed and asides go through the shared PlaybackController")
        let hosts: [Any] = [MacSettingsView(), MacSettingsVoiceTab(), MacSettingsAppearanceTab(),
                            MacListeningPopover(), MacAppearancePopover()]
        for host in hosts {
            XCTAssertEqual(Self.preferenceKeys(in: host), [], "\(type(of: host)) declares no preference")
            XCTAssertEqual(Self.preferenceWrappers(in: host), [], "\(type(of: host)) binds no preference")
        }
    }

    // MARK: - Reflection

    private static var voicePage: String { name(of: MacSettingsVoiceTab.Body.self) }
    private static var appearancePage: String { name(of: MacSettingsAppearanceTab.Body.self) }

    /// A type's runtime name, with an opaque `some View` body resolved:
    /// "SwiftUI.ModifiedContent<SwiftUI.VStack<…Aloud.ListeningView…>>".
    private static func name(of type: Any.Type) -> String {
        String(reflecting: type)
    }

    /// How many times `type` appears in a type's name, as a whole type.
    private static func count(_ type: Any.Type, in name: String) -> Int {
        let needle = String(reflecting: type)
        return name.components(separatedBy: CharacterSet(charactersIn: "<>,() ")).filter { $0 == needle }.count
    }

    /// How many places hold `type` in a body that may sit under
    /// `.presentationBackground`: that modifier wraps its content in a
    /// StaticIf whose two branches each spell it out, only one of them
    /// live, so a view placed once is named once per branch. -1 when the
    /// branches disagree.
    private static func placements(of type: Any.Type, in name: String) -> Int {
        let branches = name.hasPrefix("SwiftUI.StaticIf<") ? 2 : 1
        let total = count(type, in: name)
        return total % branches == 0 ? total / branches : -1
    }

    /// The `aloud.prefs.` keys among a view's stored properties, however
    /// deep: an `@AppStorage` keeps its key inside.
    private static func preferenceKeys(in view: Any) -> Set<String> {
        var visited = Set<ObjectIdentifier>()
        return Set(strings(in: view, depth: 0, visited: &visited).filter { $0.hasPrefix("aloud.prefs.") })
    }

    /// Every string among a value's stored properties, `limit` levels deep
    /// (a body's modifier chain runs deeper than a view's own properties).
    private static func strings(in value: Any, depth: Int, limit: Int = 12,
                                visited: inout Set<ObjectIdentifier>) -> [String] {
        guard depth < limit else { return [] }
        if let string = value as? String { return [string] }
        if type(of: value) is AnyClass {
            guard visited.insert(ObjectIdentifier(value as AnyObject)).inserted else { return [] }
        }
        var found: [String] = []
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            for child in current.children {
                found += strings(in: child.value, depth: depth + 1, limit: limit, visited: &visited)
            }
            mirror = current.superclassMirror
        }
        return found
    }

    /// Every `T` in a view value's tree of structs: a body's views, through
    /// its modifiers and stacks. Classes are not entered.
    private static func values<T>(of type: T.Type, in value: Any, depth: Int = 0) -> [T] {
        if let match = value as? T { return [match] }
        guard depth < 32, !(Swift.type(of: value) is AnyClass) else { return [] }
        return Mirror(reflecting: value).children.flatMap { values(of: type, in: $0.value, depth: depth + 1) }
    }

    /// A view's own `@AppStorage` and `Binding` properties, by label.
    private static func preferenceWrappers(in view: Any) -> [String] {
        Mirror(reflecting: view).children.compactMap { child in
            let typeName = String(describing: type(of: child.value))
            guard typeName.hasPrefix("AppStorage<") || typeName.hasPrefix("Binding<") else { return nil }
            return child.label ?? typeName
        }
    }
}
