// The Rust's READ_LANES, WRITE_QUEUE and CRYPTO_QUEUE with their batching policy (engine.rs: `pick_eligible_lane`,
// `try_take_aged`, the batch, write and crypto locks, the EWMA_*, BUSY_*, INFLIGHT_LANE and LAST_* atomics). It is
// shared state behind one `Mutex`, not an actor: everything touches it for a moment, so a thread of its own and a hop
// there and back for every touch would cost more than the work. A reactor queues a pass's work with a plain call and
// never leaves its own thread. A lane, write lane or bcrypt worker takes its next batch the same way, and when there
// is none yet it waits on its own loop (an `isolated` parameter makes sure the loop is the caller's), until the call
// that makes its batch ready wakes it or its window ends (the loop's deadline: the Rust's `wait_timeout`). Reads wait
// in three queues (fast, comments, feeds); an idle read lane picks a queue and gathers its next batch, one lane per
// queue at a time. Write lanes and bcrypt workers gather one at a time, each for a window of its own.
import Synchronization

/// An actor whose executor is its own `EventLoop`, so it can wait on that loop for the scheduler.
protocol LoopIsolated: Actor {
    nonisolated var loop: EventLoop { get }
}

final class Scheduler: Sendable {
    /// The Rust's LANE_FAST (tags, users, logins, profiles, articles, lists), LANE_CMTS and LANE_FEED.
    static let fastQueue = 0, commentsQueue = 1, feedQueue = 2

    static func queue(of op: ReadOp) -> Int {
        switch op {
        case .feed: feedQueue
        case .comments: commentsQueue
        default: fastQueue
        }
    }

    private let state: Mutex<State>

    /// `fullBcryptSets`: wait up to two bcrypt runs, with no cap, for a full lane set once workers overlap, instead of at
    /// most 35-45 ms.
    init(readWorkers: Int, bcryptLanes: Int, seedBcryptUs: Int, fullBcryptSets: Bool = false) {
        state = Mutex(State(readWorkers: readWorkers, bcryptLanes: bcryptLanes, seedBcryptUs: seedBcryptUs,
                            fullBcryptSets: fullBcryptSets))
    }

    /// Queues `s`'s work and leaves it empty, its arrays' memory kept for the caller's next pass.
    func submit(_ s: inout Submission) {
        var wakes = Wakes()
        state.withLock { $0.submit(s, &wakes) }
        wakes.fire()
        s.removeAll()
    }

    func submit(_ s: consuming Submission) {
        submit(&s)
    }

    /// The next batch for read lane `lane`, which reports how its last one went.
    func nextReads<L: LoopIsolated>(for lane: isolated L, finished: ReadBatchDone?) async -> ReadBatch {
        var finished = finished
        var gathering: Int?
        while true {
            var wakes = Wakes()
            let step = state.withLock { $0.nextReads(lane.loop, gathering: gathering, finished: finished, &wakes) }
            wakes.fire()
            finished = nil
            switch step {
            case .batch(let batch): return batch
            case .wait(let deadline, let queue):
                gathering = queue
                await lane.loop.wait(until: deadline)
            }
        }
    }

    /// The next lane set for bcrypt worker `worker`, which reports how its last one went.
    func nextCrypto<W: LoopIsolated>(for worker: isolated W, finished: CryptoBatchDone?) async -> [CryptoTask] {
        var finished = finished
        while true {
            var wakes = Wakes()
            let step = state.withLock { $0.nextCrypto(worker.loop, finished: finished, &wakes) }
            wakes.fire()
            finished = nil
            switch step {
            case .batch(let batch): return batch
            case .wait(let deadline): await worker.loop.wait(until: deadline)
            }
        }
    }

    /// The next group for write lane `lane`, which says whether it just committed one.
    func nextWrites<L: LoopIsolated>(for lane: isolated L, finished: Bool) async -> [WriteTask] {
        var finished = finished
        while true {
            var wakes = Wakes()
            let step = state.withLock { $0.nextWrites(lane.loop, finished: finished, &wakes) }
            wakes.fire()
            finished = false
            switch step {
            case .batch(let group): return group
            case .wait(let deadline): await lane.loop.wait(until: deadline)
            }
        }
    }
}

extension Scheduler {
    /// Everything behind the lock.
    private struct State: ~Copyable {
        let readWorkers: Int
        let bcryptLanes: Int
        let fullBcryptSets: Bool
        let maxBatch: Int

