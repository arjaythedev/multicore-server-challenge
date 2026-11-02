// The event loops, in place of NIO's: one thread per core, each with an epoll instance of its own (kqueue on macOS, so
// the server runs there too for development). Each turn a loop runs the work queued for it (closures, and the jobs of
// the tasks that prefer it as their executor), then calls back the file descriptors that are ready, then its timers,
// then waits. What a loop owns (its sources, its own queue, its timers) is touched only on its thread. Other threads
// reach it through `execute`, which takes a lock and wakes the loop only when it is blocked waiting; work queued from
// the loop's own thread (a task it resumed, say) takes no lock at all.
import CEventLoop
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if !os(Linux)
/// kevent(2). In a call, Darwin's `kevent` names its struct, so the function is reached through this.
private let systemKevent: @Sendable (Int32, UnsafePointer<kevent>?, Int32, UnsafeMutablePointer<kevent>?, Int32,
                                     UnsafePointer<timespec>?) -> Int32 = kevent
#endif

/// A file descriptor's owner, called back on its loop when the descriptor is ready. A hang-up or an error comes as
/// readable, so the next read finds it.
protocol LoopSource: AnyObject {
    func ready(readable: Bool, writable: Bool)
}

/// A source's registration: its slot in the loop's table and that slot's generation, so an event still in the batch
/// being dispatched can't reach whatever took the slot after the source closed.
struct LoopToken: Sendable {
    fileprivate let slot: UInt32
    fileprivate let generation: UInt32

    fileprivate var packed: UInt64 { UInt64(generation) << 32 | UInt64(slot) }
}

/// A value only its loop touches, carried through other threads to be used back on that loop.
struct LoopBound<Value>: @unchecked Sendable {
    let loop: Loop
    private let wrapped: Value

    init(_ value: Value, loop: Loop) {
        self.loop = loop
        wrapped = value
    }

    var value: Value {
        assert(loop.inLoop, "a loop-bound value used off its loop")
        return wrapped
    }
}

