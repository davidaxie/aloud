import Foundation

/// Changes the speed of speech without changing its pitch, in the time
/// domain, one pitch period at a time (pitch-synchronous overlap-add, the
/// approach of Bill Cox's Sonic library for speech).
///
/// AVAudioUnitTimePitch works in the frequency domain: on a voice it leaves
/// a faint metallic ring, more so the further it stretches. Speech is mostly
/// voiced and periodic, so it can instead be sped up by finding the pitch
/// period and blending two periods into one (or slowed down by blending one
/// into two). Nothing is resynthesized, so nothing rings: each sentence is
/// stretched once, off the main thread, before it is scheduled.
///
/// Pure and deterministic; mono Float samples in, mono Float samples out.
enum SpeechStretcher {

    /// `clip` sped up by `speed` in the time domain, its `nativeSpeed`
    /// multiplied by what the stretch achieved (the lengths say exactly),
    /// so playback's wall-time math and the time-pitch unit's remainder
    /// stay true.
    static func stretch(_ clip: SynthesizedAudio, speed: Double) -> SynthesizedAudio {
        let samples = stretch(clip.samples, sampleRate: clip.sampleRate, speed: speed)
        guard samples.count != clip.samples.count, !samples.isEmpty else { return clip }
        let achieved = Double(clip.samples.count) / Double(samples.count)
        return SynthesizedAudio(samples: samples, sampleRate: clip.sampleRate,
                                nativeSpeed: clip.nativeSpeed * achieved)
    }

    /// Voices from 65 Hz (a low male voice) to 400 Hz (a child's).
    static let minPitch = 65.0
    static let maxPitch = 400.0
    /// The pitch search runs on a 4 kHz copy, then refines at full rate.
    private static let searchRate = 4_000.0

    /// `samples` played `speed` times as fast (2 = half as long), the pitch
    /// unchanged. A speed within 0.2% of 1, or a clip too short to hold two
    /// of the longest pitch periods, comes back as it was: the caller reads
    /// the achieved speed from the lengths.
    static func stretch(_ samples: [Float], sampleRate: Double, speed: Double) -> [Float] {
        guard speed.isFinite, speed > 0, abs(speed - 1) > 0.002, sampleRate > 0 else { return samples }
        let minPeriod = max(2, Int(sampleRate / maxPitch))
        let maxPeriod = max(minPeriod + 1, Int(sampleRate / minPitch))
        let maxRequired = 2 * maxPeriod
        guard samples.count > maxRequired else { return samples }

        let skip = max(1, Int(sampleRate / searchRate))
        // Each pass keeps every output piece a whole pitch period long only
        // between 0.5x and 2x: beyond, two passes of the square root.
        let passes = speed >= 2 || speed <= 0.5 ? 2 : 1
        let step = passes == 2 ? speed.squareRoot() : speed
        var output = samples
        for _ in 0..<passes where output.count > maxRequired {
            output = output.withUnsafeBufferPointer { (input: UnsafeBufferPointer<Float>) -> [Float] in
                process(input, speed: step, minPeriod: minPeriod, maxPeriod: maxPeriod, skip: skip)
            }
        }
        return exactLength(output, for: samples.count, speed: speed)
    }