        var reads: [ReadQueue]
        /// Read lanes with nothing to gather, in the order they asked.
        var idleReaders: [EventLoop] = []
        var busyReadWorkers = 0

        var crypto = TaskQueue<CryptoTask>()
        var cryptoGatherer: Gatherer?
        var idleCrypto: [EventLoop] = []
        var busyCryptoWorkers = 0
        var ewmaBcryptUs: Int
        var ewmaCryptoLen = 0
        var lastCryptoDone: UInt64 = 0

        var writes = TaskQueue<WriteTask>()
        var writeGatherer: Gatherer?
        var idleWriters: [EventLoop] = []
        var busyWriteWorkers = 0
        var ewmaWriteLen = 0
        var lastWriteDone: UInt64 = 0

        /// Requests whose connection closed while they were queued.
        var cancelled = Set<ReplyAddr>()

        init(readWorkers: Int, bcryptLanes: Int, seedBcryptUs: Int, fullBcryptSets: Bool) {
            self.readWorkers = readWorkers
            self.bcryptLanes = bcryptLanes
            self.fullBcryptSets = fullBcryptSets
            let rw = max(readWorkers, 2)
            maxBatch = Catalog.reads().count * rw * 2 * rw * 2
            reads = Array(repeating: ReadQueue(ewmaUs: max(seedBcryptUs >> 7, 600)), count: 3)
            ewmaBcryptUs = seedBcryptUs
        }

        mutating func submit(_ s: borrowing Submission, _ wakes: inout Wakes) {
            let now = Sys.monotonicNanos()
            if !s.cancelled.isEmpty {
                if cancelled.count > 4096 { cancelled.removeAll(keepingCapacity: true) }
                for i in s.cancelled.indices { cancelled.insert(s.cancelled[i]) }
            }
            if !s.reads.isEmpty || !s.readsFront.isEmpty {
                for i in s.reads.indices { reads[Scheduler.queue(of: s.reads[i].op)].queue.append(s.reads[i], at: now) }
                for i in s.readsFront.indices.reversed() {
                    reads[Scheduler.queue(of: s.readsFront[i].op)].queue.prepend(s.readsFront[i], at: now)
                }
                for q in 0..<3 {
                    if let g = reads[q].gatherer, reads[q].queue.count >= g.want { wakes.add(g.loop) }
                }
                wakeIdleReader(now, &wakes)
            }
            if !s.crypto.isEmpty {
                crypto.append(contentsOf: s.crypto, at: now)
                if let g = cryptoGatherer {
                    if crypto.count >= max(bcryptLanes, 1) { wakes.add(g.loop) }
                } else if !idleCrypto.isEmpty {
                    wakes.add(idleCrypto.removeFirst())
                }
            }
            if !s.writes.isEmpty || !s.writesFront.isEmpty {
                writes.append(contentsOf: s.writes, at: now)
                for i in s.writesFront.indices.reversed() { writes.prepend(s.writesFront[i], at: now) }
                if let g = writeGatherer {
                    if writes.count >= Self.writeWant { wakes.add(g.loop) }
                } else if !idleWriters.isEmpty {
                    wakes.add(idleWriters.removeFirst())
                }
            }
            if !cancelled.isEmpty && crypto.isEmpty && reads.allSatisfy({ $0.queue.isEmpty }) {
                cancelled.removeAll(keepingCapacity: true)
            }
        }

        // ---------- reads ----------

        mutating func nextReads(_ loop: EventLoop, gathering: Int?, finished: ReadBatchDone?,
                                _ wakes: inout Wakes) -> ReadStep {
            let now = Sys.monotonicNanos()
            if let f = finished {
                busyReadWorkers -= 1
                reads[f.queue].inflight -= 1
                reads[f.queue].finished(count: f.count, elapsedUs: f.elapsedUs)
            }
            if let q = gathering, let g = reads[q].gatherer, g.loop === loop {
                if reads[q].queue.count >= g.want || now >= g.deadline { return drainReads(q, now, &wakes) }
                return .wait(g.deadline, gathering: q)
            }
            idleReaders.removeAll { $0 === loop }
            guard let pick = pickQueue(now) else {
                idleReaders.append(loop)
                return .wait(.max, gathering: nil)
            }
            busyReadWorkers += 1
            reads[pick.queue].inflight += 1
            reads[pick.queue].gatherer = Gatherer(loop: loop, want: pick.want, deadline: pick.deadline)
            if reads[pick.queue].queue.count >= pick.want || now >= pick.deadline { return drainReads(pick.queue, now, &wakes) }
            wakeIdleReader(now, &wakes)
            return .wait(pick.deadline, gathering: pick.queue)
        }

