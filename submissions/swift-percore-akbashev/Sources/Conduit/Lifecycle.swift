// Running the server's long-lived parts and stopping them, in place of ServiceLifecycle. Each service runs as a task
// until SIGTERM or SIGINT; then they are told to stop in reverse order, each once the ones after it have finished:
// the HTTP server first (so in-flight requests finish), then the write and read lanes, then the bcrypt workers. A
// service that ends on its own, or fails, starts the same shutdown.
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

protocol Service: Sendable {
    func run() async throws
}

/// Returns once the service this task belongs to (it, or any task it started) is told to stop.
func gracefulShutdown() async throws {
    guard let stop = Stop.current else { fatalError("gracefulShutdown() outside a service") }
    await stop.requested()
}

/// One service's stop signal.
final class Stop: Sendable {
    @TaskLocal static var current: Stop?

    private struct State {
        var stopped = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func requested() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.stopped { return true }
                s.waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func trigger() {
        let waiting = state.withLock { s in
            s.stopped = true
            defer { s.waiting = [] }
            return s.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

enum Services {
    /// Runs `services` until a signal, or until one of them ends; rethrows the first error any of them threw.
    static func run(_ services: [any Service], stoppingOn signals: [Int32]) async throws {
        let stops = services.map { _ in Stop() }
        let signalled = Signals.watch(signals)
        let failure: (any Error)? = await withTaskGroup(of: (index: Int, error: (any Error)?).self) { group in
            for (i, service) in services.enumerated() {
                group.addTask {
                    do {
                        try await Stop.$current.withValue(stops[i]) { try await service.run() }
                        return (i, nil)
                    } catch {
                        return (i, error)
                    }
                }
            }
            group.addTask {
                for await _ in signalled { break }
                return (-1, nil)
            }
            var finished = Set<Int>()
            var failure: (any Error)?
            var stopping = false
            /// Tells the last service still running to stop; the others follow as each finishes.
            func stopNext() {
                if let i = services.indices.reversed().first(where: { !finished.contains($0) }) { stops[i].trigger() }
            }
            while let next = await group.next() {
                let (i, error) = (next.index, next.error)
                if i >= 0 {
                    finished.insert(i)
                    if let error, failure == nil {
                        failure = error
                        Conduit.logger.error("service failed", metadata: ["error": "\(error)"])
                    }
                }
                if finished.count == services.count {
                    group.cancelAll() // the signal watcher
                    break
                }
                if i >= 0 || !stopping {
                    stopping = true
                    stopNext()
                }
            }
            return failure
        }
        if let failure { throw failure }
    }
}

/// The write end of the pipe the signal handler writes to: set once, before any handler is installed.
nonisolated(unsafe) private var signalPipe: Int32 = -1

private enum Signals {
    /// The signals as they arrive. A handler (async-signal-safe: one write) passes each to a thread of its own.
    static func watch(_ signals: [Int32]) -> AsyncStream<Int32> {
        var fds: [Int32] = [0, 0]
        if pipe(&fds) != 0 { fatalError("pipe: \(errno)") }
        signalPipe = fds[1]
        for s in signals {
            signal(s) { received in
                var byte = UInt8(truncatingIfNeeded: received)
                _ = write(signalPipe, &byte, 1)
            }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        let reader = fds[0]
        startThread(name: "signals") {
            var byte: UInt8 = 0
            while true {
                let n = read(reader, &byte, 1)
                if n == 1 {
                    continuation.yield(Int32(byte))
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        return stream
    }
}
