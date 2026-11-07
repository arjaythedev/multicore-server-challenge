#if os(Linux)
import CShim
import CBcrypt
import CUring

func environment(_ name: StaticString) -> UnsafePointer<CChar>? {
    sv_getenv(UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: CChar.self))
}

func fail(_ message: StaticString) -> Never {
    _ = write(2, message.utf8Start, message.utf8CodeUnitCount)
    _ = write(2, "\n", 1)
    exit(1)
}

/// Listening sockets per reactor. Each has its own queue, capped at net.core.somaxconn.
let listenersPerReactor = 2

final class ReactorConfig: @unchecked Sendable {
    let shared: Shared
    let secret: ByteView
    let host: UnsafePointer<CChar>
    let port: Int32
    let slots: Int
    let index: Int

    init(shared: Shared, secret: ByteView, host: UnsafePointer<CChar>, port: Int32, slots: Int, index: Int) {
        self.shared = shared
        self.secret = secret
        self.host = host
        self.port = port
        self.slots = slots
        self.index = index
    }
}

final class PlannerConfig: @unchecked Sendable {
    let shared: Shared
    let url: DatabaseURL
    let secret: ByteView
    let lanes: [(lane: Int, connections: Int)]
    let writes: Bool

    init(shared: Shared, url: DatabaseURL, secret: ByteView, lanes: [(lane: Int, connections: Int)], writes: Bool) {
        self.shared = shared
        self.url = url
        self.secret = secret
        self.lanes = lanes
        self.writes = writes
    }
}

/// Postgres does more than half of the work on this box, and a thread that lets it run first only
/// finds fuller batches when it gets the CPU back.
func tuneThread() {
    _ = sv_tune_thread(5, 1)
}

/// One reactor's whole life. The ring is created here, on the thread that uses it
/// (IORING_SETUP_SINGLE_ISSUER).
func runReactor(_ config: ReactorConfig) -> Never {
    tuneThread()
    var listeners: [Int32] = []
    for _ in 0..<listenersPerReactor {
        let fd = sv_listen(config.host, config.port, 65535, 1)
        guard fd >= 0 else { fail("cannot listen") }
        listeners.append(fd)
    }
    guard let server = Server(shared: config.shared, secret: config.secret, listeners: listeners, slots: config.slots,
                              reactorIndex: config.index) else {
        fail("io_uring setup failed")
    }
    server.run()
}

/// Thread entry points. Global functions, so they aren't isolated to the main actor.
func reactorThread(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    runReactor(Unmanaged<ReactorConfig>.fromOpaque(raw.unsafelyUnwrapped).takeRetainedValue())
}

func plannerThread(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    let config = Unmanaged<PlannerConfig>.fromOpaque(raw.unsafelyUnwrapped).takeRetainedValue()
    tuneThread()
    guard let planner = Planner(shared: config.shared, url: config.url, secret: config.secret, lanes: config.lanes,
                                writes: config.writes) else {
        fail("io_uring setup failed")
    }
    config.shared.markReady()
    planner.run()
}

@main
struct Main {
    static func main() {
        guard let databaseURL = environment("DATABASE_URL") else { fail("DATABASE_URL is not set") }
        guard let url = DatabaseURL(databaseURL) else { fail("cannot parse DATABASE_URL") }
        guard let secret = environment("JWT_SECRET") else { fail("JWT_SECRET is not set") }
        let host = environment("HOST") ?? UnsafeRawPointer(("0.0.0.0" as StaticString).utf8Start).assumingMemoryBound(to: CChar.self)
        let port: Int32 = environment("PORT").map { atoi($0) } ?? 80
        guard tu_probe() != 0 else { fail("io_uring is not available") }

        sv_ignore_sigpipe()
        let slots = Int(sv_raise_nofile())
        let cpus = Int(sv_cpu_count())
        let reactors = max(cpus / 2, 1)
        bc_start(Int32(max(cpus / 4, 2)), 1)
        let view = ByteView(base: UnsafeRawPointer(secret).assumingMemoryBound(to: UInt8.self), count: strlen(secret))
        let shared = Shared(reactors: reactors)
        // One planner owns every read connection, so the dispatcher can move them between lanes. The
        // counts only set the pool size: any connection serves any lane. Writes get their own thread
        // and one connection: a commit at a time, with everything that gathers meanwhile in the next.
        let plans: [([(lane: Int, connections: Int)], Bool)] = [
            ([(fastLane, 2), (commentsLane, 2), (listsLane, 2), (feedLane, 2)], false),
            ([], true),
        ]
        for (lanes, writes) in plans {
            let config = PlannerConfig(shared: shared, url: url, secret: view, lanes: lanes, writes: writes)
            guard sv_spawn(plannerThread, Unmanaged.passRetained(config).toOpaque()) == 0 else { fail("cannot start a planner") }
        }
        while shared.readyCount() < plans.count { _ = usleep(10000) }
        for i in 1..<max(reactors, 1) {
            let config = ReactorConfig(shared: shared, secret: view, host: host, port: port, slots: slots, index: i)
            guard sv_spawn(reactorThread, Unmanaged.passRetained(config).toOpaque()) == 0 else { fail("cannot start a reactor") }
        }
        runReactor(ReactorConfig(shared: shared, secret: view, host: host, port: port, slots: slots, index: 0))
    }
}
#else
@main
struct Main {
    static func main() { fatalError("this server runs on Linux only") }
}
#endif