        /// The gatherer of queue `q` takes its batch. If the hung-up clients leave it nothing, the lane picks again.
        private mutating func drainReads(_ q: Int, _ now: UInt64, _ wakes: inout Wakes) -> ReadStep {
            let loop = reads[q].gatherer!.loop
            reads[q].gatherer = nil
            var batch = reads[q].queue.take(min(reads[q].queue.count, maxBatch))
            reads[q].lastDrain = now
            if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
            if batch.isEmpty {
                busyReadWorkers -= 1
                reads[q].inflight -= 1
                return nextReads(loop, gathering: nil, finished: nil, &wakes)
            }
            wakeIdleReader(now, &wakes)
            return .batch(ReadBatch(queue: q, tasks: batch))
        }

        /// Wakes the longest-idle read lane if some queue is ready to be gathered (the Rust's `wake_read_dispatcher`).
        private mutating func wakeIdleReader(_ now: UInt64, _ wakes: inout Wakes) {
            if !idleReaders.isEmpty && pickQueue(now) != nil { wakes.add(idleReaders.removeFirst()) }
        }

        /// `pick_eligible_lane`: the queue an idle read lane gathers for next, how many requests it waits for, and until
        /// when. At most max(rw - 1, 3) lanes gather or run at once, and each queue has a share of them (fast 3/8 of the
        /// lanes, comments and feeds 1/4 each), one more for the queue with the oldest request or one waiting 90 ms
        /// while the fast queue has room. Of the queues with room, the one whose head is oldest by more than 2 ms. With
        /// nothing else going on, a short window; otherwise a queue is drained at most every 74 ms (feeds 76), a batch
        /// gathers for at least 5 ms, and no request waits more than the gap and those 5 ms.
        private func pickQueue(_ now: UInt64) -> (queue: Int, want: Int, deadline: UInt64)? {
            let rw = max(readWorkers, 2)
            let maxActive = max(rw - 1, 3)
            guard busyReadWorkers < maxActive else { return nil }
            let baseCaps = [max(rw * 3 / 8, 2), max(rw / 4, 1), max(rw / 4, 1)]
            let fast = Scheduler.fastQueue, comments = Scheduler.commentsQueue, feed = Scheduler.feedQueue

            var oldest: (queue: Int, since: UInt64)?
            for q in 0..<3 {
                if let since = reads[q].queue.since, oldest.map({ since < $0.since }) ?? true { oldest = (q, since) }
            }
            var chosen: (queue: Int, since: UInt64)?
            for q in 0..<3 {
                guard let since = reads[q].queue.since, reads[q].gatherer == nil else { continue }
                let ageMs = (now &- min(since, now)) / 1_000_000
                let isOldest = oldest?.queue == q
                var cap = baseCaps[q]
                if q == feed && (isOldest || (ageMs >= 90 && reads[fast].inflight < baseCaps[fast])) {
                    cap = min(cap + 1, maxActive)
                } else if q == fast && isOldest && reads[feed].inflight < baseCaps[feed] {
                    cap = min(cap + 1, maxActive)
                } else if q == comments && (isOldest || (ageMs >= 90 && reads[fast].inflight < baseCaps[fast])) {
                    cap = min(cap + 1, maxActive)
                }
                guard reads[q].inflight < cap else { continue }
                if let c = chosen {
                    let earlier = since + 2_000_000 < c.since
                    let tied = (c.since &- min(since, c.since)) <= 2_000_000 && q < c.queue
                    if earlier || tied { chosen = (q, since) }
                } else {
                    chosen = (q, since)
                }
            }
            guard let (q, since) = chosen else { return nil }
            let tauUs = max(reads[q].ewmaUs, 600)
            if busyReadWorkers == 0 && reads[q].ewmaLen <= 4 && reads[q].queue.count <= 2 {
                return (q, rw, since + UInt64(max(tauUs / rw, 1)) * 1000)
            }
            let gap: UInt64 = q == feed ? 76_000_000 : 74_000_000
            let window: UInt64 = 5_000_000
            let lastDrain = reads[q].lastDrain
            let age = now &- min(since, now)
            let gapLeft = lastDrain == 0 ? 0 : (lastDrain + gap) &- min(lastDrain + gap, now)
            let windowLeft = window &- min(window, age)
            let itemLeft = (gap + window) &- min(gap + window, age)
            return (q, min(rw * 256, maxBatch), now + min(max(gapLeft, windowLeft), itemLeft))
        }