    /// The overlap-add pass over `input`, one pitch period at a time, for a
    /// speed between 0.5 and 2: two periods blend into one (faster) or one
    /// into two (slower), so every piece is a whole period and the pitch is
    /// exactly kept; the rest of the speed comes from copying straight.
    private static func process(_ input: UnsafeBufferPointer<Float>, speed: Double,
                                minPeriod: Int, maxPeriod: Int, skip: Int) -> [Float] {
        let maxRequired = 2 * maxPeriod
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / speed) + maxRequired)
        var position = 0
        var copyAhead = 0
        var previousPeriod = 0
        while position + maxRequired <= input.count {
            if copyAhead > 0 {
                let count: Int = min(copyAhead, input.count - position)
                output.append(contentsOf: input[position..<(position + count)])
                position += count
                copyAhead -= count
                continue
            }
            let period: Int = pitchPeriod(input, at: position, minPeriod: minPeriod, maxPeriod: maxPeriod,
                                          skip: skip, previous: previousPeriod)
            previousPeriod = period
            let periodLength = Double(period)
            if speed > 1 {
                // Two periods become one blended period; the rest of the
                // speed-up comes from copying straight.
                let length: Int = period
                if speed < 2 { copyAhead = Int((periodLength * (2 - speed) / (speed - 1)).rounded()) }
                blend(input, fadeOutFrom: position, fadeInFrom: position + period, count: length, into: &output)
                position += period + length
            } else {
                // One period is played, then blended into a second.
                let length: Int = period
                if speed > 0.5 { copyAhead = Int((periodLength * (2 * speed - 1) / (1 - speed)).rounded()) }
                output.append(contentsOf: input[position..<(position + period)])
                blend(input, fadeOutFrom: position + period, fadeInFrom: position, count: length, into: &output)
                position += length
            }
        }
        // The tail, shorter than two long periods: as it was.
        if position < input.count { output.append(contentsOf: input[position..<input.count]) }
        return output
    }

    /// Lands the result on exactly `count / speed` samples, so the speed is
    /// what was asked and the time-pitch unit has nothing left to do. The
    /// difference (period rounding, the unstretched tail) is a few hundred
    /// samples, taken from or added to the silence that ends a sentence;
    /// a sentence that ends in sound keeps its length.
    private static func exactLength(_ output: [Float], for count: Int, speed: Double) -> [Float] {
        let target = max(1, Int((Double(count) / speed).rounded()))
        if output.count < target {
            return output + [Float](repeating: 0, count: target - output.count)
        }
        let extra = output.count - target
        guard extra > 0, output.suffix(extra).allSatisfy({ abs($0) < 0.02 }) else { return output }
        return Array(output.prefix(target))
    }

    /// A linear crossfade of `count` samples from one stretch into another.
    private static func blend(_ input: UnsafeBufferPointer<Float>, fadeOutFrom out: Int, fadeInFrom into: Int,
                              count: Int, into output: inout [Float]) {
        let length = Float(count)
        for index in 0..<count {
            let rise = Float(index) / length
            output.append(input[out + index] * (1 - rise) + input[into + index] * rise)
        }
    }

    /// The pitch period at `position`, by average magnitude difference: the
    /// lag at which the waveform best repeats. Searched on a 4 kHz average
    /// first, then refined at full rate; a lag near the last one wins a
    /// close call, so the period doesn't jump between octaves.
    private static func pitchPeriod(_ input: UnsafeBufferPointer<Float>, at position: Int,
                                    minPeriod: Int, maxPeriod: Int, skip: Int, previous: Int) -> Int {
        var coarse = maxPeriod
        if skip > 1 {
            let count = (2 * maxPeriod) / skip
            var reduced = [Float](repeating: 0, count: count)
            for index in 0..<count {
                var sum: Float = 0
                let base = position + index * skip
                for offset in 0..<skip { sum += input[base + offset] }
                reduced[index] = sum / Float(skip)
            }
            coarse = reduced.withUnsafeBufferPointer {
                bestLag($0, at: 0, from: max(1, minPeriod / skip), to: maxPeriod / skip, previous: previous / skip)
            } * skip
        }
        let low = max(minPeriod, coarse - 4 * skip)
        let high = min(maxPeriod, coarse + 4 * skip)
        guard low < high else { return min(max(coarse, minPeriod), maxPeriod) }
        return bestLag(input, at: position, from: low, to: high, previous: previous)
    }

    /// The lag in `from...to` with the smallest mean difference between the
    /// waveform and itself shifted by that lag.
    private static func bestLag(_ samples: UnsafeBufferPointer<Float>, at position: Int,
                                from: Int, to: Int, previous: Int) -> Int {
        guard from < to else { return from }
        var best = from
        var bestScore = Float.greatestFiniteMagnitude
        var previousScore = Float.greatestFiniteMagnitude
        for lag in from...to {
            var difference: Float = 0
            for index in 0..<lag {
                difference += abs(samples[position + index] - samples[position + index + lag])
            }
            let score = difference / Float(lag)
            if score < bestScore {
                bestScore = score
                best = lag
            }
            if lag == previous { previousScore = score }
        }
        // Keep the previous period when it is nearly as good.
        if previous >= from, previous <= to, previousScore <= bestScore * 1.1 { return previous }
        return best
    }
}
