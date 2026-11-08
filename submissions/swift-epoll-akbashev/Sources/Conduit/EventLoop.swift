// The executor every actor runs on: one thread of its own, an epoll instance and an eventfd. The Swift runtime hands
// it the actor's jobs through `enqueue` (from whichever thread sent the message, so the job list is the one place two
// threads meet: a Mutex), and the thread runs them one at a time, in order. With no job to run it sleeps in
// epoll_wait on the eventfd, the only place any thread of the server blocks waiting for work (Postgres reads block in
// the lanes' jobs, as in the Rust). A reactor blocks in epoll_wait itself, on an instance with its sockets registered
// next to the eventfd (`waitForEvents`); a lane or worker waiting for the scheduler, and a reactor between passes,
// wait for a deadline or `interrupt()` (`wait(until:)`).
import Glibc
import Synchronization
import Syscalls

final class EventLoop: SerialExecutor, TaskExecutor {
    /// The epoll instance; a reactor registers its sockets on it.
    let epollFD: Int32
    /// An epoll instance with only the eventfd: what the thread waits on with no job to run. A reactor's sockets
    /// stay ready (level-triggered) while its task is away on another actor's loop, so waiting on `epollFD` then
    /// would return at once, again and again.
    private let idleFD: Int32
    private let wakeFD: Int32
    static let wakeToken = UInt64.max

    private let jobs = Mutex<[UnownedJob]>([])
    private let park = Mutex<Park>(.idle)
    /// The loop is in (or about to enter) epoll_wait: whoever queues a job next writes the eventfd.
    private let sleeping = Atomic<Bool>(false)
    private let threadID = Atomic<UInt>(0)

    private enum Park: Sendable {
        case idle
        /// A pending `wait`, until `deadline` (monotonic nanoseconds).
        case waiting(UnsafeContinuation<Void, Never>, deadline: UInt64)
        /// `interrupt()` came with no wait pending: the next one returns at once.
        case woken
    }

    private let name: String
    private let nice: Int32

    /// A loop on a thread named `name`, at `nice`: one of its own, or with `onCallingThread` the thread that calls
    /// `runOnCallingThread()` once it is done with everything else (the main thread, after start-up).
    init(name: String, nice: Int32 = 0, onCallingThread: Bool = false) {
        self.name = name
        self.nice = nice
        epollFD = sys_epoll_create1(Sys.EPOLL_CLOEXEC)
        idleFD = sys_epoll_create1(Sys.EPOLL_CLOEXEC)
        wakeFD = sys_eventfd(0, Sys.EFD_NONBLOCK | Sys.EFD_CLOEXEC)
        guard epollFD >= 0, idleFD >= 0, wakeFD >= 0 else { fatalError("epoll_create1/eventfd: \(errno)") }
        for fd in [epollFD, idleFD] {
            guard EventLoop.control(fd, Sys.EPOLL_CTL_ADD, wakeFD, Sys.EPOLLIN, EventLoop.wakeToken) == 0 else {
                fatalError("epoll_ctl eventfd: \(errno)")
            }
        }
        if !onCallingThread { Sys.startThread(name: name, nice: nice) { [self] in run() } }
    }

    /// Gives the calling thread to this loop, for good.
    func runOnCallingThread() -> Never {
        Sys.nameThisThread(name, nice: nice)
        run()
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

    /// Suspends the caller until `deadline` (monotonic nanoseconds) passes or `interrupt()`, which may also have come
    /// just before. Only the actor isolated to this loop calls it, and only one wait is pending at a time. It can
    /// return early, so callers check what they wait for again.
    func wait(until deadline: UInt64 = .max) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let now = park.withLock { p -> Bool in
                if case .woken = p {
                    p = .idle
                    return true
                }
                p = .waiting(continuation, deadline: deadline)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Ends the pending `wait`, or the next one if none is pending.
    func interrupt() {
        park.withLock { p -> UnsafeContinuation<Void, Never>? in
            if case .waiting(let continuation, _) = p {
                p = .idle
                return continuation
            }
            p = .woken
            return nil
        }?.resume()
    }

    /// The pending wait's deadline, if one is pending.
    private var deadline: UInt64? {
        park.withLock { p in
            if case .waiting(_, let deadline) = p { deadline } else { nil }
        }
    }

    /// Ends the pending wait if its deadline has passed (never leaving a wake for the next one).
    private func expire(_ now: UInt64) {
        park.withLock { p -> UnsafeContinuation<Void, Never>? in
            guard case .waiting(let continuation, let deadline) = p, deadline <= now else { return nil }
            p = .idle
            return continuation
        }?.resume()
    }

    /// For the actor isolated to this loop, from its own thread (a reactor): blocks in epoll_wait on this loop's
    /// epoll instance, filling `events` (whose stride is `Sys.epollEventStride`), until a registered socket is ready or
    /// a job is queued for the loop. Returns the socket events (the eventfd's are dropped) and whether jobs are
    /// waiting, which the caller lets run by suspending.
    func waitForEvents(_ events: inout [UInt8]) -> (count: Int, jobsWaiting: Bool) {
        sleeping.store(true, ordering: .sequentiallyConsistent)
        let timeout: Int32 = jobs.withLock({ $0.isEmpty }) ? -1 : 0
        let n = Int(max(epollWait(epollFD, &events, timeout), 0))
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

    /// epoll_wait on `fd` into `events`, as many events as it holds.
    @inline(__always) private func epollWait(_ fd: Int32, _ events: inout [UInt8], _ timeout: Int32) -> Int32 {
        let capacity = Int32(events.count / Sys.epollEventStride)
        return events.withUnsafeMutableBytes { sys_epoll_wait(fd, $0.baseAddress!, capacity, timeout) }
    }

    // ---------- the thread ----------

    private func run() -> Never {
        threadID.store(UInt(bitPattern: Int(bitPattern: pthread_self())), ordering: .relaxed)
        var events = [UInt8](repeating: 0, count: Sys.epollEventStride)
        var batch: [UnownedJob] = []
        while true {
            jobs.withLock { swap(&batch, &$0) }
            if !batch.isEmpty {
                for job in batch {
                    job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: asUnownedTaskExecutor())
                }
                batch.removeAll(keepingCapacity: true)
                // A wait whose deadline passed while jobs kept coming ends now, not at the next idle moment.
                if let deadline, deadline != .max { expire(Sys.monotonicNanos()) }
                continue
            }
            let deadline = self.deadline
            sleeping.store(true, ordering: .sequentiallyConsistent)
            if !jobs.withLock({ $0.isEmpty }) {
                sleeping.store(false, ordering: .relaxed)
                continue
            }
            var timeout: Int32 = -1
            if let deadline, deadline != .max {
                let now = Sys.monotonicNanos()
                timeout = deadline <= now ? 0 : Int32(min((deadline - now + 999_999) / 1_000_000, 60_000))
            }
            if epollWait(idleFD, &events, timeout) > 0 {
                var value: UInt64 = 0
                _ = sys_read(wakeFD, &value, 8)
            }
            sleeping.store(false, ordering: .relaxed)
            if let deadline, deadline != .max { expire(Sys.monotonicNanos()) }
        }
    }
}
