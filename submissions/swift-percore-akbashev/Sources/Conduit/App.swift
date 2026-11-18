// App state and the bcrypt executor.
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct App: Sendable {
    let signer: JWTSigner
    let bcrypt: BcryptWorkers
    /// Batched reads (Reads.swift).
    let reads: ReadBatcher
    /// Group-committed writes (Writes.swift).
    let writes: WriteBatcher

    static let logger = Logger(label: "conduit.app")
}

/// A TaskExecutor on threads of its own, for the bcrypt workers: their number caps how many cores a burst of logins can
/// take from the loops. Jobs wait in one queue under a mutex, and an idle thread sleeps on its condition variable.
final class ThreadPoolExecutor: TaskExecutor, @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let ready = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    /// Guarded by `mutex`.
    private var queue: [UnownedJob] = []

    init(threads: Int) {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(ready, nil)
        for i in 0..<threads {
            startThread(name: "bcrypt-\(i)") { [unowned self] in self.work() }
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        pthread_mutex_lock(mutex)
        queue.append(job)
        pthread_cond_signal(ready)
        pthread_mutex_unlock(mutex)
    }

    private func work() {
        while true {
            pthread_mutex_lock(mutex)
            while queue.isEmpty { pthread_cond_wait(ready, mutex) }
            let job = queue.removeFirst()
            pthread_mutex_unlock(mutex)
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    /// The threads stay parked until the process exits; nothing is left queued once the workers have stopped.
    func shutdown() async throws {}
}
