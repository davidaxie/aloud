import UIKit

/// Shared, pre-prepared transport feedback: a light impact for play/pause
/// and sentence steps, selection ticks for scrub-drag sentence changes and
/// speed presets. The system gates haptics behind the hardware and
/// accessibility settings, so callers fire unconditionally — but only ever
/// from direct user actions, never from programmatic state changes.
@MainActor
enum TransportHaptics {

    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    /// Keeps the Taptic Engine warm ahead of imminent feedback (drag start).
    static func prepare() {
        impact.prepare()
        selection.prepare()
    }

    /// Light impact: play/pause tap, sentence step.
    static func tap() {
        impact.impactOccurred()
        impact.prepare()
    }

    /// Selection tick: scrub-drag sentence change, speed-preset tap.
    static func selectionChanged() {
        selection.selectionChanged()
        selection.prepare()
    }
}
