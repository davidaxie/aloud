import Foundation
#if os(iOS)
import UIKit
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
    #endif
}
