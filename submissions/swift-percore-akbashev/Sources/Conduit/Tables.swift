// A hash table for a batch's integer keys (article and user ids, tag ids, and viewer-target pairs of them): open
// addressing with linear probing over one array, and a multiplicative hash. Dictionary and Set hash every key with
// SipHash, seeded per process so an attacker can't choose colliding keys; these keys come from Postgres and from tokens
// we signed, so a cheap hash is safe here, and in a profile Set and Dictionary were about 5% of the server's CPU.

/// A key of an IntTable: equality and a 64-bit hash whose high bits are well mixed.
protocol IntKey: Equatable, Sendable {
    var hash: UInt64 { get }
    /// What an empty slot holds (never looked at: emptiness is the slot's value being nil).
    static var placeholder: Self { get }
}

extension Int64: IntKey {
    var hash: UInt64 { UInt64(bitPattern: self) &* 0x9E37_79B9_7F4A_7C15 }
    static var placeholder: Int64 { 0 }
}

extension Int32: IntKey {
    var hash: UInt64 { UInt64(UInt32(bitPattern: self)) &* 0x9E37_79B9_7F4A_7C15 }
    static var placeholder: Int32 { 0 }
}

/// A viewer and what the viewer looks at: an article (favorited) or a user (followed).
struct Pair: IntKey {
    let viewer: Int64
    let target: Int64

    var hash: UInt64 {
        (UInt64(bitPattern: viewer) &* 0xC2B2_AE3D_27D4_EB4F ^ UInt64(bitPattern: target)) &* 0x9E37_79B9_7F4A_7C15
    }

    static var placeholder: Pair { Pair(viewer: 0, target: 0) }
}

struct IntTable<Key: IntKey, Value> {
    private var slots: [Key]
    /// nil: the slot is empty.
    private var values: [Value?]
    /// The slot index is the hash's top bits.
    private var shift: UInt64
    /// Every key, in the order it was first added.
    private(set) var keys: [Key] = []

    init(capacity: Int = 0) {
        let size = Self.size(for: capacity)
        slots = Array(repeating: .placeholder, count: size)
        values = Array(repeating: nil, count: size)
        shift = UInt64(64 - size.trailingZeroBitCount)
        keys.reserveCapacity(capacity)
    }

    /// A power of two with room for `count` keys at half load.
    private static func size(for count: Int) -> Int {
        var size = 16
        while size < 2 * count { size *= 2 }
        return size
    }

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    /// The slot holding `key`, or the empty slot where it would go.
    private func slot(_ key: Key) -> Int {
        let mask = values.count - 1
        var i = Int(truncatingIfNeeded: key.hash >> shift)
        while values[i] != nil, slots[i] != key { i = (i + 1) & mask }
        return i
    }

    subscript(key: Key) -> Value? {
        let i = slot(key)
        return values[i]
    }

    func contains(_ key: Key) -> Bool {
        values[slot(key)] != nil
    }

    /// Sets the value of `key`, adding the key if it is new.
    mutating func set(_ key: Key, _ value: Value) {
        let i = slot(key)
        if values[i] == nil {
            if 2 * (keys.count + 1) > values.count {
                grow()
                return set(key, value)
            }
            slots[i] = key
            keys.append(key)
        }
        values[i] = value
    }

    /// Changes the value of `key` in place, starting from `initial` if the key is new.
    mutating func modify(_ key: Key, default initial: @autoclosure () -> Value, _ change: (inout Value) -> Void) {
        var i = slot(key)
        if values[i] == nil {
            if 2 * (keys.count + 1) > values.count {
                grow()
                i = slot(key)
            }
            slots[i] = key
            keys.append(key)
            values[i] = initial()
        }
        change(&values[i]!)
    }

    /// Changes the value of `key` in place, if the key is there.
    mutating func update(_ key: Key, _ change: (inout Value) -> Void) {
        let i = slot(key)
        if values[i] != nil { change(&values[i]!) }
    }

    private mutating func grow() {
        let old = (slots, values)
        let size = values.count * 2
        slots = Array(repeating: .placeholder, count: size)
        values = Array(repeating: nil, count: size)
        shift = UInt64(64 - size.trailingZeroBitCount)
        for i in old.1.indices where old.1[i] != nil {
            let j = slot(old.0[i])
            slots[j] = old.0[i]
            values[j] = old.1[i]
        }
    }
}

extension IntTable where Value == Void {
    /// Adds `key`; false if it was there already.
    @discardableResult
    mutating func insert(_ key: Key) -> Bool {
        if contains(key) { return false }
        set(key, ())
        return true
    }
}

typealias IntSet<Key: IntKey> = IntTable<Key, Void>
