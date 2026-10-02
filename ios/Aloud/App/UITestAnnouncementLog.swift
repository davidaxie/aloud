#if DEBUG
import Combine
import Foundation

/// Every VoiceOver announcement PlaybackController makes, posted or muted,
/// so UI tests (always muted) can assert what VoiceOver would have said.
/// DEBUG only; the debug.announcements probe reads it.
@MainActor
final class UITestAnnouncementLog: ObservableObject {

    static let shared = UITestAnnouncementLog()

    private static let capacity = 50

    @Published private(set) var entries: [String] = []

    func record(_ text: String) {
        entries.append(text)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func reset() {
        entries = []
    }
}
#endif
