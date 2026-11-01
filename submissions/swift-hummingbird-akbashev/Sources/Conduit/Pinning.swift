// Connections pinned to their event loops (PIN_CONNECTIONS=0 turns it off). Hummingbird runs each connection's task
// (reading its requests, running the handlers, writing the responses) on Swift's cooperative pool, so every request
// crosses from the connection's event loop to the pool and back. Pinned, the task runs on the event loop that owns the
// connection: only a read's batch result, a write's commit and bcrypt cross threads. Measured: 8-17% less server CPU
// per request, and the same or more requests per second.
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import NIOPosix

/// Hummingbird's HTTP/1 channel, with each connection's task preferring its own event loop's executor.
struct LoopPinnedHTTP1Channel: ServerChildChannel {
    let inner: HTTP1Channel
    let executors: EventLoopTaskExecutors

    func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<HTTP1Channel.Value> {
        inner.setup(channel: channel, logger: logger)
    }

    func handle(value: HTTP1Channel.Value, logger: Logger) async {
        await withTaskExecutorPreference(executors.executor(for: value.channel.eventLoop)) {
            await inner.handle(value: value, logger: logger)
        }
    }
}

/// A TaskExecutor for each event loop of the group, made once at startup.
final class EventLoopTaskExecutors: Sendable {
    private let byLoop: [ObjectIdentifier: EventLoopTaskExecutor]

    init(_ group: MultiThreadedEventLoopGroup) {
        byLoop = Dictionary(uniqueKeysWithValues: group.makeIterator().map { (ObjectIdentifier($0), EventLoopTaskExecutor($0)) })
    }

    func executor(for loop: any EventLoop) -> EventLoopTaskExecutor? {
        byLoop[ObjectIdentifier(loop)]
    }
}

/// Runs a task's jobs on one event loop.
final class EventLoopTaskExecutor: TaskExecutor {
    private let loop: any EventLoop

    init(_ loop: any EventLoop) {
        self.loop = loop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
