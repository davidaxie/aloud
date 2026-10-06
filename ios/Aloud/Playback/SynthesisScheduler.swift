import Foundation

enum SynthesisPriority: String, Sendable {
    case now
    case prefetch
}

enum SynthesisSchedulerError: Error {
    case backlogFull
}

/// Serializes synthesis into two FIFO lanes. `now` preempts the entire
/// prefetch backlog; the prefetch lane is bounded (excess silently dropped);
/// exactly one synthesis is in flight at a time. Results land in the cache.
actor SynthesisScheduler {

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<SynthesizedAudio, Error>
    }

    private struct Job {
        let key: String
        let text: String
        let voice: TtsVoice
        /// The pace asked of the engine (`NativeSpeed`); the key carries it.
        let speed: Double
        var waiters: [Waiter] = []
    }

    private let engine: any TtsEngine
    private let cache: AudioClipCache

    private var nowLane: [Job] = []
    private var prefetchLane: [Job] = []
    private var inFlight: Job?
    private var isDraining = false
    // Bridges the tiny race where a waiter is cancelled before it is admitted.
    private var cancelledWaiters: Set<UUID> = []

    private static let prefetchBound = 8

    init(engine: any TtsEngine, cache: AudioClipCache) {
        self.engine = engine
        self.cache = cache
    }

    /// Synthesizes (or serves from cache) the clip for `key`, waiting its turn
    /// in the requested lane. Cancellation-aware: a cancelled caller is
    /// resumed with `CancellationError` and its slot released.
    func synthesize(_ text: String,
                    voice: TtsVoice,
                    speed: Double = 1.0,
                    key: String,
                    priority: SynthesisPriority = .now) async throws -> SynthesizedAudio {
        if let hit = cache.clip(forKey: key) { return hit }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                admit(Waiter(id: waiterID, continuation: continuation),
                      key: key, text: text, voice: voice, speed: speed, priority: priority)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Fire-and-forget warm-up of the cache via the prefetch lane.
    func prefetch(_ text: String, voice: TtsVoice, speed: Double = 1.0, key: String) {
        guard cache.clip(forKey: key) == nil, !isQueued(key) else { return }
        guard prefetchLane.count < Self.prefetchBound else { return }
        prefetchLane.append(Job(key: key, text: text, voice: voice, speed: speed))
        drainIfNeeded()
    }

    /// Drops everything queued (the in-flight job finishes and still caches).
    func cancelPending() {
        let dropped = nowLane + prefetchLane
        nowLane = []
        prefetchLane = []
        for job in dropped {
            for waiter in job.waiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - Queueing

    private func admit(_ waiter: Waiter,
                       key: String,
                       text: String,
                       voice: TtsVoice,
                       speed: Double,
                       priority: SynthesisPriority) {
        if cancelledWaiters.remove(waiter.id) != nil {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if let hit = cache.clip(forKey: key) {
            waiter.continuation.resume(returning: hit)
            return
        }
        if inFlight?.key == key {
            inFlight?.waiters.append(waiter)
            return
        }

        switch priority {
        case .now:
            // Preempt: the entire prefetch backlog yields to the now lane.
            let preempted = prefetchLane
            prefetchLane = []
            for job in preempted {
                for stale in job.waiters {
                    stale.continuation.resume(throwing: CancellationError())
                }
            }
            if let index = nowLane.firstIndex(where: { $0.key == key }) {
                nowLane[index].waiters.append(waiter)
            } else {
                nowLane.append(Job(key: key, text: text, voice: voice, speed: speed, waiters: [waiter]))
            }
        case .prefetch:
            if let index = prefetchLane.firstIndex(where: { $0.key == key }) {
                prefetchLane[index].waiters.append(waiter)
            } else if prefetchLane.count >= Self.prefetchBound {
                waiter.continuation.resume(throwing: SynthesisSchedulerError.backlogFull)
                return
            } else {
                prefetchLane.append(Job(key: key, text: text, voice: voice, speed: speed, waiters: [waiter]))
            }
        }
        drainIfNeeded()
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = removeWaiter(id: id, from: &nowLane)
            ?? removeWaiter(id: id, from: &prefetchLane)
            ?? removeInFlightWaiter(id: id) {
            continuation.resume(throwing: CancellationError())
            return
        }
        // Not admitted yet (or already settled) — remember briefly, capped.
        if cancelledWaiters.count >= 32 { cancelledWaiters.removeAll() }
        cancelledWaiters.insert(id)
    }

    private func removeWaiter(id: UUID, from lane: inout [Job])
        -> CheckedContinuation<SynthesizedAudio, Error>? {
        for jobIndex in lane.indices {
            if let waiterIndex = lane[jobIndex].waiters.firstIndex(where: { $0.id == id }) {
                return lane[jobIndex].waiters.remove(at: waiterIndex).continuation
            }
        }
        return nil
    }

    private func removeInFlightWaiter(id: UUID)
        -> CheckedContinuation<SynthesizedAudio, Error>? {
        guard var job = inFlight,
              let index = job.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        let waiter = job.waiters.remove(at: index)
        inFlight = job
        return waiter.continuation
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
        while let job = dequeue() {
            inFlight = job
            let outcome: Result<SynthesizedAudio, Error>
            if let hit = cache.clip(forKey: job.key) {
                outcome = .success(hit)
            } else {
                do {
                    let clip = try await engine.synthesize(job.text, voice: job.voice, speed: job.speed)
                    cache.store(clip, forKey: job.key)
                    outcome = .success(clip)
                } catch {
                    outcome = .failure(error)
                }
            }
            // Re-read: waiters may have joined while synthesis was in flight.
            let settled = inFlight
            inFlight = nil
            for waiter in settled?.waiters ?? [] {
                switch outcome {
                case .success(let clip): waiter.continuation.resume(returning: clip)
                case .failure(let error): waiter.continuation.resume(throwing: error)
                }
            }
        }
        isDraining = false
    }

    private func dequeue() -> Job? {
        if !nowLane.isEmpty { return nowLane.removeFirst() }
        if !prefetchLane.isEmpty { return prefetchLane.removeFirst() }
        return nil
    }
}
