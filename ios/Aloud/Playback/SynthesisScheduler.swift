import Foundation
import os

enum SynthesisPriority: String, Sendable {
    case now
    case prefetch
}

enum SynthesisSchedulerError: Error {
    case backlogFull
}

/// One piece of a cold lead's chain as it lands (`SynthesisScheduler.synthesizeLead`).
struct LandedPiece: Sendable {
    let clip: SynthesizedAudio
    /// The piece of the plan it speaks; nil for the whole sentence (its
    /// clip was cached, or being made whole, when the chain was asked for).
    let piece: ColdLeadPlan.Piece?
    let isLast: Bool
}

/// Serializes synthesis into two FIFO lanes. `now` preempts the entire
/// prefetch backlog; the prefetch lane is bounded (excess silently dropped);
/// exactly one synthesis is in flight at a time. Results land in the cache.
/// Queued work is only what someone still wants: a request whose last
/// waiter gave up leaves its lane, and a prefetch someone waits on goes
/// ahead of (and, in a full lane, displaces) the warm-ups no one waits on.
/// A cold lead (R3-07) is one job made in pieces back to back, so nothing
/// queued can slip between them; each piece reaches its listeners as it
/// lands, and the joined clip is cached and given to the waiters. A
/// look-ahead sentence or warm-up may be made in pieces too (C4), so the
/// one job in flight, which nothing can stop mid-call, stops at its next
/// piece once no one wants it: a tap then waits behind one piece of it.
actor SynthesisScheduler {

    private struct Waiter {
        let id: UUID
        let deliver: @Sendable (Result<SynthesizedAudio, Error>) -> Void

        init(id: UUID, continuation: CheckedContinuation<SynthesizedAudio, Error>) {
            self.id = id
            self.deliver = { continuation.resume(with: $0) }
        }

        init(id: UUID, deliver: @escaping @Sendable (Result<SynthesizedAudio, Error>) -> Void) {
            self.id = id
            self.deliver = deliver
        }
    }

    /// A listener to a cold lead's pieces.
    private struct Sink {
        let id: UUID
        let continuation: AsyncThrowingStream<LandedPiece, Error>.Continuation
    }

    private struct Job {
        let key: String
        let text: String
        let voice: TtsVoice
        /// The pace asked of the engine (`NativeSpeed`); the key carries it.
        let speed: Double
        /// Queued by `prefetch`: wanted in the cache with no one waiting, so
        /// it stays when a waiter that joined it gives up.
        var isWarmUp = false
        var waiters: [Waiter] = []
        /// Made in these pieces (R3-07) rather than whole.
        var plan: ColdLeadPlan?
        var sinks: [Sink] = []
        /// The pieces made so far, seamed, for a listener that joins late.
        var landed: [SynthesizedAudio] = []
        /// A cold lead (`leadWait`) or a whole `now` job (`nowWait`) queued
        /// behind a different job in flight: its wait in line, signposted
        /// from its admit to its turn.
        var wait: QueueWait?

        /// Someone still wants it made.
        var isWanted: Bool { isWarmUp || !waiters.isEmpty || !sinks.isEmpty }
    }

    /// When a start began waiting behind another job, and its interval.
    private struct QueueWait {
        let interval: BudgetSignposts.Interval
        let since: ContinuousClock.Instant
    }

    private let engine: any TtsEngine
    private let cache: AudioClipCache
    private let signposts: BudgetSignposts
    private static let log = Logger(subsystem: "com.davidxie.Aloud", category: "synthesis")

    private var nowLane: [Job] = []
    private var prefetchLane: [Job] = []
    private var inFlight: Job?
    private var isDraining = false
    // Bridges the tiny race where a waiter is cancelled before it is admitted.
    private var cancelledWaiters: Set<UUID> = []
    /// The pieces each recently joined clip was made in (C4): the tokens
    /// each speaks and its frames in the joined clip, so a clip asked for
    /// in pieces is scheduled with each piece's own word timing. Capped.
    private var joinedPieces: [String: [MadePiece]] = [:]

    private static let prefetchBound = 8

    init(engine: any TtsEngine, cache: AudioClipCache, signposts: BudgetSignposts = .live) {
        self.engine = engine
        self.cache = cache
        self.signposts = signposts
    }

    /// Synthesizes (or serves from cache) the clip for `key`, waiting its turn
    /// in the requested lane. Cancellation-aware: a cancelled caller is
    /// resumed with `CancellationError` and its slot released.
    /// `plan` (C4): made in its pieces rather than whole when it is queued
    /// new (a job already queued for `key` keeps how it was asked for, one
    /// in flight how it is being made); the waiters get the joined clip.
    func synthesize(_ text: String,
                    voice: TtsVoice,
                    speed: Double = 1.0,
                    key: String,
                    priority: SynthesisPriority = .now,
                    plan: ColdLeadPlan? = nil) async throws -> SynthesizedAudio {
        if let hit = cache.clip(forKey: key) { return hit }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admit(Waiter(id: waiterID, continuation: continuation),
                      key: key, text: text, voice: voice, speed: speed, priority: priority, plan: plan)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Fire-and-forget warm-up of the cache via the prefetch lane, made in
    /// `plan`'s pieces when one is given (C4). `aheadOfWarmUps` (C5, a
    /// Mac click's held sentence): ahead of the other warm-ups no one
    /// waits on, though never of a request someone waits on.
    func prefetch(_ text: String, voice: TtsVoice, speed: Double = 1.0, key: String,
                  plan: ColdLeadPlan? = nil, aheadOfWarmUps: Bool = false) {
        guard cache.clip(forKey: key) == nil else { return }
        // A cold lead in flight that its listener left (a pause from
        // buffering) is wanted in the cache now: it makes the rest of its
        // pieces rather than stop, and nothing is made twice.
        if inFlight?.key == key, inFlight?.plan != nil {
            inFlight?.isWarmUp = true
            return
        }
        guard !isQueued(key) else { return }
        guard prefetchLane.count < Self.prefetchBound else { return }
        let job = Job(key: key, text: text, voice: voice, speed: speed, isWarmUp: true, plan: plan)
        if aheadOfWarmUps {
            prefetchLane.insert(job, at: prefetchLane.firstIndex { $0.waiters.isEmpty } ?? prefetchLane.endIndex)
        } else {
            prefetchLane.append(job)
        }
        drainIfNeeded()
    }

    /// Warms `warmUps` in order, first dropping the warm-ups no one waits on
    /// when `replacingWarmUps`: the cue moved, so the clips for where it was
    /// are no longer wanted ahead of anything else. One call, so a drop can
    /// never land between the new cue's warm-ups. `plans` (C4, by key):
    /// those made in pieces.
    func prefetch(_ warmUps: [(text: String, key: String)], voice: TtsVoice, speed: Double = 1.0,
                  replacingWarmUps: Bool, plans: [String: ColdLeadPlan] = [:]) {
        if replacingWarmUps { prefetchLane.removeAll { $0.waiters.isEmpty } }
        for warmUp in warmUps {
            prefetch(warmUp.text, voice: voice, speed: speed, key: warmUp.key, plan: plans[warmUp.key])
        }
    }

    /// C5: a warm-up for `key` is no longer wanted (a held click became a
    /// double-click, a selection or a key): a queued one no one waits on
    /// leaves its lane, and one in flight that no one waits on or listens
    /// to stops at its next piece. Anything someone waits on is untouched.
    func dropWarmUp(key: String) {
        prefetchLane.removeAll { $0.key == key && $0.waiters.isEmpty && $0.sinks.isEmpty }
        if inFlight?.key == key, inFlight?.waiters.isEmpty == true, inFlight?.sinks.isEmpty == true {
            inFlight?.isWarmUp = false
        }
    }

    /// C4: the pieces the clip cached under `key` was joined from, the
    /// tokens each speaks and its frames there, in order; nil for a clip
    /// made whole (or long gone).
    func madePieces(forKey key: String) -> [MadePiece]? {
        joinedPieces[key]
    }

    /// Makes the clip for `key` in `plan`'s pieces, in the `now` lane, and
    /// hands each piece to the stream as it lands, seamed (`ColdLeadPlan.seamed`).
    /// The pieces are one job, made back to back; once all have landed the
    /// joined clip is cached under `key`. A clip already cached, or being
    /// made whole, comes as one piece with no `piece`. Ending the stream
    /// leaves the chain: made for no one, it stops at its next piece.
    func synthesizeLead(_ plan: ColdLeadPlan, voice: TtsVoice, speed: Double = 1.0,
                        key: String) -> AsyncThrowingStream<LandedPiece, Error> {
        let (stream, continuation) = AsyncThrowingStream<LandedPiece, Error>.makeStream()
        let sink = Sink(id: UUID(), continuation: continuation)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelSink(sink.id) }
        }
        admitLead(sink, plan: plan, voice: voice, speed: speed, key: key)
        return stream
    }

    /// Drops everything queued (the in-flight job finishes and still caches).
    func cancelPending() {
        let dropped = nowLane + prefetchLane
        nowLane = []
        prefetchLane = []
        for job in dropped {
            discard(job)
            for waiter in job.waiters {
                waiter.deliver(.failure(CancellationError()))
            }
            for sink in job.sinks { sink.continuation.finish(throwing: CancellationError()) }
        }
    }

    // MARK: - Queueing

    private func admit(_ waiter: Waiter,
                       key: String,
                       text: String,
                       voice: TtsVoice,
                       speed: Double,
                       priority: SynthesisPriority,
                       plan: ColdLeadPlan? = nil) {
        if cancelledWaiters.remove(waiter.id) != nil {
            waiter.deliver(.failure(CancellationError()))
            return
        }
        if let hit = cache.clip(forKey: key) {
            waiter.deliver(.success(hit))
            return
        }
        if inFlight?.key == key {
            inFlight?.waiters.append(waiter)
            return
        }

        switch priority {
        case .now:
            preemptPrefetchLane()
            if let index = nowLane.firstIndex(where: { $0.key == key }) {
                nowLane[index].waiters.append(waiter)
            } else {
                var job = Job(key: key, text: text, voice: voice, speed: speed, waiters: [waiter], plan: plan)
                // Behind another job in flight, the start waits for the rest
                // of it first: measured apart from its own making.
                if inFlight != nil {
                    job.wait = QueueWait(interval: signposts.begin(.nowWait), since: .now)
                }
                nowLane.append(job)
            }
        case .prefetch:
            if let index = prefetchLane.firstIndex(where: { $0.key == key }),
               !prefetchLane[index].waiters.isEmpty {
                prefetchLane[index].waiters.append(waiter)
            } else {
                // The first to wait on it: ahead of every warm-up no one
                // waits on (a stale cue's never holds up reading), and a
                // full lane makes room by dropping the oldest of those.
                // Refused only when the whole lane is waited on.
                var job = prefetchLane.firstIndex(where: { $0.key == key }).map { prefetchLane.remove(at: $0) }
                    ?? Job(key: key, text: text, voice: voice, speed: speed)
                job.waiters = [waiter]
                if job.plan == nil { job.plan = plan }
                if prefetchLane.count >= Self.prefetchBound {
                    guard let spare = prefetchLane.firstIndex(where: { $0.waiters.isEmpty }) else {
                        waiter.deliver(.failure(SynthesisSchedulerError.backlogFull))
                        return
                    }
                    prefetchLane.remove(at: spare)
                }
                let slot = prefetchLane.firstIndex(where: { $0.waiters.isEmpty }) ?? prefetchLane.endIndex
                prefetchLane.insert(job, at: slot)
            }
        }
        drainIfNeeded()
    }

    /// The entire prefetch backlog yields to the now lane, and a job in
    /// flight in pieces that only warms the cache (no one waits on it or
    /// listens to it: a lead a pause left, a background warm-up) is no
    /// longer wanted, so it stops at its next piece (C4) and the start goes
    /// next. One made whole cannot stop, and finishes.
    private func preemptPrefetchLane() {
        if inFlight?.plan != nil, inFlight?.isWarmUp == true,
           inFlight?.waiters.isEmpty == true, inFlight?.sinks.isEmpty == true {
            inFlight?.isWarmUp = false
        }
        let preempted = prefetchLane
        prefetchLane = []
        for job in preempted {
            discard(job)
            for stale in job.waiters {
                stale.deliver(.failure(CancellationError()))
            }
            for sink in job.sinks { sink.continuation.finish(throwing: CancellationError()) }
        }
    }

    /// A cold lead's listener joins: a cached clip comes at once, a job in
    /// flight is followed (its landed pieces first), and otherwise the
    /// sentence is queued in the now lane to be made in `plan`'s pieces,
    /// taking over any job queued for it with its waiters.
    private func admitLead(_ sink: Sink, plan: ColdLeadPlan, voice: TtsVoice, speed: Double, key: String) {
        if let hit = cache.clip(forKey: key) {
            sink.continuation.yield(LandedPiece(clip: hit, piece: nil, isLast: true))
            sink.continuation.finish()
            return
        }
        if inFlight?.key == key {
            if let inFlightPlan = inFlight?.plan {
                for (index, clip) in (inFlight?.landed ?? []).enumerated() {
                    sink.continuation.yield(LandedPiece(clip: clip, piece: inFlightPlan.pieces[index],
                                                        isLast: index == inFlightPlan.pieces.count - 1))
                }
                inFlight?.sinks.append(sink)
            } else {
                let continuation = sink.continuation
                inFlight?.waiters.append(Waiter(id: sink.id) { result in
                    switch result {
                    case .success(let clip):
                        continuation.yield(LandedPiece(clip: clip, piece: nil, isLast: true))
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                })
            }
            return
        }
        let queuedNow = nowLane.firstIndex { $0.key == key }
        var job = queuedNow.map { nowLane.remove(at: $0) }
            ?? prefetchLane.firstIndex { $0.key == key }.map { prefetchLane.remove(at: $0) }
            ?? Job(key: key, text: plan.text, voice: voice, speed: speed)
        preemptPrefetchLane()
        if job.plan == nil { job.plan = plan }
        job.sinks.append(sink)
        // Behind another job in flight, the lead waits its whole length
        // first: measured apart from the lead's own making.
        if job.wait == nil, inFlight != nil {
            job.wait = QueueWait(interval: signposts.begin(.leadWait), since: .now)
        }
        nowLane.insert(job, at: queuedNow ?? nowLane.endIndex)
        drainIfNeeded()
    }

    private func cancelSink(_ id: UUID) {
        func drop(from lane: inout [Job]) {
            for index in lane.indices.reversed() where lane[index].sinks.contains(where: { $0.id == id }) {
                lane[index].sinks.removeAll { $0.id == id }
                if !lane[index].isWanted { discard(lane.remove(at: index)) }
            }
        }
        drop(from: &nowLane)
        drop(from: &prefetchLane)
        inFlight?.sinks.removeAll { $0.id == id }
        // A listener to a job made whole waits as a waiter.
        _ = removeInFlightWaiter(id: id)
    }

    private func cancelWaiter(_ id: UUID) {
        if let deliver = removeWaiter(id: id, from: &nowLane)
            ?? removeWaiter(id: id, from: &prefetchLane)
            ?? removeInFlightWaiter(id: id) {
            deliver(.failure(CancellationError()))
            return
        }
        // Not admitted yet (or already settled) — remember briefly, capped.
        if cancelledWaiters.count >= 32 { cancelledWaiters.removeAll() }
        cancelledWaiters.insert(id)
    }

    /// A job whose last waiter gave up leaves the lane (a warm-up stays):
    /// rapid skips never make the sentence landed on wait behind the ones
    /// skipped past.
    private func removeWaiter(id: UUID, from lane: inout [Job])
        -> (@Sendable (Result<SynthesizedAudio, Error>) -> Void)? {
        for jobIndex in lane.indices {
            if let waiterIndex = lane[jobIndex].waiters.firstIndex(where: { $0.id == id }) {
                let waiter = lane[jobIndex].waiters.remove(at: waiterIndex)
                if !lane[jobIndex].isWanted { discard(lane.remove(at: jobIndex)) }
                return waiter.deliver
            }
        }
        return nil
    }

    private func removeInFlightWaiter(id: UUID)
        -> (@Sendable (Result<SynthesizedAudio, Error>) -> Void)? {
        guard var job = inFlight,
              let index = job.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        let waiter = job.waiters.remove(at: index)
        inFlight = job
        return waiter.deliver
    }

    private func isQueued(_ key: String) -> Bool {
        inFlight?.key == key
            || nowLane.contains { $0.key == key }
            || prefetchLane.contains { $0.key == key }
    }

    // MARK: - Draining

    private func drainIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { await drainLoop() }
    }

    private func drainLoop() async {
        while var job = dequeue() {
            endWait(&job)
            inFlight = job
            let outcome: Result<SynthesizedAudio, Error>
            if let hit = cache.clip(forKey: job.key) {
                outcome = .success(hit)
            } else if let plan = job.plan {
                outcome = await synthesizePieces(of: plan, voice: job.voice, speed: job.speed, key: job.key)
            } else {
                do {
                    let clip = try await engine.synthesize(job.text, voice: job.voice, speed: job.speed)
                    cache.store(clip, forKey: job.key)
                    joinedPieces[job.key] = nil
                    outcome = .success(clip)
                } catch {
                    outcome = .failure(error)
                }
            }
            // Re-read: waiters may have joined while synthesis was in flight.
            let settled = inFlight
            inFlight = nil
            for waiter in settled?.waiters ?? [] {
                waiter.deliver(outcome)
            }
            for sink in settled?.sinks ?? [] {
                switch outcome {
                case .success(let clip) where settled?.landed.isEmpty == true:
                    // Cached before its first piece was made: the whole clip.
                    sink.continuation.yield(LandedPiece(clip: clip, piece: nil, isLast: true))
                    sink.continuation.finish()
                case .success: sink.continuation.finish()
                case .failure(let error): sink.continuation.finish(throwing: error)
                }
            }
        }
        isDraining = false
    }

    /// The in-flight job's pieces, made back to back and handed to its
    /// listeners as each lands; the joined clip is cached under `key`.
    /// Stops at a piece boundary once no one wants the rest.
    private func synthesizePieces(of plan: ColdLeadPlan, voice: TtsVoice, speed: Double,
                                  key: String) async -> Result<SynthesizedAudio, Error> {
        var made: [SynthesizedAudio] = []
        var tail: TimeInterval = 0
        let last = plan.pieces.count - 1
        for (index, piece) in plan.pieces.enumerated() {
            guard inFlight?.isWanted == true else { return .failure(CancellationError()) }
            do {
                let clip = try await engine.synthesize(piece.text, voice: voice, speed: speed)
                let seamed = ColdLeadPlan.seamed(clip, trimsLeading: index > 0, trimsTrailing: index < last,
                                                 rate: plan.rate, precedingTail: tail)
                tail = seamed.tail
                made.append(seamed.clip)
                inFlight?.landed.append(seamed.clip)
                for sink in inFlight?.sinks ?? [] {
                    sink.continuation.yield(LandedPiece(clip: seamed.clip, piece: piece, isLast: index == last))
                }
            } catch {
                return .failure(error)
            }
        }
        guard let joined = ColdLeadPlan.joined(made) else { return .failure(TtsError.emptyAudio) }
        cache.store(joined, forKey: key)
        if joinedPieces.count >= Self.joinedPiecesBound { joinedPieces.removeAll() }
        joinedPieces[key] = zip(plan.pieces, made).map { MadePiece(tokens: $0.tokens, frames: $1.samples.count) }
        return .success(joined)
    }

    private static let joinedPiecesBound = 32

    /// A job dropped before its turn: a start's wait never reached it.
    private func discard(_ job: Job) {
        if let wait = job.wait { signposts.end(wait.interval, gaveUp: true) }
    }

    /// A start's turn has come: its wait in line ends.
    private func endWait(_ job: inout Job) {
        guard let wait = job.wait else { return }
        job.wait = nil
        signposts.end(wait.interval)
        let waited = ContinuousClock.now - wait.since
        let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
        if wait.interval.budget == .leadWait {
            Self.log.info("cold lead waited \(seconds, format: .fixed(precision: 3), privacy: .public) s behind a job in flight")
        } else {
            Self.log.info("now job waited \(seconds, format: .fixed(precision: 3), privacy: .public) s behind a job in flight")
        }
        #if DEBUG
        TapAudioProbe.noteQueueWait(seconds: seconds)
        #endif
    }

    private func dequeue() -> Job? {
        if !nowLane.isEmpty { return nowLane.removeFirst() }
        if !prefetchLane.isEmpty { return prefetchLane.removeFirst() }
        return nil
    }

    #if DEBUG
    /// Test seam: the keys queued behind the one in flight, now lane first.
    var queuedKeys: [String] { (nowLane + prefetchLane).map(\.key) }
    /// Test seam: the key in flight, if any.
    var inFlightKey: String? { inFlight?.key }
    #endif
}

/// One piece a joined clip was made in (`SynthesisScheduler.madePieces`):
/// the sentence tokens it speaks and its frames in the joined clip.
struct MadePiece: Sendable, Equatable {
    let tokens: Range<Int>
    let frames: Int
}
