// The Rust's `FastMap` and `sort_unstable`, for the read lanes' per-batch key sets and sorts. Swift's Dictionary
// always hashes with SipHash, and its `sort` is a stable sort that calls the comparison through a closure; the Rust
// hashes a word with one multiply (`HwHasher`) and sorts in place with the comparison inlined.

/// The Rust's `HwHasher`, its portable variant (the CRC32 one needs an instruction Swift doesn't reach): every word
/// xor-ed into the state and multiplied, then one mix at the end.
struct FastHasher {
    private var state: UInt64 = 0x517C_C1B7_2722_0A95

    @inline(__always) mutating func write(_ v: UInt64) {
        state = (state ^ v) &* 0x9E37_79B9_7F4A_7C15
    }

    @inline(__always) mutating func write(_ v: Int64) {
        write(UInt64(bitPattern: v))
    }

    /// `bytes` eight at a time, the last word zero-padded, after their count.
    @inline(__always) mutating func write(bytes: Span<UInt8>) {
        write(UInt64(bytes.count))
        bytes.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            let n = raw.count
            var i = 0
            while i + 8 <= n {
                write(UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                i += 8
            }
            if i < n {
                var tail: UInt64 = 0
                for k in 0..<(n - i) { tail |= UInt64(raw[i + k]) << (8 * k) }
                write(tail)
            }
        }
    }

    @inline(__always) func finish() -> UInt64 {
        var x = state &* 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        return x ^ (x >> 27)
    }
}

/// A key a `KeySet` can index: it feeds its fields to a `FastHasher`.
protocol FastHashable: Equatable {
    func feed(_ hasher: inout FastHasher)
}

extension FastHashable {
    @inline(__always) var fastHash: UInt64 {
        var h = FastHasher()
        feed(&h)
        return h.finish()
    }
}

extension Int64: FastHashable {
    @inline(__always) func feed(_ hasher: inout FastHasher) { hasher.write(self) }
}

extension SmallBytes: FastHashable {
    @inline(__always) func feed(_ hasher: inout FastHasher) { withSpan { hasher.write(bytes: $0) } }
}

/// The index of a key set (the Rust's `FastMap<K, u32>`): from a key's hash to its ordinal in the caller's array of
/// keys. Linear probing over a power-of-two table at most half full; a slot holds the hash's low half and the ordinal
/// plus one (0 is a free slot), so a probe compares keys only when the hashes' halves agree.
struct IndexTable {
    private var slots: [UInt64] = []
    private(set) var count = 0

    /// The ordinal under `hash` that `isKey` accepts.
    @inline(__always) func find(_ hash: UInt64, _ isKey: (UInt32) -> Bool) -> UInt32? {
        if count == 0 { return nil }
        let mask = slots.count - 1
        let tag = hash & 0xFFFF_FFFF
        var i = Int(truncatingIfNeeded: hash) & mask
        while true {
            let s = slots[i]
            if s == 0 { return nil }
            if s >> 32 == tag {
                let ordinal = UInt32(truncatingIfNeeded: s) &- 1
                if isKey(ordinal) { return ordinal }
            }
            i = (i &+ 1) & mask
        }
    }

    /// Adds `ordinal`, not in the table yet, under `hash`.
    @inline(__always) mutating func insert(_ hash: UInt64, _ ordinal: UInt32) {
        if (count + 1) * 2 > slots.count { grow() }
        place((hash & 0xFFFF_FFFF) << 32 | UInt64(ordinal &+ 1))
        count += 1
    }

    @inline(__always) private mutating func place(_ entry: UInt64) {
        let mask = slots.count - 1
        var i = Int(truncatingIfNeeded: entry >> 32) & mask
        while slots[i] != 0 { i = (i &+ 1) & mask }
        slots[i] = entry
    }

    @inline(never) private mutating func grow() {
        let old = slots
        slots = [UInt64](repeating: 0, count: Swift.max(16, old.count * 2))
        for s in old where s != 0 { place(s) }
    }

