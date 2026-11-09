// main.rs: configuration, the start-up checks (bcrypt calibration, every statement prepared once), and the server
// itself as one root task holding a task group: a child task per actor, each starting on that actor's own event loop.
// The Rust's thread layout, one actor per thread: IO reactors (cores / 2), read lanes (cores), write lanes (cores / 2,
// 2 to 4) and bcrypt workers (cores / 2, at least 3). The scheduler that holds the queues is shared state behind a
// lock, as in the Rust. `main` is synchronous and its thread becomes reactor 0's, so every thread is an actor's: an
// `async` main would start on Swift's global executor, which brings up libdispatch's threads that nothing else uses.
import Glibc

@main
struct Conduit {
    static func main() {
        Sys.tuneProcess()
        guard let databaseURL = env("DATABASE_URL") else { fatalError("DATABASE_URL must be set") }
        guard let jwtSecret = env("JWT_SECRET") else { fatalError("JWT_SECRET must be set") }
        let host = env("HOST") ?? "0.0.0.0"
        let port = UInt16(envInt("PORT", 80))
        let cores = Sys.availableParallelism()

        let ioWorkers = envInt("IO_THREADS", max(cores / 2, 2))
        let readWorkers = envInt("READ_LANES", max(cores, 4))
        let writeWorkers = envInt("WRITE_LANES", min(max(cores / 2, 2), 4))
        let cryptoWorkers = envInt("BCRYPT_THREADS", max(cores / 2, 3))
        let passNanos = UInt64(max(envInt("PASS_US", 2000), 0)) * 1000
        // Under full CPU, Postgres and the lanes run before the reactors, and the bcrypt workers after everything else
        // but the first of them (which keeps logins moving).
        let loopNice = Int32(envInt("LOOP_NICE", 5))
        let bcryptNice = Int32(envInt("BCRYPT_NICE", 10))

        let calibrationStart = Sys.monotonicNanos()
        let (autoLanes, autoKernel, seedBcryptUs, l1dKB) = Bcrypt.calibrate()
        let calibrationMs = (Sys.monotonicNanos() - calibrationStart) / 1_000_000
        let bcryptLanes = envInt("BCRYPT_LANES", autoLanes)
        let bcryptKernel = env("BCRYPT_KERNEL").flatMap(Bcrypt.Kernel.init(name:)) ?? autoKernel

        let signer = TokenSigner(secret: Array(jwtSecret.utf8))
        guard let db = DbEndpoint(url: databaseURL) else { fatalError("invalid DATABASE_URL") }
        do {
            var probe = try PgConn.connect(db)
            try probe.prepareBatch(Catalog.reads() + Catalog.writes())
        } catch {
            fatalError("PostgreSQL statement preparation failed: \(error)")
        }
        let fdBudget = Sys.probeNofileLimit()

        let scheduler = Scheduler(readWorkers: readWorkers, bcryptLanes: bcryptLanes, seedBcryptUs: seedBcryptUs,
                                  fullBcryptSets: env("BCRYPT_WAIT") != "capped")
        // Reactor 0's loop is the main thread's, which runs it once start-up is done.
        let mainLoop = EventLoop(name: "io-reactor", nice: loopNice, onCallingThread: true)
        let reactors = (0..<ioWorkers).map {
            Reactor(index: $0, loop: $0 == 0 ? mainLoop : EventLoop(name: "io-reactor", nice: loopNice), signer: signer,
                    scheduler: scheduler, host: host, port: port, fdBudget: fdBudget, passNanos: passNanos)
        }
        let readLanes = (0..<readWorkers).map { _ in
            ReadLane(loop: EventLoop(name: "db-read"), db: db, scheduler: scheduler, reactors: reactors)
        }
        let writeLanes = (0..<writeWorkers).map { _ in
            WriteLane(loop: EventLoop(name: "db-write"), db: db, scheduler: scheduler, reactors: reactors, signer: signer)
        }
        let crypto = (0..<cryptoWorkers).map { i in
            CryptoWorker(loop: EventLoop(name: "crypto", nice: i == 0 ? 0 : bcryptNice), scheduler: scheduler,
                         reactors: reactors, signer: signer, kernel: bcryptKernel)
        }

        Sys.logLine("listening on \(host):\(port) (\(ioWorkers) io, \(readWorkers) read, \(writeWorkers) write, "
            + "\(cryptoWorkers)x\(bcryptLanes) crypto (\(bcryptKernel) kernel), L1D=\(l1dKB)KB, nofile=\(fdBudget)/io, "
            + "bcrypt cost 10 = \(seedBcryptUs / 1000) ms per \(autoLanes)-lane batch, calibrated in \(calibrationMs) ms, "
            + "SHA-256 \(SHA256.usesExtensions ? "on the CPU's SHA extensions" : "in Swift"))")

        // The server's root task, on reactor 0's loop: it starts every actor as a child and waits on them for good.
        Task(executorPreference: mainLoop) {
            await withDiscardingTaskGroup { group in
                for lane in readLanes { group.addTask(executorPreference: lane.loop) { await lane.run() } }
                for lane in writeLanes { group.addTask(executorPreference: lane.loop) { await lane.run() } }
                for worker in crypto { group.addTask(executorPreference: worker.loop) { await worker.run() } }
                for reactor in reactors { group.addTask(executorPreference: reactor.loop) { await reactor.run() } }
            }
        }
        mainLoop.runOnCallingThread()
    }
}

extension Conduit {
    private static func env(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    private static func envInt(_ name: String, _ fallback: Int) -> Int {
        env(name).flatMap { Int($0) } ?? fallback
    }
}
