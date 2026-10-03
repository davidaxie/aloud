import SwiftUI

/// The Settings window (⌘,): "Voice & speed" and "Text & appearance" tabs,
/// 500 wide on the paper (contracts §6). A phase-1 stub with a frozen
/// signature: the paper at the window's width, until the settings slice
/// fills it.
struct MacSettingsView: View {
    var body: some View {
        Theme.bg
            .frame(width: 500, height: 320)
    }
}
