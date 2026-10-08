import Foundation

/// The app's one voice and speed formatter. The player chip, the Listening
/// sheet, Settings and the accessibility identifiers all format through here,
/// so "1.25×" and "Michael" read the same on every surface.
enum ListeningFormat {

    /// "1×", "1.25×", "2.5×": to the hundredth, no trailing zeros.
    static func rate(_ rate: Double) -> String {
        ((rate * 100).rounded() / 100).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// "1", "1.25", "2.5": locale-free, for accessibility identifiers.
    static func identifierNumber(_ rate: Double) -> String {
        String(format: "%g", rate)
    }

    /// The first word of the voice's name: "Michael", "System".
    static func shortName(_ voice: TtsVoice) -> String {
        voice.name.split(separator: " ").first.map(String.init) ?? voice.name
    }

    /// The player chip: "Michael · 1.25×".
    static func chipTitle(voice: TtsVoice, rate: Double) -> String {
        "\(shortName(voice)) · \(Self.rate(rate))"
    }

    /// The player chip where its full title can't fit beside the transport:
    /// the speed alone, "2.25×". The chip's spoken label still names the
    /// voice.
    static func chipShortTitle(rate: Double) -> String {
        Self.rate(rate)
    }
}

/// The speed control's scale: range, step, the magnetic 1× detent and the
/// presets (R8).
enum SpeedScale {
    static let range: ClosedRange<Double> = 0.5...3.0
    static let step: Double = 0.05
    static let detentRadius: Double = 0.04
    static let presets: [Double] = [1, 1.25, 1.5, 2, 2.5]

    /// Clamped to `range`; within ±`detentRadius` of 1.0 lands on 1.0;
    /// otherwise the nearest 0.05 step.
    static func snap(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        // The epsilon keeps the detent inclusive: 1.04 - 1.0 is a hair over
        // 0.04 in binary floating point.
        if abs(clamped - 1.0) <= detentRadius + 1e-9 { return 1.0 }
        return (clamped * 20).rounded() / 20   // 20 steps of 0.05 per 1×
    }

    static func isSelected(_ preset: Double, at rate: Double) -> Bool {
        abs(rate - preset) < 0.001
    }

    /// True when a speed change arrives at 1× from elsewhere: the detent's
    /// one tick (R20). Holding on 1× or leaving it is silent.
    static func landsOnDetent(from old: Double, to new: Double) -> Bool {
        isSelected(1, at: new) && !isSelected(1, at: old)
    }
}
