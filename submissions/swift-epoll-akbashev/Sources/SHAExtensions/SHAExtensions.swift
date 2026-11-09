// SHA-256's compression function with the x86 SHA extensions (SHA-NI), as the Rust's `compress_words_shani`. Swift
// reaches the instructions only through its `Builtin` module, which this module imports (with the compiler's
// -enable-builtin-module, a hidden flag, as is the module), and it is built with the SHA, SSSE3 and SSE4.1 instructions
// enabled (Package.swift): only a CPU that has them may run any of it. Conduit checks the CPU first and keeps its own
// Swift compression function otherwise; nothing here is inlinable, so none of it lands in code built without them.
#if arch(x86_64)
import Builtin

/// Compresses the `blocks` 64-byte blocks at `data` into `state`, SHA-256's eight words a...h. Never inlined: its
/// instructions must stay in this module.
@inline(never) public func compress(_ state: UnsafeMutablePointer<UInt32>, _ data: UnsafeRawPointer, blocks: Int) {
    let k: InlineArray<16, SIMD4<UInt32>> = [
        SIMD4(0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5), SIMD4(0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5),
        SIMD4(0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3), SIMD4(0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174),
        SIMD4(0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc), SIMD4(0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da),
        SIMD4(0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7), SIMD4(0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967),
        SIMD4(0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13), SIMD4(0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85),
        SIMD4(0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3), SIMD4(0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070),
        SIMD4(0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5), SIMD4(0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3),
        SIMD4(0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208), SIMD4(0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2),
    ]
    // The instructions keep the state as two halves, lane 0 the last word: (f, e, b, a) and (h, g, d, c).
    var abef = SIMD4<UInt32>(state[5], state[4], state[1], state[0])
    var cdgh = SIMD4<UInt32>(state[7], state[6], state[3], state[2])
    for b in 0..<blocks {
        let block = data + 64 * b
        let (savedABEF, savedCDGH) = (abef, cdgh)
        // The message schedule four words at a time, w0...w3 holding the last sixteen.
        var w0 = words(block, 0), w1 = words(block, 16), w2 = words(block, 32), w3 = words(block, 48)
        fourRounds(&abef, &cdgh, w0 &+ k[0])
        fourRounds(&abef, &cdgh, w1 &+ k[1])
        fourRounds(&abef, &cdgh, w2 &+ k[2])
        fourRounds(&abef, &cdgh, w3 &+ k[3])
        for g in stride(from: 4, to: 16, by: 4) {
            w0 = schedule(w0, w1, w2, w3)
            fourRounds(&abef, &cdgh, w0 &+ k[g])
            w1 = schedule(w1, w2, w3, w0)
            fourRounds(&abef, &cdgh, w1 &+ k[g + 1])
            w2 = schedule(w2, w3, w0, w1)
            fourRounds(&abef, &cdgh, w2 &+ k[g + 2])
            w3 = schedule(w3, w0, w1, w2)
            fourRounds(&abef, &cdgh, w3 &+ k[g + 3])
        }
        abef &+= savedABEF
        cdgh &+= savedCDGH
    }
    state[0] = abef[3]
    state[1] = abef[2]
    state[4] = abef[1]
    state[5] = abef[0]
    state[2] = cdgh[3]
    state[3] = cdgh[2]
    state[6] = cdgh[1]
    state[7] = cdgh[0]
}

/// Four big-endian words at `offset`, the first in lane 0.
@inline(__always) private func words(_ block: UnsafeRawPointer, _ offset: Int) -> SIMD4<UInt32> {
    SIMD4(UInt32(bigEndian: block.loadUnaligned(fromByteOffset: offset, as: UInt32.self)),
          UInt32(bigEndian: block.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)),
          UInt32(bigEndian: block.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)),
          UInt32(bigEndian: block.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
}

/// Four rounds with `wk`, four message words plus their round constants: two rounds per instruction, each taking
/// the low two lanes, the halves swapping places after each.
@inline(__always) private func fourRounds(_ abef: inout SIMD4<UInt32>, _ cdgh: inout SIMD4<UInt32>, _ wk: SIMD4<UInt32>) {
    cdgh = rounds2(cdgh, abef, wk)
    abef = rounds2(abef, cdgh, SIMD4(wk[2], wk[3], 0, 0))
}

/// The next four message words from the last sixteen (`a` the oldest four): W[t-16] + σ0(W[t-15]) (msg1), plus
/// W[t-7], then + σ1(W[t-2]) (msg2).
@inline(__always) private func schedule(_ a: SIMD4<UInt32>, _ b: SIMD4<UInt32>, _ c: SIMD4<UInt32>, _ d: SIMD4<UInt32>) -> SIMD4<UInt32> {
    message2(message1(a, b) &+ SIMD4(c[1], c[2], c[3], d[0]), d)
}

@inline(__always) private func rounds2(_ cdgh: SIMD4<UInt32>, _ abef: SIMD4<UInt32>, _ wk: SIMD4<UInt32>) -> SIMD4<UInt32> {
    vector(Builtin.int_x86_sha256rnds2(cdgh._storage._value, abef._storage._value, wk._storage._value))
}

@inline(__always) private func message1(_ a: SIMD4<UInt32>, _ b: SIMD4<UInt32>) -> SIMD4<UInt32> {
    vector(Builtin.int_x86_sha256msg1(a._storage._value, b._storage._value))
}

@inline(__always) private func message2(_ a: SIMD4<UInt32>, _ b: SIMD4<UInt32>) -> SIMD4<UInt32> {
    vector(Builtin.int_x86_sha256msg2(a._storage._value, b._storage._value))
}

@inline(__always) private func vector(_ v: Builtin.Vec4xInt32) -> SIMD4<UInt32> {
    var r = SIMD4<UInt32>()
    r._storage._value = v
    return r
}
#endif