        // ---------- bcrypt ----------

        /// One worker gathers at a time, for a full lane set: briefly when logins come one by one, otherwise for 1.5
        /// bcrypt runs (2 to 35 ms) with no other worker busy, or 2 (10 to 45 ms) with one. With `fullBcryptSets`,
        /// briefly while no worker is busy and logins come one by one, otherwise for two bcrypt runs.
        mutating func nextCrypto(_ loop: EventLoop, finished: CryptoBatchDone?, _ wakes: inout Wakes) -> TakeStep<CryptoTask> {
            let now = Sys.monotonicNanos()
            if let f = finished {
                busyCryptoWorkers -= 1
                if let us = f.standardUs {
                    let next = ewmaBcryptUs == 0 ? us : (ewmaBcryptUs * 3 + us) / 4
                    ewmaBcryptUs = min(max(next, 1_000), 150_000)
                    lastCryptoDone = now
                }
            }
            let lanes = max(bcryptLanes, 1)
            if let g = cryptoGatherer, g.loop !== loop {
                if !idleCrypto.contains(where: { $0 === loop }) { idleCrypto.append(loop) }
                return .wait(.max)
            }
            idleCrypto.removeAll { $0 === loop }
            if cryptoGatherer == nil {
                guard let since = crypto.since else {
                    idleCrypto.append(loop)
                    return .wait(.max)
                }
                let tauUs = max(ewmaBcryptUs, 10_000)
                let overlap = busyCryptoWorkers > 0 || crypto.count > 1
                    || (lastCryptoDone > 0 && now &- min(lastCryptoDone, now) < 120_000_000)
                let ageUs = if fullBcryptSets {
                    busyCryptoWorkers == 0 && ewmaCryptoLen <= 1 ? max(ewmaBcryptUs / (lanes * 2), 1) : max(ewmaBcryptUs * 2, 1)
                } else if !overlap && ewmaCryptoLen <= 1 {
                    max(tauUs / (lanes * 2), 1)
                } else if busyCryptoWorkers == 0 {
                    min(max(tauUs * 3 / 2, 2_000), 35_000)
                } else {
                    min(max(tauUs * 2, 10_000), 45_000)
                }
                cryptoGatherer = Gatherer(loop: loop, want: lanes, deadline: since + UInt64(ageUs) * 1000)
            }
            let deadline = cryptoGatherer!.deadline
            if crypto.count < lanes && now < deadline { return .wait(deadline) }
            cryptoGatherer = nil
            var batch = crypto.take(min(crypto.count, lanes))
            ewmaCryptoLen = ewmaCryptoLen == 0 ? batch.count : (ewmaCryptoLen * 3 + batch.count) / 4
            busyCryptoWorkers += 1
            if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
            if !crypto.isEmpty && !idleCrypto.isEmpty { wakes.add(idleCrypto.removeFirst()) }
            return .batch(batch)
        }

        // ---------- writes ----------

        static let writeWant = 64

        /// One lane gathers at a time, for up to 64 writes: 150 µs when writes come one by one, otherwise 3 ms with no
        /// other lane committing, 4 with one, 5 with more. A group is at most 128.
        mutating func nextWrites(_ loop: EventLoop, finished: Bool, _ wakes: inout Wakes) -> TakeStep<WriteTask> {
            let now = Sys.monotonicNanos()
            if finished {
                busyWriteWorkers -= 1
                lastWriteDone = now
            }
            if let g = writeGatherer, g.loop !== loop {
                if !idleWriters.contains(where: { $0 === loop }) { idleWriters.append(loop) }
                return .wait(.max)
            }
            idleWriters.removeAll { $0 === loop }
            if writeGatherer == nil {
                guard let since = writes.since else {
                    idleWriters.append(loop)
                    return .wait(.max)
                }
                let recent = busyWriteWorkers > 0 || writes.count > 1 || ewmaWriteLen > 2
                    || (lastWriteDone > 0 && now &- min(lastWriteDone, now) < 10_000_000)
                let ageUs: UInt64 = !recent ? 150 : busyWriteWorkers == 0 ? 3_000 : busyWriteWorkers == 1 ? 4_000 : 5_000
                writeGatherer = Gatherer(loop: loop, want: Self.writeWant, deadline: since + ageUs * 1000)
            }
            let deadline = writeGatherer!.deadline
            if writes.count < Self.writeWant && now < deadline { return .wait(deadline) }
            writeGatherer = nil
            let group = writes.take(min(writes.count, 128))
            ewmaWriteLen = ewmaWriteLen == 0 ? group.count : (ewmaWriteLen * 3 + group.count) / 4
            busyWriteWorkers += 1
            if !writes.isEmpty && !idleWriters.isEmpty { wakes.add(idleWriters.removeFirst()) }
            return .batch(group)
        }
    }

