import Foundation

/// How the listener's speed is shared between the voice and the time-pitch
/// unit. Stretching a 1x clip three times smears it (the "muffled" sound at
/// 2.95x); Kokoro speaking faster itself changes its articulation instead.
/// Measured clearest (MacNativeSpeedClarityTests, offline, against the 1x
/// clip's spectrum): about an even split, Kokoro taking a little over the
/// square root of the speed-up (at 2.95x, asking for 2x beat 1.75x) and the
/// time-pitch unit the rest, at its highest overlap. Below about 1.15x the
/// time-pitch unit alone is clearer.
///
/// Kokoro rounds each sound to whole frames and keeps a floor, so asked for
/// 2x a clip is only about 1.8x shorter, and by how much depends on the
/// voice: `compression` is measured per voice, and each clip carries it
/// (`SynthesizedAudio.nativeSpeed`), so the time-pitch unit plays exactly
/// the rest and 2.95x stays 2.95x.
enum NativeSpeed {

    /// The paces Kokoro is asked for.
    static let tiers: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

    /// Kokoro's share of the speed-up, as an exponent: 0.5 is an even split.
    static let splitExponent = 0.55

    /// The time-pitch unit's overlap (3...32): more overlapping analysis
    /// windows, fewer artifacts. Its cost is small next to synthesis.
    static let timePitchOverlap: Float = 32

    /// The pace to ask Kokoro for at `rate`: the tier whose typical
    /// compression is nearest `rate` to the power `splitExponent`; the
    /// System voice always speaks at its own pace.
    static func tier(for rate: Double, engine: EngineKind) -> Double {
        guard engine == .kokoro, rate.isFinite else { return 1.0 }
        let wanted = pow(max(rate, 1.0), splitExponent)
        return tiers.min { abs(typical(at: $0) - wanted) < abs(typical(at: $1) - wanted) } ?? 1.0
    }

    /// How much shorter `voiceID`'s clips are at pace `speed` than at 1x
    /// (1x length over native length), interpolated between measured paces.
    static func compression(speed: Double, voiceID: String) -> Double {
        guard speed.isFinite, speed > 1.0 else { return max(speed.isFinite ? speed : 1.0, 0.1) }
        let table = measured[voiceID] ?? typicalTable
        return interpolate(speed, table)
    }

    /// The cache key's pace component: clips made at different paces never
    /// stand in for each other.
    static func keyComponent(_ speed: Double) -> String {
        "x" + String(Int((speed * 100).rounded()))
    }

    // MARK: - Measured

    /// 1x length over native length at 1.25, 1.5, 1.75 and 2.0, per voice:
    /// MacNativeSpeedClarityTests.testNativeSpeedCompression, 16 sentences
    /// of two bundled classics, the pinned model, Oct 6 2026.
    static let measured: [String: [Double]] = [
        "kokoro:am_michael": [1.203, 1.565, 1.704, 1.858],
        "kokoro:aloud_velvet": [1.186, 1.551, 1.671, 1.821],
        "kokoro:aloud_anchor": [1.182, 1.552, 1.677, 1.787],
        "kokoro:aloud_ember": [1.183, 1.552, 1.690, 1.828],
        "kokoro:am_fenrir": [1.187, 1.526, 1.639, 1.767],
        "kokoro:am_puck": [1.182, 1.493, 1.600, 1.726],
        "kokoro:af_heart": [1.177, 1.522, 1.628, 1.736],
        "kokoro:af_bella": [1.178, 1.533, 1.649, 1.798],
        "kokoro:af_nicole": [1.218, 1.573, 1.740, 1.962],
        "kokoro:af_sarah": [1.169, 1.519, 1.647, 1.780],
        "kokoro:bf_emma": [1.158, 1.508, 1.596, 1.689],
    ]

    private static let measuredSpeeds: [Double] = [1.25, 1.5, 1.75, 2.0]

    /// The mean of the measured voices, for a voice the table doesn't name.
    static let typicalTable: [Double] = {
        let rows = Array(measured.values)
        guard !rows.isEmpty else { return measuredSpeeds }
        return measuredSpeeds.indices.map { index in rows.reduce(0) { $0 + $1[index] } / Double(rows.count) }
    }()

    private static func typical(at speed: Double) -> Double {
        speed > 1.0 ? interpolate(speed, typicalTable) : 1.0
    }

    /// Piecewise linear through (1, 1) and the measured paces; past the last
    /// one, along the last segment's slope.
    private static func interpolate(_ speed: Double, _ table: [Double]) -> Double {
        let xs = [1.0] + measuredSpeeds, ys = [1.0] + table
        guard xs.count == ys.count else { return speed }
        var index = 1
        while index < xs.count - 1, speed > xs[index] { index += 1 }
        let (x0, x1, y0, y1) = (xs[index - 1], xs[index], ys[index - 1], ys[index])
        return y0 + (speed - x0) * (y1 - y0) / (x1 - x0)
    }
}
