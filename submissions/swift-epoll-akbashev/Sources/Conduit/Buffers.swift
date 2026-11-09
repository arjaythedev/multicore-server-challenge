// The Rust's `Vec<u8>` and `Vec<T>`, as noncopyable owners of their memory. A buffer has exactly one owner and moves
// instead of being copied, so appending is what the Rust's `extend_from_slice` is: a capacity check and a memcpy, with
// no uniqueness check (an array's) and no generic append; what reads a buffer borrows a `Span` of it, whose lifetime
// the compiler ties to the borrow, and a read lane lends its batch's bodies to the reactors that way. A body that goes
// on its own leaves its buffer as a plain `[UInt8]` (`take()`): immutable and Sendable, it can go to another thread or
// to several connections at once, which is what the Rust's `Arc<[u8]>` shared bodies are for.

/// A growable byte buffer (Rust's `Vec<u8>`). An empty one holds no memory, so an idle connection costs nothing.
struct ByteBuffer: ~Copyable {
    private var base: UnsafeMutablePointer<UInt8>?
    private(set) var count = 0
    private(set) var capacity = 0

    init() {}

    init(capacity: Int) {
        if capacity > 0 { grow(to: capacity) }
    }

    /// A buffer holding a copy of `span`, exactly its size.
    init(copying span: Span<UInt8>) {
        if span.count > 0 { grow(to: span.count) }
        append(span)
    }

    deinit {
        base?.deallocate()
    }

    @inline(__always) var isEmpty: Bool { count == 0 }

    /// Room for `n` more bytes; the address they go to.
    @inline(__always) private mutating func reserve(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        if capacity - count < n { grow(to: Swift.max(count + n, capacity * 2)) }
        return base! + count
    }

    @inline(never) private mutating func grow(to minimum: Int) {
        let next = Swift.max(minimum, 64)
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        if let base {
            fresh.update(from: base, count: count)
            base.deallocate()
        }
        base = fresh
        capacity = next
    }

    @inline(__always) mutating func append(_ byte: UInt8) {
        reserve(1).pointee = byte
        count += 1
    }

    @inline(__always) mutating func append(_ raw: UnsafeRawBufferPointer) {
        guard let src = raw.baseAddress, raw.count > 0 else { return }
        UnsafeMutableRawPointer(reserve(raw.count)).copyMemory(from: src, byteCount: raw.count)
        count += raw.count
    }

    @inline(__always) mutating func append(_ literal: StaticString) {
        append(UnsafeRawBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
    }

    @inline(__always) mutating func append(_ span: Span<UInt8>) {
        span.withUnsafeBytes { append($0) }
    }

    @inline(__always) mutating func append(_ other: borrowing [UInt8]) {
        other.withUnsafeBytes { append($0) }
    }

    /// Appends bytes `range` of `other`.
    @inline(__always) mutating func append(_ other: borrowing ByteBuffer, _ range: Range<Int>) {
        append(other.span.extracting(range))
    }

    @inline(__always) mutating func append(repeating byte: UInt8, count n: Int) {
        guard n > 0 else { return }
        reserve(n).update(repeating: byte, count: n)
        count += n
    }

    /// Lets `body` fill up to `maximum` bytes past the end (a socket read straight into the buffer); returns what
    /// `body` returned, and keeps that many bytes if it is positive.
    @inline(__always) mutating func appendSpare(maximum: Int, _ body: (UnsafeMutableRawBufferPointer) -> Int) -> Int {
        let spare = UnsafeMutableRawBufferPointer(start: reserve(maximum), count: maximum)
        let n = body(spare)
        if n > 0 { count += n }
        return n
    }

    @inline(__always) subscript(i: Int) -> UInt8 {
        get { base![i] }
        set { base![i] = newValue }
    }

    /// Writes `value` big-endian at `offset` (a length patched in after the fact).
    @inline(__always) mutating func storeBigEndian(_ value: UInt32, at offset: Int) {
        UnsafeMutableRawPointer(base! + offset).storeBytes(of: value.bigEndian, as: UInt32.self)
    }

    /// Keeps the memory (Rust's `clear()`).
    @inline(__always) mutating func removeAll() {
        count = 0
    }

    /// Clears, and gives memory back past `threshold` bytes, keeping `limit` (Rust's `clear()` + `shrink_to`).
    mutating func removeAll(shrinkingAbove threshold: Int, to limit: Int) {
        count = 0
        if capacity > threshold {
            release()
            grow(to: limit)
        }
    }

    /// Frees the memory (Rust's `= Vec::new()`).
    @inline(__always) mutating func release() {
        base?.deallocate()
        base = nil
        count = 0
        capacity = 0
    }

    @inline(__always) mutating func truncate(_ n: Int) {
        if n < count { count = n }
    }

    /// Drops the first `n` bytes (Rust's `drain(..n)`).
    @inline(__always) mutating func removeFirst(_ n: Int) {
        precondition(n <= count)
        if n < count { base!.update(from: base! + n, count: count - n) }
        count -= n
    }

    var span: Span<UInt8> {
        @_lifetime(borrow self) borrowing get {
            let span = Span(_unsafeElements: UnsafeBufferPointer(start: base, count: count))
            return _overrideLifetime(span, borrowing: self)
        }
    }

    @inline(__always) func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    @inline(__always) mutating func withMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: base, count: count))
    }

    /// The finished bytes, as an array of their own.
    consuming func take() -> [UInt8] {
        [UInt8](copying: span)
    }
}

extension Array where Element == UInt8 {
    /// A copy of `span`.
    @inline(__always) init(copying span: Span<UInt8>) {
        self = span.withUnsafeBufferPointer { [UInt8]($0) }
    }
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

/// A short byte string held in place (the Rust's 64-byte `SmallStr`): a read's key, a slug, username, email or tag of
/// up to 56 bytes, costs no allocation, and compares and hashes as seven words. A longer one lives on the heap.
struct SmallBytes: Hashable, Sendable {
    static let inlineCapacity = 56
    /// The bytes, zero-padded, when they fit.
    private var words = InlineArray<7, UInt64>(repeating: 0)
    let count: Int
    private let heap: [UInt8]?

    init(_ bytes: Span<UInt8>) {
        count = bytes.count
        if bytes.count <= Self.inlineCapacity {
            heap = nil
            withUnsafeMutableBytes(of: &words) { dst in bytes.withUnsafeBytes { dst.copyMemory(from: $0) } }
        } else {
            heap = [UInt8](copying: bytes)
        }
    }

    var isEmpty: Bool { count == 0 }

    @inline(__always) func withSpan<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        if let heap { return try body(heap.span) }
        return try withUnsafeBytes(of: words) { raw in
            try body(Span(_unsafeElements: UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                              count: count)))
        }
    }

    static func == (a: SmallBytes, b: SmallBytes) -> Bool {
        guard a.count == b.count else { return false }
        if a.heap != nil || b.heap != nil { return a.heap == b.heap }
        for i in 0..<7 where a.words[i] != b.words[i] { return false }
        return true
    }

    func hash(into hasher: inout Hasher) {
        if let heap {
            hasher.combine(heap)
        } else {
            hasher.combine(count)
            for i in 0..<7 { hasher.combine(words[i]) }
        }
    }
}
