// Bytes with one owner, for what is built or received a piece at a time: Postgres requests and replies, a batch's
// rows, a connection's received bytes. Raw memory grown by realloc, read from `start` and written at `end`, and not
// allocated until something is written. ~Copyable, so a buffer is never shared or copied by accident: it is moved
// (swap, consume) where its owner changes, and each write is a capacity check and a store, with no copy-on-write check.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct Bytes: ~Copyable {
    private var base: UnsafeMutableRawPointer?
    private(set) var capacity = 0
    /// The readable bytes are `base[start..<end]`; every offset below counts from `start`.
    private var start = 0
    private var end = 0

    init() {}

    init(capacity: Int) {
        reserve(capacity)
    }

    deinit {
        free(base)
    }

    var count: Int { end - start }
    var isEmpty: Bool { start == end }

    // ---------- writing ----------

    /// Room for `extra` more bytes at the end.
    @inline(__always)
    mutating func reserve(_ extra: Int) {
        if end + extra > capacity { grow(extra) }
    }

    private mutating func grow(_ extra: Int) {
        if start > 0, count + extra <= capacity {
            compact()
            return
        }
        compact()
        var size = max(capacity * 2, 256)
        while size < count + extra { size *= 2 }
        base = realloc(base, size)
        capacity = size
    }

    /// Moves the readable bytes to the front, reclaiming what was consumed.
    mutating func compact() {
        guard start > 0, let base else { return }
        if count > 0 { memmove(base, base + start, count) }
        end -= start
        start = 0
    }

    mutating func append(_ source: UnsafeRawBufferPointer) {
        guard let from = source.baseAddress, source.count > 0 else { return }
        reserve(source.count)
        (base! + end).copyMemory(from: from, byteCount: source.count)
        end += source.count
    }

    mutating func append(_ bytes: Span<UInt8>) {
        bytes.withUnsafeBytes { append($0) }
    }

    /// `other`'s readable bytes from `offset`, `count` of them.
    mutating func append(_ other: borrowing Bytes, from offset: Int, count: Int) {
        guard count > 0 else { return }
        append(UnsafeRawBufferPointer(start: other.base! + other.start + offset, count: count))
    }

    /// A string's UTF-8.
    mutating func append(_ s: String) {
        var s = s
        s.withUTF8 { append(UnsafeRawBufferPointer($0)) }
    }

    mutating func appendNullTerminated(_ s: String) {
        append(s)
        append(integer: UInt8(0))
    }

    /// An integer, big-endian (network order).
    mutating func append<T: FixedWidthInteger>(integer value: T) {
        reserve(MemoryLayout<T>.size)
        (base! + end).storeBytes(of: value.bigEndian, as: T.self)
        end += MemoryLayout<T>.size
    }

    /// Overwrites an integer already written, big-endian.
    mutating func set<T: FixedWidthInteger>(integer value: T, at offset: Int) {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count, "Bytes.set out of range")
        (base! + start + offset).storeBytes(of: value.bigEndian, as: T.self)
    }

    /// Reads from `fd` into the room at the end, making `minimum` bytes of room first. Returns read(2)'s result (the
    /// byte count, 0 at end of stream, or -1 with errno set) and how much room it was given.
    mutating func read(from fd: Int32, minimum: Int) -> (count: Int, room: Int) {
        reserve(minimum)
        let room = capacity - end
        let n = readDescriptor(fd, UnsafeMutableRawBufferPointer(start: base! + end, count: room))
        if n > 0 { end += n }
        return (n, room)
    }

    // ---------- reading ----------

    /// An integer at `offset`, big-endian; nil past the end.
    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        return T(bigEndian: (base! + start + offset).loadUnaligned(as: T.self))
    }

    func string(at offset: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: base! + start + offset, count: count), as: UTF8.self)
    }

    /// A copy of `range`, for the rare message that is parsed field by field.
    func array(_ range: Range<Int>) -> [UInt8] {
        guard !range.isEmpty else { return [] }
        return Array(UnsafeRawBufferPointer(start: base! + start + range.lowerBound, count: range.count))
    }

    /// The readable bytes, for as long as `body` runs.
    func withSpan<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        let buffer = UnsafeBufferPointer(start: base.map { ($0 + start).assumingMemoryBound(to: UInt8.self) }, count: count)
        return try body(Span(_unsafeElements: buffer))
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base.map { $0 + start }, count: count))
    }

    /// Drops `n` bytes from the front.
    mutating func consume(_ n: Int) {
        start += n
        if start == end { clear() }
    }

    /// Empties the buffer, keeping its memory.
    mutating func clear() {
        start = 0
        end = 0
    }

    /// Empties the buffer and gives its memory back.
    mutating func release() {
        free(base)
        base = nil
        capacity = 0
        clear()
    }
}
