// The Rust's READ_QUEUE, WRITE_QUEUE and CRYPTO_QUEUE with their batching policy (engine.rs: `take_aged`, the batch
// lock, the EWMA_* and BUSY_* atomics), as one actor. What the Rust shares between threads behind locks and atomics
// is this actor's state: reactors submit a tick's work in one message, lanes and crypto workers ask for their next
// batch and are resumed with it. One lane gathers at a time (the head waiter: the Rust's BATCH_LOCK holder) and
// takes the batch once it is big enough or its oldest request has waited long enough; the deadline is a timeout
// on this actor's own loop.

/// A FIFO of tasks with cheap removal from the front and insertion at it.
private struct TaskQueue<T> {
    private var items: [T] = []
    private var head = 0

    var count: Int { items.count - head }
    var isEmpty: Bool { head == items.count }

    mutating func append(_ t: T) { items.append(t) }
    mutating func append(contentsOf ts: [T]) { items.append(contentsOf: ts) }

    /// Puts `ts` in front, in their order (Rust's push_front / push_batch_front).
    mutating func prepend(_ ts: [T]) {
        guard !ts.isEmpty else { return }
        if head >= ts.count {
            head -= ts.count
            for (i, t) in ts.enumerated() { items[head + i] = t }
        } else {
            items.replaceSubrange(0..<head, with: ts)
            head = 0
        }
    }

    mutating func take(_ n: Int) -> [T] {
        let out = Array(items[head..<(head + n)])
        head += n
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 4096 && head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return out
    }
}

/// The parameters one gathering lane computed when it became the gatherer (under the Rust's batch lock).
private struct Gather {
    var want: Int
    var maxAge: UInt64
    var maxCap: Int
}

struct ReadBatchDone: Sendable {
    var count: Int
    var elapsedUs: Int
}

struct CryptoBatchDone: Sendable {
    /// Microseconds of the cost-10 part, if there was one (EWMA_BCRYPT_US).
    var standardUs: Int?
}