    /// The loops to wake, collected under the lock and woken once it is released (each exactly once: `fire` consumes).
    private struct Wakes: ~Copyable {
        private var loops = InlineArray<8, EventLoop?>(repeating: nil)
        private var count = 0

        mutating func add(_ loop: EventLoop) {
            for i in 0..<count where loops[i] === loop { return }
            if count == 8 {
                loop.interrupt()
                return
            }
            loops[count] = loop
            count += 1
        }

        consuming func fire() {
            for i in 0..<count { loops[i]!.interrupt() }
        }
    }

    private enum ReadStep {
        case batch(ReadBatch)
        /// Until `deadline`, or until woken; `gathering` is the queue the lane gathers for, if any.
        case wait(UInt64, gathering: Int?)
    }

    private enum TakeStep<T> {
        case batch([T])
        case wait(UInt64)
    }

    /// A FIFO of tasks with cheap removal from the front and insertion at it, and when each arrived.
    private struct TaskQueue<T> {
        private var items: [T] = []
        /// Monotonic nanoseconds.
        private var arrivals: [UInt64] = []
        private var head = 0
        /// When the request at the head arrived, or an older one if a newer was put in front of it (the Rust's
        /// `since`); nil when empty.
        private(set) var since: UInt64?

        var count: Int { items.count - head }
        var isEmpty: Bool { head == items.count }

        mutating func append(_ t: T, at now: UInt64) {
            if isEmpty { since = now }
            items.append(t)
            arrivals.append(now)
        }

        mutating func append(contentsOf ts: [T], at now: UInt64) {
            guard !ts.isEmpty else { return }
            if isEmpty { since = now }
            items.append(contentsOf: ts)
            arrivals.append(contentsOf: repeatElement(now, count: ts.count))
        }

        /// Puts `t` in front (Rust's push_front).
        mutating func prepend(_ t: T, at now: UInt64) {
            since = min(since ?? now, now)
            if head > 0 {
                head -= 1
                items[head] = t
                arrivals[head] = now
            } else {
                items.insert(t, at: 0)
                arrivals.insert(now, at: 0)
            }
        }

        mutating func take(_ n: Int) -> [T] {
            let out = Array(items[head..<(head + n)])
            head += n
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                arrivals.removeAll(keepingCapacity: true)
                head = 0
                since = nil
            } else {
                if head > 4096 && head * 2 > items.count {
                    items.removeFirst(head)
                    arrivals.removeFirst(head)
                    head = 0
                }
                since = arrivals[head]
            }
            return out
        }
    }

    /// The worker gathering a queue's next batch, on `loop`, which it takes once `want` requests wait or at `deadline`.
    private struct Gatherer {
        let loop: EventLoop
        let want: Int
        let deadline: UInt64
    }

    /// One of the three read queues and what the Rust keeps per lane for it.
    private struct ReadQueue {
        var queue = TaskQueue<ReadTask>()
        var gatherer: Gatherer?
        /// Lanes gathering or running a batch from this queue (INFLIGHT_LANE).
        var inflight = 0
        /// When it was last drained (LAST_DRAIN_US), 0 before the first time.
        var lastDrain: UInt64 = 0
        /// Its batches' time and size (EWMA_LANE_US, EWMA_LANE_LEN).
        var ewmaUs: Int
        var ewmaLen = 0

        init(ewmaUs: Int) { self.ewmaUs = ewmaUs }

        mutating func finished(count: Int, elapsedUs: Int) {
            ewmaUs = min(max(ewmaUs == 0 ? elapsedUs : (ewmaUs * 3 + elapsedUs) / 4, 200), 100_000)
            ewmaLen = ewmaLen == 0 ? count : (ewmaLen * 3 + count) / 4
        }
    }

    struct ReadBatch: Sendable {
        let queue: Int
        let tasks: [ReadTask]
    }

    struct ReadBatchDone: Sendable {
        let queue: Int
        let count: Int
        let elapsedUs: Int
    }

    struct CryptoBatchDone: Sendable {
        /// Microseconds of the cost-10 part, if there was one (EWMA_BCRYPT_US).
        let standardUs: Int?
    }
}
