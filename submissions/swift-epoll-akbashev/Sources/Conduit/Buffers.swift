// The Rust's `Vec<u8>` and `Vec<T>`, as noncopyable owners. A buffer has exactly one owner and moves instead of
// being copied, so its array is always uniquely referenced and appending never copies it; what reads a buffer borrows
// a `Span` of it, whose lifetime the compiler ties to the borrow. A finished body leaves its buffer as a plain
// `[UInt8]` (`take()`, no copy): immutable and Sendable, it can go to another thread or to several connections at
// once, which is what the Rust's `Arc<[u8]>` shared bodies are for.

/// A growable byte buffer (Rust's `Vec<u8>`). An empty one holds no memory, so an idle connection costs nothing.
struct ByteBuffer: ~Copyable, Sendable {
    private(set) var bytes: [UInt8] = []

    init() {}

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    @inline(__always) var count: Int { bytes.count }
    @inline(__always) var isEmpty: Bool { bytes.isEmpty }
    @inline(__always) var capacity: Int { bytes.capacity }

    @inline(__always) mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    @inline(__always) mutating func append(_ raw: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: raw)
    }

    @inline(__always) mutating func append(_ literal: StaticString) {
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
    }

    @inline(__always) mutating func append(_ span: Span<UInt8>) {
        span.withUnsafeBytes { bytes.append(contentsOf: $0) }
    }

    @inline(__always) mutating func append(_ other: borrowing [UInt8]) {
        other.withUnsafeBytes { bytes.append(contentsOf: $0) }
    }

    /// Appends bytes `range` of `other`.
    @inline(__always) mutating func append(_ other: borrowing ByteBuffer, _ range: Range<Int>) {
        bytes.append(contentsOf: other.bytes[range])
    }

    @inline(__always) mutating func append(repeating byte: UInt8, count n: Int) {
        bytes.append(contentsOf: repeatElement(byte, count: n))
    }

    /// Lets `body` fill up to `maximum` bytes past the end (a socket read straight into the buffer, through an
    /// `OutputSpan`); returns what `body` returned, and keeps that many bytes if it is positive.
    @inline(__always) mutating func appendSpare(maximum: Int, _ body: (UnsafeMutableRawBufferPointer) -> Int) -> Int {
        var result = 0
        bytes.append(addingCapacity: maximum) { (out: inout OutputSpan<UInt8>) in
            result = out.withUnsafeMutableBufferPointer { spare, initialized in
                let n = body(UnsafeMutableRawBufferPointer(spare))
                if n > 0 { initialized = n }
                return n
            }
        }
        return result
    }

    @inline(__always) subscript(i: Int) -> UInt8 {
        get { bytes[i] }
        set { bytes[i] = newValue }
    }

    /// Writes `value` big-endian at `offset` (a length patched in after the fact).
    @inline(__always) mutating func storeBigEndian(_ value: UInt32, at offset: Int) {
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self) }
    }

    /// Keeps the memory (Rust's `clear()`).
    @inline(__always) mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    /// Clears, and gives memory back past `threshold` bytes, keeping `limit` (Rust's `clear()` + `shrink_to`).
    mutating func removeAll(shrinkingAbove threshold: Int, to limit: Int) {
        if bytes.capacity > threshold {
            bytes = []
            bytes.reserveCapacity(limit)
        } else {
            bytes.removeAll(keepingCapacity: true)
        }
    }

    /// Frees the memory (Rust's `= Vec::new()`).
    @inline(__always) mutating func release() {
        bytes = []
    }

    @inline(__always) mutating func truncate(_ n: Int) {
        if n < bytes.count { bytes.removeLast(bytes.count - n) }
    }

    /// Drops the first `n` bytes (Rust's `drain(..n)`).
    @inline(__always) mutating func removeFirst(_ n: Int) {
        bytes.removeFirst(n)
    }

    var span: Span<UInt8> {
        @_lifetime(borrow self) borrowing get { bytes.span }
    }

    @inline(__always) func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    @inline(__always) mutating func withMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeMutableBytes(body)
    }

    /// The finished bytes, moved out without a copy.
    consuming func take() -> [UInt8] { bytes }
}

/// A growable array of noncopyable elements (Rust's `Vec<T>` where T owns memory): the connection slots of a reactor,
/// each holding its own buffers. Elements are reached in place through `unsafeAddress`, never copied.
struct UniqueArray<Element: ~Copyable>: ~Copyable {
    private var base: UnsafeMutablePointer<Element>
    private(set) var count: Int = 0
    private var capacity: Int

    init(capacity: Int = 0) {
        self.capacity = Swift.max(capacity, 1)
        base = .allocate(capacity: self.capacity)
    }

    deinit {
        base.deinitialize(count: count)
        base.deallocate()
    }

    @inline(__always) subscript(i: Int) -> Element {
        unsafeAddress { UnsafePointer(base + i) }
        unsafeMutableAddress { base + i }
    }

    @inline(__always) mutating func append(_ element: consuming Element) {
        if count == capacity { grow(to: count + 1) }
        (base + count).initialize(to: element)
        count += 1
    }

    @inline(never) private mutating func grow(to needed: Int) {
        let next = Swift.max(needed, capacity * 2)
        let fresh = UnsafeMutablePointer<Element>.allocate(capacity: next)
        fresh.moveInitialize(from: base, count: count)
        base.deallocate()
        base = fresh
        capacity = next
    }
}