    /// Keeps the table's memory.
    mutating func clear() {
        guard count > 0 else { return }
        slots.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        count = 0
    }
}

extension Array {
    /// Rust's `sort_unstable_by`: in place, no buffer, `less` inlined here (the standard library's `sort` calls its
    /// comparison through a closure). Quicksort on a median of three, runs of up to 16 finished by insertion sort,
    /// heapsort for a range that keeps splitting badly.
    @inline(__always) mutating func sortUnstable(by less: (Element, Element) -> Bool) {
        withUnsafeMutableBufferPointer { Self.sortUnstable($0, by: less) }
    }

    @inline(__always) static func sortUnstable(_ a: UnsafeMutableBufferPointer<Element>, by less: (Element, Element) -> Bool) {
        guard a.count > 1, let p = a.baseAddress else { return }
        if a.count <= 16 { return insertionSort(p, 0, a.count, by: less) }
        // Ranges still to sort, the larger half of each split, so at most log2(count) of them wait.
        var pending = InlineArray<64, (lo: Int, hi: Int, depth: Int)>(repeating: (0, 0, 0))
        var waiting = 0
        var lo = 0
        var hi = a.count
        var depth = 2 * (Int.bitWidth - a.count.leadingZeroBitCount)
        while true {
            let n = hi - lo
            if n <= 16 {
                insertionSort(p, lo, hi, by: less)
            } else if depth == 0 {
                heapsort(p + lo, n, by: less)
            } else {
                depth -= 1
                // Hoare's partition around the median of the first, middle and last: [lo, split) <= pivot <= [split, hi).
                let mid = lo + (n - 1) / 2
                if less(p[mid], p[lo]) { p.swapAt(mid, lo) }
                if less(p[hi - 1], p[mid]) {
                    p.swapAt(hi - 1, mid)
                    if less(p[mid], p[lo]) { p.swapAt(mid, lo) }
                }
                let pivot = p[mid]
                var i = lo - 1
                var j = hi
                while true {
                    repeat { i += 1 } while less(p[i], pivot)
                    repeat { j -= 1 } while less(pivot, p[j])
                    if i >= j { break }
                    p.swapAt(i, j)
                }
                let split = j + 1
                if split - lo < hi - split {
                    pending[waiting] = (split, hi, depth)
                    hi = split
                } else {
                    pending[waiting] = (lo, split, depth)
                    lo = split
                }
                waiting += 1
                continue
            }
            if waiting == 0 { return }
            waiting -= 1
            (lo, hi, depth) = pending[waiting]
        }
    }

    @inline(__always) private static func insertionSort(_ p: UnsafeMutablePointer<Element>, _ lo: Int, _ hi: Int,
                                                         by less: (Element, Element) -> Bool) {
        for i in (lo + 1)..<hi {
            let x = p[i]
            var j = i
            while j > lo && less(x, p[j - 1]) {
                p[j] = p[j - 1]
                j -= 1
            }
            p[j] = x
        }
    }

    @inline(__always) private static func heapsort(_ p: UnsafeMutablePointer<Element>, _ n: Int, by less: (Element, Element) -> Bool) {
        func siftDown(_ start: Int, _ end: Int) {
            var root = start
            while true {
                var child = 2 * root + 1
                if child >= end { return }
                if child + 1 < end && less(p[child], p[child + 1]) { child += 1 }
                if !less(p[root], p[child]) { return }
                p.swapAt(root, child)
                root = child
            }
        }
        for start in stride(from: n / 2 - 1, through: 0, by: -1) { siftDown(start, n) }
        for end in stride(from: n - 1, to: 0, by: -1) {
            p.swapAt(0, end)
            siftDown(0, end)
        }
    }
}

extension Array where Element: Comparable {
    @inline(__always) mutating func sortUnstable() {
        sortUnstable(by: <)
    }
}

extension UnsafeMutablePointer {
    @inline(__always) fileprivate func swapAt(_ i: Int, _ j: Int) {
        let t = self[i]
        self[i] = self[j]
        self[j] = t
    }
}
