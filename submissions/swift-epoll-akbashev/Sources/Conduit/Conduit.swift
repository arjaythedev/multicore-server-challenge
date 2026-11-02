// main.rs: configuration, the start-up checks (bcrypt calibration, every statement prepared once), and the server
// itself as one task group: a child task per actor, each starting on that actor's own event loop. The Rust's thread
// layout, one actor per thread: IO reactors (cores / 2), read lanes (cores), the write lane, bcrypt workers
// (cores / 2, at least 3), and the scheduler that holds the queues.
import Glibc

private func env(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

private func envInt(_ name: String, _ fallback: Int) -> Int {
    env(name).flatMap { Int($0) } ?? fallback
}

@main
struct Conduit {
    static func main() async {
        tuneProcess()
        guard let databaseURL = env("DATABASE_URL") else { fatalError("DATABASE_URL must be set") }
        guard let jwtSecret = env("JWT_SECRET") else { fatalError("JWT_SECRET must be set") }
        let host = env("HOST") ?? "0.0.0.0"
        let port = UInt16(envInt("PORT", 80))
        let cores = availableParallelism()

        let ioWorkers = envInt("IO_THREADS", max(cores / 2, 2))
        let readWorkers = envInt("READ_LANES", max(cores, 4))
        let writeWorkers = envInt("WRITE_LANES", 1)
        let cryptoWorkers = envInt("BCRYPT_THREADS", max(cores / 2, 3))

        let calibrationStart = monotonicNanos()
        let (autoLanes, autoKernel, seedBcryptUs, l1dKB) = calibrateBcryptHardware()
        let calibrationMs = (monotonicNanos() - calibrationStart) / 1_000_000
        let bcryptLanes = envInt("BCRYPT_LANES", autoLanes)
        let bcryptKernel = env("BCRYPT_KERNEL").flatMap(BcryptKernel.init(name:)) ?? autoKernel

        let signer = TokenSigner(secret: Array(jwtSecret.utf8))
        guard let db = DbEndpoint(url: databaseURL) else { fatalError("invalid DATABASE_URL") }
        do {
            var probe = try PgConn.connect(db)
            try probe.prepareBatch(readCatalog() + writeCatalog())
        } catch {
            fatalError("PostgreSQL statement preparation failed: \(error)")
        }
        let fdBudget = probeNofileLimit()

        let scheduler = Scheduler(loop: EventLoop(name: "scheduler"), readWorkers: readWorkers, bcryptLanes: bcryptLanes,
                                  seedBcryptUs: seedBcryptUs)
        let reactors = (0..<ioWorkers).map {
            Reactor(index: $0, loop: EventLoop(name: "io-reactor"), signer: signer, scheduler: scheduler,
                    host: host, port: port, fdBudget: fdBudget)
        }
        let readLanes = (0..<readWorkers).map { _ in
            ReadLane(loop: EventLoop(name: "db-read"), db: db, scheduler: scheduler, reactors: reactors)
        }
        let writeLanes = (0..<writeWorkers).map { _ in
            WriteLane(loop: EventLoop(name: "db-write"), db: db, scheduler: scheduler, reactors: reactors, signer: signer)
        }
        let crypto = (0..<cryptoWorkers).map { _ in
            CryptoWorker(loop: EventLoop(name: "crypto"), scheduler: scheduler, reactors: reactors, signer: signer,
                         kernel: bcryptKernel)
        }

        logLine("listening on \(host):\(port) (\(ioWorkers) io, \(readWorkers) read, \(writeWorkers) write, "
            + "\(cryptoWorkers)x\(bcryptLanes) crypto (\(bcryptKernel) kernel), L1D=\(l1dKB)KB, nofile=\(fdBudget)/io, "
            + "bcrypt cost 10 = \(seedBcryptUs / 1000) ms per \(autoLanes)-lane batch, calibrated in \(calibrationMs) ms)")

        await withDiscardingTaskGroup { group in
            group.addTask(executorPreference: scheduler.loop) { await scheduler.run() }
            for lane in readLanes { group.addTask(executorPreference: lane.loop) { await lane.run() } }
            for lane in writeLanes { group.addTask(executorPreference: lane.loop) { await lane.run() } }
            for worker in crypto { group.addTask(executorPreference: worker.loop) { await worker.run() } }
            for reactor in reactors { group.addTask(executorPreference: reactor.loop) { await reactor.run() } }
        }
    }
}