actor Scheduler {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let readWorkers: Int
    private let bcryptLanes: Int
    private let baseBatch: Int
    private let maxBatch: Int
    private let writeCap: Int

    private var reads = TaskQueue<ReadTask>()
    private var readsSince: UInt64?
    private var readWaiters: [CheckedContinuation<[ReadTask], Never>] = []
    private var readGather: Gather?
    private var readDeadline = UInt64.max
    private var busyReadWorkers = 0
    private var ewmaBatchUs: Int
    private var ewmaBatchLen = 0

    private var crypto = TaskQueue<CryptoTask>()
    private var cryptoSince: UInt64?
    private var cryptoWaiters: [CheckedContinuation<[CryptoTask], Never>] = []
    private var cryptoGather: Gather?
    private var cryptoDeadline = UInt64.max
    private var busyCryptoWorkers = 0
    private var ewmaBcryptUs: Int
    private var ewmaCryptoLen = 0

    private var writes = TaskQueue<WriteTask>()
    private var writeWaiters: [CheckedContinuation<[WriteTask], Never>] = []

    /// Requests whose connection closed while they were queued.
    private var cancelled = Set<ReplyAddr>()

    init(loop: EventLoop, readWorkers: Int, bcryptLanes: Int, seedBcryptUs: Int) {
        self.loop = loop
        self.readWorkers = readWorkers
        self.bcryptLanes = bcryptLanes
        let families = readCatalog().count
        let rw = max(readWorkers, 2)
        baseBatch = families * rw * 2
        maxBatch = baseBatch * rw * 2
        writeCap = families * rw * 2
        ewmaBatchUs = max(seedBcryptUs >> 7, 600)
        ewmaBcryptUs = seedBcryptUs
    }

    /// The deadline loop: re-evaluates the gathering lanes whenever woken (a submission, or a window ending).
    func run() async {
        while true {
            evaluate()
            await loop.wait(until: min(readDeadline, cryptoDeadline))
        }
    }

    func submit(_ s: Submission) {
        let now = monotonicNanos()
        if !s.cancelled.isEmpty {
            if cancelled.count > 4096 { cancelled.removeAll(keepingCapacity: true) }
            cancelled.formUnion(s.cancelled)
        }
        if !s.reads.isEmpty || !s.readsFront.isEmpty {
            if reads.isEmpty { readsSince = now }
            reads.append(contentsOf: s.reads)
            reads.prepend(s.readsFront)
        }
        if !s.crypto.isEmpty {
            if crypto.isEmpty { cryptoSince = now }
            crypto.append(contentsOf: s.crypto)
        }
        if !s.writes.isEmpty || !s.writesFront.isEmpty {
            writes.append(contentsOf: s.writes)
            writes.prepend(s.writesFront)
            serveWrites()
        }
        evaluate()
        loop.interrupt()
    }

    // ---------- reads ----------

    /// The next batch for a read lane, which reports how its last one went.
    func nextReads(finished: ReadBatchDone?) async -> [ReadTask] {
        if let f = finished {
            busyReadWorkers -= 1
            let us = ewmaBatchUs == 0 ? f.elapsedUs : (ewmaBatchUs * 3 + f.elapsedUs) / 4
            ewmaBatchUs = min(max(us, 200), 100_000)
            ewmaBatchLen = ewmaBatchLen == 0 ? f.count : (ewmaBatchLen * 3 + f.count) / 4
        }
        return await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
            if readWaiters.count == 1 { readGather = computeReadGather() }
            evaluate()
            loop.interrupt()
        }
    }

    private func computeReadGather() -> Gather {
        let rw = max(readWorkers, 2)
        let lanes = max(bcryptLanes, 2)
        let busy = min(busyReadWorkers, rw)
        if busy == 0 && ewmaBatchLen <= 2 {
            return Gather(want: rw, maxAge: UInt64(max(ewmaBatchUs / rw, 1)) * 1000, maxCap: maxBatch)
        }
        let target = min(max(ewmaBatchLen + ewmaBatchLen >> 1, baseBatch), maxBatch)
        if busy < rw {
            return Gather(want: target, maxAge: UInt64(max(ewmaBcryptUs / lanes, 1)) * 1000, maxCap: maxBatch)
        }
        // Every lane busy: gather for longer, a lane's share of a batch's time or half a bcrypt lane set's, at most a
        // bcrypt's.
        let windowUs = min(max(ewmaBatchUs / rw, ewmaBcryptUs / max(lanes / 2, 2)), ewmaBcryptUs)
        return Gather(want: target, maxAge: UInt64(windowUs) * 1000, maxCap: maxBatch)
    }

    // ---------- bcrypt ----------

    func nextCrypto(finished: CryptoBatchDone?) async -> [CryptoTask] {
        if let f = finished {
            busyCryptoWorkers -= 1
            if let us = f.standardUs {
                let next = ewmaBcryptUs == 0 ? us : (ewmaBcryptUs * 3 + us) / 4
                ewmaBcryptUs = min(max(next, 1_000), 150_000)
            }
        }
        return await withCheckedContinuation { continuation in
            cryptoWaiters.append(continuation)
            if cryptoWaiters.count == 1 { cryptoGather = computeCryptoGather() }
            evaluate()
            loop.interrupt()
        }
    }

    private func computeCryptoGather() -> Gather {
        let lanes = max(bcryptLanes, 1)
        let ageUs = busyCryptoWorkers == 0 && ewmaCryptoLen <= 1 ? max(ewmaBcryptUs / (lanes * 2), 1) : max(ewmaBcryptUs * 2, 1)
        return Gather(want: lanes, maxAge: UInt64(ageUs) * 1000, maxCap: lanes)
    }

    // ---------- writes ----------

    /// The next group for the write lane: everything waiting, up to the cap (Rust's `drain_up_to`).
    func nextWrites() async -> [WriteTask] {
        if !writes.isEmpty { return writes.take(min(writes.count, writeCap)) }
        return await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func serveWrites() {
        while !writeWaiters.isEmpty && !writes.isEmpty {
            writeWaiters.removeFirst().resume(returning: writes.take(min(writes.count, writeCap)))
        }
    }

    // ---------- gathering ----------

    private func evaluate() {
        let now = monotonicNanos()
        readDeadline = .max
        while !readWaiters.isEmpty && !reads.isEmpty {
            if readGather == nil { readGather = computeReadGather() }
            let g = readGather!
            if g.maxAge > 0 && reads.count < g.want {
                let deadline = (readsSince ?? now) + g.maxAge
                if now < deadline {
                    readDeadline = deadline
                    break
                }
            }
            var batch = reads.take(min(reads.count, g.maxCap))
            readsSince = reads.isEmpty ? nil : now
            readGather = nil
            if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
            if batch.isEmpty { continue }
            busyReadWorkers += 1
            readWaiters.removeFirst().resume(returning: batch)
            // The next lane in line gathers now, while this batch's lane counts as busy (the Rust's next lane takes
            // the batch lock, and computes its window, the moment this one releases it).
            readGather = readWaiters.isEmpty ? nil : computeReadGather()
        }
        cryptoDeadline = .max
        while !cryptoWaiters.isEmpty && !crypto.isEmpty {
            if cryptoGather == nil { cryptoGather = computeCryptoGather() }
            let g = cryptoGather!
            if g.maxAge > 0 && crypto.count < g.want {
                let deadline = (cryptoSince ?? now) + g.maxAge
                if now < deadline {
                    cryptoDeadline = deadline
                    break
                }
            }
            var batch = crypto.take(min(crypto.count, g.maxCap))
            cryptoSince = crypto.isEmpty ? nil : now
            cryptoGather = nil
            busyCryptoWorkers += 1
            ewmaCryptoLen = ewmaCryptoLen == 0 ? batch.count : (ewmaCryptoLen * 3 + batch.count) / 4
            if !cancelled.isEmpty { batch.removeAll { cancelled.contains($0.addr) } }
            cryptoWaiters.removeFirst().resume(returning: batch)
            cryptoGather = cryptoWaiters.isEmpty ? nil : computeCryptoGather()
        }
        if reads.isEmpty && crypto.isEmpty && !cancelled.isEmpty { cancelled.removeAll(keepingCapacity: true) }
    }
}
