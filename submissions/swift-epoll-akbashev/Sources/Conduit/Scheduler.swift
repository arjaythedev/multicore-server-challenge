// The Rust's READ_LANES, WRITE_QUEUE and CRYPTO_QUEUE with their batching policy (engine.rs: `pick_eligible_lane`,
// `try_take_aged`, the batch, write and crypto locks, the EWMA_*, BUSY_*, INFLIGHT_LANE and LAST_* atomics), as one
// actor. What the Rust shares between threads behind locks and atomics is this actor's state: reactors submit a tick's
// work in one message, lanes and crypto workers ask for their next batch and are resumed with it. Reads wait in three
// queues (fast, comments, feeds); an idle read lane picks a queue and gathers its next batch, one lane per queue at a
// time, and takes it once it is big enough or its window ends. Write and bcrypt workers gather one at a time, each
// for a window of its own. The windows are timeouts on this actor's own loop.

actor Scheduler {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    /// The Rust's LANE_FAST (tags, users, logins, profiles, articles, lists), LANE_CMTS and LANE_FEED.
    static let fastQueue = 0, commentsQueue = 1, feedQueue = 2

    static func queue(of op: ReadOp) -> Int {
        switch op {
        case .feed: feedQueue
        case .comments: commentsQueue
        default: fastQueue
        }
    }

    private let readWorkers: Int
    private let bcryptLanes: Int
    private let maxBatch: Int

    private var reads: [ReadQueue]
    private var readWaiters: [CheckedContinuation<ReadBatch, Never>] = []
    private var readDeadline = UInt64.max
    private var busyReadWorkers = 0

    private var crypto = TaskQueue<CryptoTask>()
    private var cryptoWaiters: [CheckedContinuation<[CryptoTask], Never>] = []
    /// When the gathering bcrypt worker takes its lane set, whether full or not.
    private var cryptoGather: UInt64?
    private var cryptoDeadline = UInt64.max
    private var busyCryptoWorkers = 0
    private var ewmaBcryptUs: Int
    private var ewmaCryptoLen = 0
    private var lastCryptoDone: UInt64 = 0

    private var writes = TaskQueue<WriteTask>()
    private var writeWaiters: [CheckedContinuation<[WriteTask], Never>] = []
    /// When the gathering write lane takes its group, whether full or not.
    private var writeGather: UInt64?
    private var writeDeadline = UInt64.max
    private var busyWriteWorkers = 0
    private var ewmaWriteLen = 0
    private var lastWriteDone: UInt64 = 0

    /// Requests whose connection closed while they were queued.
    private var cancelled = Set<ReplyAddr>()

    init(loop: EventLoop, readWorkers: Int, bcryptLanes: Int, seedBcryptUs: Int) {
        self.loop = loop
        self.readWorkers = readWorkers
        self.bcryptLanes = bcryptLanes
        let rw = max(readWorkers, 2)
        maxBatch = Catalog.reads().count * rw * 2 * rw * 2
        reads = Array(repeating: ReadQueue(ewmaUs: max(seedBcryptUs >> 7, 600)), count: 3)
        ewmaBcryptUs = seedBcryptUs
    }

    /// The deadline loop: re-evaluates the gathering workers whenever woken (a submission, or a window ending).
    func run() async {
        while true {
            evaluate()
            await loop.wait(until: min(readDeadline, writeDeadline, cryptoDeadline))
        }
    }

    /// Queues `s`'s work, and gives `s` back emptied, its arrays' memory kept for the sender's next submission.
    @discardableResult
    func submit(_ s: consuming Submission) -> Submission {
        let now = Sys.monotonicNanos()
        if !s.cancelled.isEmpty {
            if cancelled.count > 4096 { cancelled.removeAll(keepingCapacity: true) }
            cancelled.formUnion(s.cancelled)
        }
        for t in s.reads { reads[Self.queue(of: t.op)].queue.append(t, at: now) }
        for t in s.readsFront.reversed() { reads[Self.queue(of: t.op)].queue.prepend(t, at: now) }
        crypto.append(contentsOf: s.crypto, at: now)
        writes.append(contentsOf: s.writes, at: now)
        for t in s.writesFront.reversed() { writes.prepend(t, at: now) }
        evaluate()
        loop.interrupt()
        s.removeAll()
        return s
    }

    // ---------- reads ----------

    /// The next batch for a read lane, which reports how its last one went.
    func nextReads(finished: Scheduler.ReadBatchDone?) async -> ReadBatch {
        if let f = finished {
            busyReadWorkers -= 1
            reads[f.queue].inflight -= 1
            reads[f.queue].finished(count: f.count, elapsedUs: f.elapsedUs)
        }
        return await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
            evaluate()
            loop.interrupt()
        }
    }

    /// `pick_eligible_lane`: the queue an idle read lane gathers for next, how many requests it waits for, and until
    /// when. At most max(rw - 1, 3) lanes gather or run at once, and each queue has a share of them (fast 3/8 of the
    /// lanes, comments and feeds 1/4 each), one more for the queue with the oldest request or one waiting 90 ms while
    /// the fast queue has room. Of the queues with room, the one whose head is oldest by more than 2 ms. With nothing
    /// else going on, a short window; otherwise a queue is drained at most every 74 ms (feeds 76), a batch gathers for
    /// at least 5 ms, and no request waits more than the gap and those 5 ms.
    private func pickQueue(_ now: UInt64) -> (queue: Int, want: Int, deadline: UInt64)? {
        let rw = max(readWorkers, 2)
        let maxActive = max(rw - 1, 3)
        guard busyReadWorkers < maxActive else { return nil }
        let baseCaps = [max(rw * 3 / 8, 2), max(rw / 4, 1), max(rw / 4, 1)]
        let fast = Self.fastQueue, comments = Self.commentsQueue, feed = Self.feedQueue

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
        let r = reads[q]
        let tauUs = max(r.ewmaUs, 600)
        if busyReadWorkers == 0 && r.ewmaLen <= 4 && r.queue.count <= 2 {
            return (q, rw, since + UInt64(max(tauUs / rw, 1)) * 1000)
        }
        let gap: UInt64 = q == feed ? 76_000_000 : 74_000_000
        let window: UInt64 = 5_000_000
        let age = now &- min(since, now)
        let gapLeft = r.lastDrain == 0 ? 0 : (r.lastDrain + gap) &- min(r.lastDrain + gap, now)
        let windowLeft = window &- min(window, age)
        let itemLeft = (gap + window) &- min(gap + window, age)
        return (q, min(rw * 256, maxBatch), now + min(max(gapLeft, windowLeft), itemLeft))
    }

    private func evaluateReads(_ now: UInt64) {
        var progressed = true
        while progressed {
            progressed = false
            while !readWaiters.isEmpty, let pick = pickQueue(now) {
                busyReadWorkers += 1
                reads[pick.queue].inflight += 1
                reads[pick.queue].gatherer = Gatherer(continuation: readWaiters.removeFirst(), want: pick.want,
                                                       deadline: pick.deadline)
            }
            for q in 0..<3 {
                guard let g = reads[q].gatherer, reads[q].queue.count >= g.want || now >= g.deadline else { continue }
                reads[q].gatherer = nil
                var batch = reads[q].queue.take(min(reads[q].queue.count, maxBatch))
                reads[q].lastDrain = now
                if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
                if batch.isEmpty {
                    busyReadWorkers -= 1
                    reads[q].inflight -= 1
                    readWaiters.insert(g.continuation, at: 0)
                } else {
                    g.continuation.resume(returning: ReadBatch(queue: q, tasks: batch))
                }
                progressed = true
            }
        }
        readDeadline = .max
        for q in 0..<3 { if let g = reads[q].gatherer { readDeadline = min(readDeadline, g.deadline) } }
    }

    // ---------- bcrypt ----------

    /// The next lane set for a bcrypt worker, which reports how its last one went.
    func nextCrypto(finished: Scheduler.CryptoBatchDone?) async -> [CryptoTask] {
        if let f = finished {
            busyCryptoWorkers -= 1
            if let us = f.standardUs {
                let next = ewmaBcryptUs == 0 ? us : (ewmaBcryptUs * 3 + us) / 4
                ewmaBcryptUs = min(max(next, 1_000), 150_000)
                lastCryptoDone = Sys.monotonicNanos()
            }
        }
        return await withCheckedContinuation { continuation in
            cryptoWaiters.append(continuation)
            evaluate()
            loop.interrupt()
        }
    }

    /// One worker gathers at a time, for a full lane set: briefly when logins come one by one, otherwise for 1.5 bcrypt
    /// runs (2 to 35 ms) with no other worker busy, or 2 (10 to 45 ms) with one.
    private func evaluateCrypto(_ now: UInt64) {
        cryptoDeadline = .max
        let lanes = max(bcryptLanes, 1)
        while !cryptoWaiters.isEmpty, let since = crypto.since {
            if cryptoGather == nil {
                let tauUs = max(ewmaBcryptUs, 10_000)
                let overlap = busyCryptoWorkers > 0 || crypto.count > 1
                    || (lastCryptoDone > 0 && now &- min(lastCryptoDone, now) < 120_000_000)
                let ageUs = if !overlap && ewmaCryptoLen <= 1 {
                    max(tauUs / (lanes * 2), 1)
                } else if busyCryptoWorkers == 0 {
                    min(max(tauUs * 3 / 2, 2_000), 35_000)
                } else {
                    min(max(tauUs * 2, 10_000), 45_000)
                }
                cryptoGather = since + UInt64(ageUs) * 1000
            }
            if crypto.count < lanes && now < cryptoGather! {
                cryptoDeadline = cryptoGather!
                break
            }
            cryptoGather = nil
            var batch = crypto.take(min(crypto.count, lanes))
            ewmaCryptoLen = ewmaCryptoLen == 0 ? batch.count : (ewmaCryptoLen * 3 + batch.count) / 4
            busyCryptoWorkers += 1
            if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
            cryptoWaiters.removeFirst().resume(returning: batch)
        }
    }

    // ---------- writes ----------

    /// The next group for a write lane, which says whether it just committed one.
    func nextWrites(finished: Bool) async -> [WriteTask] {
        if finished {
            busyWriteWorkers -= 1
            lastWriteDone = Sys.monotonicNanos()
        }
        return await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
            evaluate()
            loop.interrupt()
        }
    }

    /// One lane gathers at a time, for up to 64 writes: 150 µs when writes come one by one, otherwise 3 ms with no
    /// other lane committing, 4 with one, 5 with more. A group is at most 128.
    private func evaluateWrites(_ now: UInt64) {
        writeDeadline = .max
        while !writeWaiters.isEmpty, let since = writes.since {
            if writeGather == nil {
                let recent = busyWriteWorkers > 0 || writes.count > 1 || ewmaWriteLen > 2
                    || (lastWriteDone > 0 && now &- min(lastWriteDone, now) < 10_000_000)
                let ageUs: UInt64 = !recent ? 150 : busyWriteWorkers == 0 ? 3_000 : busyWriteWorkers == 1 ? 4_000 : 5_000
                writeGather = since + ageUs * 1000
            }
            if writes.count < 64 && now < writeGather! {
                writeDeadline = writeGather!
                break
            }
            writeGather = nil
            let group = writes.take(min(writes.count, 128))
            ewmaWriteLen = ewmaWriteLen == 0 ? group.count : (ewmaWriteLen * 3 + group.count) / 4
            busyWriteWorkers += 1
            writeWaiters.removeFirst().resume(returning: group)
        }
    }

    // ---------- gathering ----------

    private func evaluate() {
        let now = Sys.monotonicNanos()
        evaluateReads(now)
        evaluateCrypto(now)
        evaluateWrites(now)
        if !cancelled.isEmpty && crypto.isEmpty && reads.allSatisfy({ $0.queue.isEmpty }) {
            cancelled.removeAll(keepingCapacity: true)
        }
    }
}

extension Scheduler {
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

    /// The idle read lane gathering a queue's next batch, which it takes once `want` requests wait or at `deadline`.
    private struct Gatherer {
        let continuation: CheckedContinuation<ReadBatch, Never>
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