final class Loop: TaskExecutor, @unchecked Sendable {
    /// One loop per core, each started with its thread on first use.
    static let all: [Loop] = (0..<System.coreCount).map { Loop(index: $0) }
    private static let turn = Atomic<Int>(0)
    /// The loop the calling thread runs, if any. (No call with a side effect goes inside a precondition here: the
    /// package builds with -Ounchecked, which doesn't evaluate them.)
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        let rc = pthread_key_create(&key, nil)
        if rc != 0 { fatalError("pthread_key_create: \(rc)") }
        return key
    }()

    /// The loops in turn, for work that has no loop of its own yet (a lane; on macOS, an accepted connection).
    static func next() -> Loop {
        all[turn.wrappingAdd(1, ordering: .relaxed).oldValue % all.count]
    }

    let index: Int

    private enum Local {
        case closure(() -> Void)
        case job(UnownedJob)
    }

    private enum Remote: Sendable {
        case closure(@Sendable () -> Void)
        case job(UnownedJob)
    }

    private struct Slot {
        var source: (any LoopSource)?
        var generation: UInt32
    }

    private struct Timer {
        var due: UInt64
        let interval: UInt64
        let body: () -> Void
    }

    // Shared with other threads.
    private let remote = Mutex<[Remote]>([])
    /// The loop is about to block, or blocked, waiting: whoever queues work for it next wakes it.
    private let sleeping = Atomic<Bool>(false)

    // The loop's thread only.
    private var local: [Local] = []
    private var running: [Local] = []
    private var incoming: [Remote] = []
    private var sources: [Slot] = []
    private var freeSlots: [UInt32] = []
    private var timers: [Timer] = []

    #if os(Linux)
    private let epoll: Int32
    private let wakeFD: Int32
    private static let wakeToken = UInt64.max
    private var events = [epoll_event](repeating: epoll_event(), count: 512)
    #else
    private let kq: Int32
    private var events: [kevent] = Array(repeating: kevent(), count: 512)
    #endif

    private init(index: Int) {
        self.index = index
        #if os(Linux)
        epoll = epoll_create1(Int32(EPOLL_CLOEXEC))
        wakeFD = eventfd(0, Int32(EFD_NONBLOCK | EFD_CLOEXEC))
        if epoll < 0 || wakeFD < 0 { fatalError("epoll_create1/eventfd: \(errno)") }
        var event = epoll_event()
        event.events = EPOLLIN.rawValue
        event.data.u64 = Self.wakeToken
        if epoll_ctl(epoll, EPOLL_CTL_ADD, wakeFD, &event) != 0 { fatalError("epoll_ctl: \(errno)") }
        #else
        kq = kqueue()
        if kq < 0 { fatalError("kqueue: \(errno)") }
        var event = kevent(ident: 0, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        if systemKevent(kq, &event, 1, nil, 0, nil) != 0 { fatalError("kevent: \(errno)") }
        #endif
        startThread(name: "loop-\(index)") { [unowned self] in self.run() }
    }

    /// Whether the calling thread is this loop's.
    var inLoop: Bool {
        pthread_getspecific(Self.key) == Unmanaged.passUnretained(self).toOpaque()
    }

    // ---------- queued work ----------

    /// Runs `work` on this loop: in its next turn, or after what is running now if called from the loop itself.
    func execute(_ work: @escaping @Sendable () -> Void) {
        if inLoop { local.append(.closure(work)) } else { submit(.closure(work)) }
    }

    /// Runs `work` after what this loop is running now; from the loop's own thread, so `work` may capture what only
    /// this loop touches.
    func later(_ work: @escaping () -> Void) {
        assert(inLoop, "Loop.later off its loop")
        local.append(.closure(work))
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        if inLoop { local.append(.job(job)) } else { submit(.job(job)) }
    }

    private func submit(_ work: Remote) {
        remote.withLock { $0.append(work) }
        if sleeping.exchange(false, ordering: .sequentiallyConsistent) { wake() }
    }

    private func wake() {
        #if os(Linux)
        var one: UInt64 = 1
        _ = write(wakeFD, &one, 8)
        #else
        var event = kevent(ident: 0, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
        _ = systemKevent(kq, &event, 1, nil, 0, nil)
        #endif
    }

    /// The other threads' work, then this loop's own, until none is left (bounded, so a chain of jobs that keeps
    /// queueing more can't starve the descriptors).
    private func runQueued() {
        remote.withLock { swap(&$0, &incoming) }
        for work in incoming {
            switch work {
            case .closure(let body): body()
            case .job(let job): job.runSynchronously(on: asUnownedTaskExecutor())
            }
        }
        incoming.removeAll(keepingCapacity: true)
        var rounds = 0
        while !local.isEmpty, rounds < 16 {
            swap(&local, &running)
            for work in running {
                switch work {
                case .closure(let body): body()
                case .job(let job): job.runSynchronously(on: asUnownedTaskExecutor())
                }
            }
            running.removeAll(keepingCapacity: true)
            rounds += 1
        }
    }

    // ---------- timers ----------

    /// Calls `body` on this loop every `interval`, from this loop's own thread.
    func every(_ interval: Duration, _ body: @escaping () -> Void) {
        assert(inLoop, "Loop.every off its loop")
        let nanos = UInt64(interval.components.seconds) * 1_000_000_000 + UInt64(interval.components.attoseconds / 1_000_000_000)
        timers.append(Timer(due: Self.now() + nanos, interval: nanos, body: body))
    }

    private static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    /// Milliseconds until the next timer is due; -1 for none.
    private func timerTimeout() -> Int32 {
        guard let due = timers.lazy.map(\.due).min() else { return -1 }
        let now = Self.now()
        return due <= now ? 0 : Int32(min((due - now + 999_999) / 1_000_000, UInt64(Int32.max)))
    }

    private func runTimers() {
        let now = Self.now()
        for i in timers.indices where timers[i].due <= now {
            timers[i].due = now + timers[i].interval
            timers[i].body()
        }
    }

    // ---------- descriptors ----------

    /// Watches `fd` for `source`, from this loop's own thread, until `unregister`.
    func register(_ fd: Int32, _ source: any LoopSource, readable: Bool, writable: Bool) -> LoopToken {
        assert(inLoop, "Loop.register off its loop")
        let slot: UInt32
        if let free = freeSlots.popLast() {
            slot = free
        } else {
            slot = UInt32(sources.count)
            sources.append(Slot(source: nil, generation: 1))
        }
        sources[Int(slot)].source = source
        let token = LoopToken(slot: slot, generation: sources[Int(slot)].generation)
        #if os(Linux)
        var event = epoll_event()
        event.events = Self.mask(readable: readable, writable: writable)
        event.data.u64 = token.packed
        if epoll_ctl(epoll, EPOLL_CTL_ADD, fd, &event) != 0 { App.logger.error("epoll_ctl ADD: \(errno)") }
        #else
        change(fd, token, readable: readable, writable: writable)
        #endif
        return token
    }

    /// Changes what `fd` is watched for.
    func watch(_ fd: Int32, _ token: LoopToken, readable: Bool, writable: Bool) {
        assert(inLoop, "Loop.watch off its loop")
        #if os(Linux)
        var event = epoll_event()
        event.events = Self.mask(readable: readable, writable: writable)
        event.data.u64 = token.packed
        if epoll_ctl(epoll, EPOLL_CTL_MOD, fd, &event) != 0 { App.logger.error("epoll_ctl MOD: \(errno)") }
        #else
        change(fd, token, readable: readable, writable: writable)
        #endif
    }

    /// Forgets the source; its descriptor is closed right after (which takes it out of epoll or kqueue).
    func unregister(_ token: LoopToken) {
        assert(inLoop, "Loop.unregister off its loop")
        let slot = Int(token.slot)
        guard slot < sources.count, sources[slot].generation == token.generation else { return }
        sources[slot].source = nil
        sources[slot].generation = sources[slot].generation == UInt32.max ? 1 : sources[slot].generation + 1
        freeSlots.append(token.slot)
    }

    private func source(_ packed: UInt64) -> (any LoopSource)? {
        let slot = Int(UInt32(truncatingIfNeeded: packed))
        guard slot < sources.count, sources[slot].generation == UInt32(truncatingIfNeeded: packed >> 32) else { return nil }
        return sources[slot].source
    }

    #if os(Linux)
    private static func mask(readable: Bool, writable: Bool) -> UInt32 {
        (readable ? EPOLLIN.rawValue : 0) | (writable ? EPOLLOUT.rawValue : 0)
    }
    #else
    private func change(_ fd: Int32, _ token: LoopToken, readable: Bool, writable: Bool) {
        let udata = UnsafeMutableRawPointer(bitPattern: UInt(token.packed))
        var changes = [
            kevent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | (readable ? EV_ENABLE : EV_DISABLE)),
                   fflags: 0, data: 0, udata: udata),
            kevent(ident: UInt(fd), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | (writable ? EV_ENABLE : EV_DISABLE)),
                   fflags: 0, data: 0, udata: udata),
        ]
        if systemKevent(kq, &changes, 2, nil, 0, nil) != 0 { App.logger.error("kevent: \(errno)") }
    }
    #endif

    // ---------- the loop ----------

    private func run() {
        pthread_setspecific(Self.key, Unmanaged.passUnretained(self).toOpaque())
        while true {
            runQueued()
            var timeout = local.isEmpty ? timerTimeout() : 0
            if timeout != 0 {
                sleeping.store(true, ordering: .sequentiallyConsistent)
                if remote.withLock({ !$0.isEmpty }) { timeout = 0 }
            }
            let ready = poll(timeout)
            sleeping.store(false, ordering: .sequentiallyConsistent)
            dispatch(ready)
            if !timers.isEmpty { runTimers() }
        }
    }

    #if os(Linux)
    private func poll(_ timeout: Int32) -> Int {
        let n = epoll_wait(epoll, &events, Int32(events.count), timeout)
        return n < 0 ? 0 : Int(n) // EINTR
    }

    private func dispatch(_ count: Int) {
        for i in 0..<count {
            let event = events[i]
            let packed = event.data.u64
            if packed == Self.wakeToken {
                var drained: UInt64 = 0
                _ = read(wakeFD, &drained, 8)
                continue
            }
            let flags = event.events
            let failed = flags & (EPOLLHUP.rawValue | EPOLLERR.rawValue) != 0
            source(packed)?.ready(readable: failed || flags & EPOLLIN.rawValue != 0,
                                  writable: failed || flags & EPOLLOUT.rawValue != 0)
        }
    }
    #else
    private func poll(_ timeout: Int32) -> Int {
        var n: Int32
        if timeout < 0 {
            n = systemKevent(kq, nil, 0, &events, Int32(events.count), nil)
        } else {
            var ts = timespec(tv_sec: Int(timeout / 1000), tv_nsec: Int(timeout % 1000) * 1_000_000)
            n = systemKevent(kq, nil, 0, &events, Int32(events.count), &ts)
        }
        return n < 0 ? 0 : Int(n) // EINTR
    }

    private func dispatch(_ count: Int) {
        for i in 0..<count {
            let event = events[i]
            if event.filter == Int16(EVFILT_USER) { continue }
            let packed = UInt64(UInt(bitPattern: event.udata))
            let readable = event.filter == Int16(EVFILT_READ) || event.flags & UInt16(EV_EOF) != 0
            source(packed)?.ready(readable: readable, writable: event.filter == Int16(EVFILT_WRITE))
        }
    }
    #endif
}
