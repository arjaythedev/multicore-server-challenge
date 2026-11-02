// The executor every actor runs on: one thread of its own, an epoll instance and an eventfd. The Swift runtime hands
// it the actor's jobs through `enqueue` (from whichever thread sent the message, so the job list is the one place two
// threads meet: a Mutex), and the thread runs them one at a time, in order. With no job to run it sleeps in
// epoll_wait, the only place any thread of the server blocks waiting for work (Postgres reads block in the lanes'
// jobs, as in the Rust). A reactor blocks in that same epoll_wait itself, with its sockets registered next to the
// eventfd (`waitForEvents`); the scheduler waits for a deadline or `interrupt()` (`wait(until:)`).
import Glibc
import Synchronization

final class EventLoop: SerialExecutor, TaskExecutor {
    /// The epoll instance; a reactor registers its sockets on it.
    let epollFD: Int32
    private let wakeFD: Int32
    static let wakeToken = UInt64.max

    private let jobs = Mutex<[UnownedJob]>([])
    private let parked = Mutex<Parked?>(nil)
    /// The loop is in (or about to enter) epoll_wait: whoever queues a job next writes the eventfd.
    private let sleeping = Atomic<Bool>(false)
    private let threadID = Atomic<UInt>(0)

    private struct Parked: Sendable {
        let continuation: UnsafeContinuation<Void, Never>
        /// Monotonic nanoseconds.
        let deadline: UInt64
    }

    init(name: String) {
        epollFD = sys_epoll_create1(Sys.EPOLL_CLOEXEC)
        wakeFD = sys_eventfd(0, Sys.EFD_NONBLOCK | Sys.EFD_CLOEXEC)
        guard epollFD >= 0, wakeFD >= 0 else { fatalError("epoll_create1/eventfd: \(errno)") }
        guard EventLoop.control(epollFD, Sys.EPOLL_CTL_ADD, wakeFD, Sys.EPOLLIN, EventLoop.wakeToken) == 0 else {
            fatalError("epoll_ctl eventfd: \(errno)")
        }
        startThread(name: name) { [self] in run() }
    }

    /// epoll_ctl with an event built at the ABI's offsets (see `Sys.epollDataOffset`).
    static func control(_ epfd: Int32, _ op: Int32, _ fd: Int32, _ events: UInt32, _ token: UInt64) -> Int32 {
        withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { raw in
            raw.storeBytes(of: events, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: token, toByteOffset: Sys.epollDataOffset, as: UInt64.self)
            return sys_epoll_ctl(epfd, op, fd, raw.baseAddress!)
        }
    }

    // ---------- the executor ----------

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        jobs.withLock { $0.append(job) }
        if sleeping.exchange(false, ordering: .sequentiallyConsistent) {
            var one: UInt64 = 1
            _ = sys_write(wakeFD, &one, 8)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Whether the calling thread is this loop's: what `assumeIsolated` and `preconditionIsolated` check.
    func isIsolatingCurrentContext() -> Bool? {
        threadID.load(ordering: .relaxed) == UInt(bitPattern: Int(bitPattern: pthread_self()))
    }

    func checkIsolated() {
        if isIsolatingCurrentContext() != true { fatalError("not on this event loop's thread") }
    }

    // ---------- waiting, for the actor isolated to this loop ----------

    /// Suspends the caller until `deadline` (monotonic nanoseconds) passes or `interrupt()`. Only the actor isolated
    /// to this loop calls it, and only one wait is pending at a time.
    func wait(until deadline: UInt64 = .max) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            parked.withLock { $0 = Parked(continuation: continuation, deadline: deadline) }
        }
    }

    /// Ends the pending `wait`, if any.
    func interrupt() {
        parked.withLock { p -> UnsafeContinuation<Void, Never>? in
            defer { p = nil }
            return p?.continuation
        }?.resume()
    }

    /// For the actor isolated to this loop, from its own thread (a reactor): blocks in epoll_wait on this loop's
    /// epoll instance, filling `events` (whose stride is `Sys.epollEventStride`), until a registered socket is ready or
    /// a job is queued for the loop. Returns the socket events (the eventfd's are dropped) and whether jobs are
    /// waiting, which the caller lets run by suspending.
    func waitForEvents(_ events: inout [UInt8]) -> (count: Int, jobsWaiting: Bool) {
        sleeping.store(true, ordering: .sequentiallyConsistent)
        let timeout: Int32 = jobs.withLock({ $0.isEmpty }) ? -1 : 0
        let n = Int(max(epollWait(&events, timeout), 0))
        sleeping.store(false, ordering: .relaxed)
        var kept = 0
        for i in 0..<n {
            let at = i * Sys.epollEventStride
            if events.span.bytes.load(fromByteOffset: at + Sys.epollDataOffset, as: UInt64.self) == EventLoop.wakeToken {
                var value: UInt64 = 0
                _ = sys_read(wakeFD, &value, 8)
                continue
            }
            if kept != i {
                for b in 0..<Sys.epollEventStride { events[kept * Sys.epollEventStride + b] = events[at + b] }
            }
            kept += 1
        }
        return (kept, !jobs.withLock { $0.isEmpty })
    }

    /// epoll_wait into `events`, as many events as it holds.
    @inline(__always) private func epollWait(_ events: inout [UInt8], _ timeout: Int32) -> Int32 {
        let capacity = Int32(events.count / Sys.epollEventStride)
        return events.withUnsafeMutableBytes { sys_epoll_wait(epollFD, $0.baseAddress!, capacity, timeout) }
    }

    // ---------- the thread ----------

    private func run() -> Never {
        threadID.store(UInt(bitPattern: Int(bitPattern: pthread_self())), ordering: .relaxed)
        let maxEvents = 64
        var events = [UInt8](repeating: 0, count: maxEvents * Sys.epollEventStride)
        var batch: [UnownedJob] = []
        while true {
            jobs.withLock { swap(&batch, &$0) }
            if !batch.isEmpty {
                for job in batch {
                    job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: asUnownedTaskExecutor())
                }
                batch.removeAll(keepingCapacity: true)
                continue
            }
            let deadline = parked.withLock { $0?.deadline }
            sleeping.store(true, ordering: .sequentiallyConsistent)
            if !jobs.withLock({ $0.isEmpty }) {
                sleeping.store(false, ordering: .relaxed)
                continue
            }
            var timeout: Int32 = -1
            if let deadline, deadline != .max {
                let now = monotonicNanos()
                timeout = deadline <= now ? 0 : Int32(min((deadline - now + 999_999) / 1_000_000, 60_000))
            }
            // Only the eventfd matters here: a reactor's sockets are read by the reactor's own waitForEvents.
            let n = epollWait(&events, timeout)
            sleeping.store(false, ordering: .relaxed)
            for i in 0..<max(Int(n), 0)
            where events.span.bytes.load(fromByteOffset: i * Sys.epollEventStride + Sys.epollDataOffset, as: UInt64.self) == EventLoop.wakeToken {
                var value: UInt64 = 0
                _ = sys_read(wakeFD, &value, 8)
            }
            if let deadline, deadline != .max, monotonicNanos() >= deadline { interrupt() }
        }
    }
}
