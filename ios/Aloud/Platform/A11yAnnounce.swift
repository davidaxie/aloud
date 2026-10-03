import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A VoiceOver announcement. Callers keep their own `muted` guard and the
/// DEBUG `UITestAnnouncementLog` record; this only speaks. (S3)
@MainActor
enum A11yAnnounce {
    #if os(iOS)
    /// Queued by default, so an announcement never cuts off what VoiceOver
    /// is already saying.
    static func post(_ text: String, queued: Bool = true) {
        UIAccessibility.post(notification: .announcement,
                             argument: argument(for: text, queued: queued))
    }

    /// The announcement's payload, apart so a test can pin it.
    static func argument(for text: String, queued: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .accessibilitySpeechQueueAnnouncement: queued,
        ])
    }
    #elseif os(macOS)
    /// Asked of the main window (the app when none is up). Medium priority
    /// waits behind what VoiceOver is saying; high (not queued) cuts in.
    ///
    /// A muted process never speaks, whatever its caller checked:
    /// VoiceOver reads an announcement aloud through the Mac's own output,
    /// and a muted Debug launch or test host shares that output with the
    /// user. The callers' `UITestAnnouncementLog` record is all it leaves.
    static func post(_ text: String, queued: Bool = true) {
        guard !UITestHooks.muteAudio, let app = NSApp else { return }
        let element: NSResponder = app.mainWindow ?? app
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: userInfo(for: text, queued: queued))
        #if DEBUG
        postedCount += 1
        #endif
    }

    /// The announcement's payload, apart so a test can pin it.
    static func userInfo(for text: String, queued: Bool) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        let priority: NSAccessibilityPriorityLevel = queued ? .medium : .high
        return [.announcement: text, .priority: priority.rawValue]
    }

    #if DEBUG
    /// How many announcements reached VoiceOver in this process: 0 in a
    /// muted one.
    private(set) static var postedCount = 0
    #endif
    #endif
}
