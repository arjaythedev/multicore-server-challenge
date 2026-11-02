// Logging, in place of swift-log: one line per message on standard error, with the time, the level, the logger's
// label and any metadata. The server logs only what goes wrong, and its start.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct Logger: Sendable {
    let label: String

    init(label: String) {
        self.label = label
    }

    func info(_ message: @autoclosure () -> String, metadata: @autoclosure () -> [String: String] = [:]) {
        log("info", message(), metadata())
    }

    func warning(_ message: @autoclosure () -> String, metadata: @autoclosure () -> [String: String] = [:]) {
        log("warning", message(), metadata())
    }

    func error(_ message: @autoclosure () -> String, metadata: @autoclosure () -> [String: String] = [:]) {
        log("error", message(), metadata())
    }

    func critical(_ message: @autoclosure () -> String, metadata: @autoclosure () -> [String: String] = [:]) {
        log("critical", message(), metadata())
    }

    private func log(_ level: String, _ message: String, _ metadata: [String: String]) {
        var now = time(nil)
        var parts = tm()
        localtime_r(&now, &parts)
        var stamp = [CChar](repeating: 0, count: 32)
        _ = strftime(&stamp, stamp.count, "%Y-%m-%dT%H:%M:%S%z", &parts)
        var line = "\(String(decoding: stamp.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) \(level) \(label): \(message)"
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) { line += " \(key)=\(value)" }
        line += "\n"
        // One write(2) per line, straight to descriptor 2, so lines from different threads don't mix.
        var bytes = Array(line.utf8)
        _ = bytes.withUnsafeMutableBytes { write(2, $0.baseAddress, $0.count) }
    }
}
