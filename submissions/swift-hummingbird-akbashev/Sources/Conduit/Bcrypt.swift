// bcrypt as OpenBSD defines it ($2a$, $2b$, $2y$), with several hashes run in lockstep on one core. One bcrypt is a
// single chain of dependent S-box loads: each Blowfish round needs the round before it, so a core running one hash
// mostly waits on its L1 cache. Independent hashes interleaved round by round give it chains to overlap. Every hash
// still runs all 2^cost rounds (the approach of rust-epoll-WorriedArrow's bcrypt). Checked byte for byte against
// OpenBSD's C (as in HummingbirdBcrypt) on random passwords and salts at widths 1 to 6, and on the seed's $2a$ hashes.
import HTTPTypes
import ServiceLifecycle
import Synchronization

/// One Blowfish state: the P-array, then the four S-boxes. 4,168 bytes, kept inline (on the worker's stack).
struct BlowfishState: BitwiseCopyable {
    var p: InlineArray<18, UInt32>
    var s: InlineArray<1024, UInt32>

    static let initial = BlowfishState(p: InlineArray { blowfishInitialP[$0] }, s: InlineArray { blowfishInitialS[$0] })
}

/// What one hash mixes into its state: the key (the password and its NUL, repeated) and the salt, as 32-bit words.
struct BcryptKey: BitwiseCopyable {
    var key: InlineArray<18, UInt32>
    var salt: InlineArray<4, UInt32>
    /// The salt repeated to 18 words, for the rounds that use it as the key.
    var saltAsKey: InlineArray<18, UInt32>

    /// `password` must be at most 72 bytes; $2a$, $2b$ and $2y$ then all use the password and its NUL as the key.
    init(password: Span<UInt8>, salt: InlineArray<16, UInt8>) {
        let length = password.count + 1
        var at = 0
        func next() -> UInt8 {
            defer { at = at + 1 == length ? 0 : at + 1 }
            return at < password.count ? password[at] : 0
        }
        key = InlineArray(repeating: 0)
        for i in 0..<18 {
            key[i] = UInt32(next()) << 24 | UInt32(next()) << 16 | UInt32(next()) << 8 | UInt32(next())
        }
        self.salt = InlineArray(repeating: 0)
        for i in 0..<4 {
            self.salt[i] = UInt32(salt[4 * i]) << 24 | UInt32(salt[4 * i + 1]) << 16
                | UInt32(salt[4 * i + 2]) << 8 | UInt32(salt[4 * i + 3])
        }
        saltAsKey = InlineArray(repeating: 0)
        for i in 0..<18 { saltAsKey[i] = self.salt[i & 3] }
    }
}

typealias BcryptDigest = InlineArray<23, UInt8>

/// Runs `lanes` hashes of the same cost in lockstep and returns their digests (the 23 bytes a hash string encodes).
func bcryptDigests<let lanes: Int>(_ keys: borrowing InlineArray<lanes, BcryptKey>, cost: Int) -> InlineArray<lanes, BcryptDigest> {
    var states = InlineArray<lanes, BlowfishState>(repeating: .initial)
    expand(&states, keys, .initial)
    for _ in 0..<(1 << cost) {
        expand(&states, keys, .key)
        expand(&states, keys, .salt)
    }
    // Encrypt "OrpheanBeholderScryDoubt" (6 words, 3 blocks) 64 times.
    let magic: InlineArray<6, UInt32> = [0x4f72_7068, 0x6561_6e42, 0x6568_6f6c, 0x6465_7253, 0x6372_7944, 0x6f75_6274]
    var text = InlineArray<lanes, InlineArray<6, UInt32>>(repeating: magic)
    for _ in 0..<64 {
        for block in 0..<3 {
            var l = InlineArray<lanes, UInt32>(repeating: 0)
            var r = InlineArray<lanes, UInt32>(repeating: 0)
            for k in 0..<lanes {
                l[k] = text[k][2 * block]
                r[k] = text[k][2 * block + 1]
            }
            encrypt(states, &l, &r)
            for k in 0..<lanes {
                text[k][2 * block] = l[k]
                text[k][2 * block + 1] = r[k]
            }
        }
    }
    var digests = InlineArray<lanes, BcryptDigest>(repeating: BcryptDigest(repeating: 0))
    for k in 0..<lanes {
        for i in 0..<23 {
            digests[k][i] = UInt8(truncatingIfNeeded: text[k][i >> 2] >> (24 - 8 * UInt32(i & 3)))
        }
    }
    return digests
}

private enum Expansion {
    /// ExpandKey(state, salt, key): P mixed with the key, and every block mixed with the salt.
    case initial
    /// ExpandKey(state, 0, key)
    case key
    /// ExpandKey(state, 0, salt)
    case salt
}

@inline(__always)
private func expand<let lanes: Int>(_ states: inout InlineArray<lanes, BlowfishState>,
                                    _ keys: borrowing InlineArray<lanes, BcryptKey>, _ mode: Expansion) {
    for k in 0..<lanes {
        for i in 0..<18 {
            states[k].p[i] ^= mode == .salt ? keys[k].saltAsKey[i] : keys[k].key[i]
        }
    }
    var l = InlineArray<lanes, UInt32>(repeating: 0)
    var r = InlineArray<lanes, UInt32>(repeating: 0)
    var saltWord = 0
    for i in 0..<9 {
        if mode == .initial {
            for k in 0..<lanes {
                l[k] ^= keys[k].salt[saltWord]
                r[k] ^= keys[k].salt[saltWord + 1]
            }
            saltWord ^= 2
        }
        encrypt(states, &l, &r)
        for k in 0..<lanes {
            states[k].p[2 * i] = l[k]
            states[k].p[2 * i + 1] = r[k]
        }
    }
    for j in 0..<512 {
        if mode == .initial {
            for k in 0..<lanes {
                l[k] ^= keys[k].salt[saltWord]
                r[k] ^= keys[k].salt[saltWord + 1]
            }
            saltWord ^= 2
        }
        encrypt(states, &l, &r)
        for k in 0..<lanes {
            states[k].s[2 * j] = l[k]
            states[k].s[2 * j + 1] = r[k]
        }
    }
}

/// One Blowfish block encryption in each state, interleaved round by round.
@inline(__always)
private func encrypt<let lanes: Int>(_ states: borrowing InlineArray<lanes, BlowfishState>,
                                     _ l: inout InlineArray<lanes, UInt32>, _ r: inout InlineArray<lanes, UInt32>) {
    for round in 0..<8 {
        for k in 0..<lanes {
            l[k] ^= states[k].p[2 * round]
            r[k] ^= f(states, k, l[k])
        }
        for k in 0..<lanes {
            r[k] ^= states[k].p[2 * round + 1]
            l[k] ^= f(states, k, r[k])
        }
    }
    for k in 0..<lanes {
        let x = l[k] ^ states[k].p[16]
        l[k] = r[k] ^ states[k].p[17]
        r[k] = x
    }
}

@inline(__always)
private func f<let lanes: Int>(_ states: borrowing InlineArray<lanes, BlowfishState>, _ k: Int, _ x: UInt32) -> UInt32 {
    let a = states[k].s[Int(x >> 24)]
    let b = states[k].s[256 + Int(x >> 16 & 0xFF)]
    let c = states[k].s[512 + Int(x >> 8 & 0xFF)]
    let d = states[k].s[768 + Int(x & 0xFF)]
    return ((a &+ b) ^ c) &+ d
}

// ---------- hash strings ----------

private let alphabet: InlineArray<64, UInt8> = [
    0x2E, 0x2F, // . /
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, // A-M
    0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, // N-Z
    0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, // a-m
    0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, // n-z
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, // 0-9
]

private func alphabetIndex(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x2E, 0x2F: c - 0x2E
    case 0x41...0x5A: c - 0x41 + 2
    case 0x61...0x7A: c - 0x61 + 28
    case 0x30...0x39: c - 0x30 + 54
    default: nil
    }
}

/// bcrypt's base64 (its own alphabet, no padding) of `bytes`.
private func encode(_ bytes: Span<UInt8>, into out: inout [UInt8]) {
    var i = 0
    while i < bytes.count {
        let c1 = bytes[i]
        out.append(alphabet[Int(c1 >> 2)])
        var c = (c1 & 0x03) << 4
        guard i + 1 < bytes.count else { out.append(alphabet[Int(c)]); return }
        let c2 = bytes[i + 1]
        out.append(alphabet[Int(c | c2 >> 4)])
        c = (c2 & 0x0F) << 2
        guard i + 2 < bytes.count else { out.append(alphabet[Int(c)]); return }
        let c3 = bytes[i + 2]
        out.append(alphabet[Int(c | c3 >> 6)])
        out.append(alphabet[Int(c3 & 0x3F)])
        i += 3
    }
}

/// Decodes `count` bytes from bcrypt's base64; nil on a character outside its alphabet.
private func decode(_ text: Span<UInt8>, count: Int, into out: inout MutableSpan<UInt8>) -> Bool {
    var n = 0
    var i = 0
    while n < count {
        guard i + 1 < text.count, let c1 = alphabetIndex(text[i]), let c2 = alphabetIndex(text[i + 1]) else { return false }
        out[n] = c1 << 2 | (c2 & 0x30) >> 4
        n += 1
        if n == count { break }
        guard i + 2 < text.count, let c3 = alphabetIndex(text[i + 2]) else { return false }
        out[n] = (c2 & 0x0F) << 4 | (c3 & 0x3C) >> 2
        n += 1
        if n == count { break }
        guard i + 3 < text.count, let c4 = alphabetIndex(text[i + 3]) else { return false }
        out[n] = (c3 & 0x03) << 6 | c4
        n += 1
        i += 4
    }
    return true
}

/// A hash string's parts: `$2x$NN$` + 22 characters of salt + 31 of digest.
struct BcryptHash {
    let cost: Int
    var salt: InlineArray<16, UInt8>
    var digest: BcryptDigest

    init?(_ hash: String) {
        let utf8 = hash.utf8
        let text = utf8.span
        guard text.count == 60, text[0] == 0x24, text[1] == 0x32, text[3] == 0x24, text[6] == 0x24, // $2?$NN$
              text[2] == 0x61 || text[2] == 0x62 || text[2] == 0x79, // a b y
              (0x30...0x39).contains(text[4]), (0x30...0x39).contains(text[5]) else { return nil }
        cost = Int(text[4] - 0x30) * 10 + Int(text[5] - 0x30)
        guard (4...31).contains(cost) else { return nil }
        salt = InlineArray(repeating: 0)
        digest = InlineArray(repeating: 0)
        var saltOut = salt.mutableSpan
        guard decode(text.extracting(7..<29), count: 16, into: &saltOut) else { return nil }
        var digestOut = digest.mutableSpan
        guard decode(text.extracting(29..<60), count: 23, into: &digestOut) else { return nil }
    }

    init(cost: Int, salt: InlineArray<16, UInt8>, digest: BcryptDigest) {
        self.cost = cost
        self.salt = salt
        self.digest = digest
    }

    /// `$2b$`, as OpenBSD writes it now.
    var string: String {
        var out: [UInt8] = [0x24, 0x32, 0x62, 0x24, 0x30 + UInt8(cost / 10), 0x30 + UInt8(cost % 10), 0x24]
        out.reserveCapacity(60)
        encode(salt.span, into: &out)
        encode(digest.span, into: &out)
        return String(decoding: out, as: UTF8.self)
    }
}

// ---------- the workers ----------

/// The server's bcrypt. Every hash and verification waits in one queue, and each worker (one per bcrypt thread) runs
/// up to `lanes` of them in lockstep. The first worker takes what is waiting once a full set is there or the oldest
/// has waited `window`; the others only take full sets, so a steady trickle of logins isn't split into half-empty
/// runs. The workers are child tasks that prefer the bcrypt threads' executor, so no hash ever runs on an event loop.
/// Past `limit` hashes running or waiting, a login or sign-up is a 503 straight away.
final class BcryptWorkers: Service {
    struct Job: Sendable {
        let key: BcryptKey
        let cost: Int
        let since: ContinuousClock.Instant
        let continuation: CheckedContinuation<BcryptDigest, any Error>
    }

    private struct State {
        var queue: [Job] = []
        var sleeping: [CheckedContinuation<Void, Never>] = []
        var stopped = false
    }

    let lanes: Int
    private let threads: ThreadPoolExecutor
    private let workers: Int
    private let window: Duration
    private let limit: Int
    private let admitted = Atomic<Int>(0)
    private let state = Mutex(State())
    private let clock = ContinuousClock()

    init(threads: Int, lanes: Int, window: Duration, limit: Int) {
        self.threads = ThreadPoolExecutor(threads: threads)
        workers = threads
        self.lanes = min(max(lanes, 1), 6)
        self.window = window
        self.limit = limit
    }

    /// The digest of `key` at `cost`, from whichever set it joins.
    func digest(_ key: BcryptKey, cost: Int) async throws -> BcryptDigest {
        guard admitted.wrappingAdd(1, ordering: .relaxed).newValue <= limit else {
            admitted.wrappingSubtract(1, ordering: .relaxed)
            throw ApiError(.serviceUnavailable, "server busy")
        }
        defer { admitted.wrappingSubtract(1, ordering: .relaxed) }
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(key: key, cost: cost, since: clock.now, continuation: continuation)
            let (queued, wake) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                if s.stopped { return (false, []) }
                s.queue.append(job)
                defer { s.sleeping = [] }
                return (true, s.sleeping)
            }
            if !queued { continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
            for worker in wake { worker.resume() }
        }
    }

    func run() async throws {
        await withDiscardingTaskGroup { group in
            for worker in 0..<workers {
                group.addTask(executorPreference: threads) { await self.work(gathering: worker == 0) }
            }
            group.addTask {
                try? await gracefulShutdown()
                self.stop()
            }
        }
        try await threads.shutdown()
    }

    private func stop() {
        let (queued, sleeping) = state.withLock { s in
            s.stopped = true
            defer { s.queue = []; s.sleeping = [] }
            return (s.queue, s.sleeping)
        }
        for job in queued { job.continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
        for worker in sleeping { worker.resume() }
    }

    private func work(gathering: Bool) async {
        while let set = await take(gathering: gathering) {
            let digests = Self.lockstep(set)
            for i in set.indices { set[i].continuation.resume(returning: digests[i]) }
        }
    }

    private enum Next {
        case set([Job])
        case wait
        case waitUntil(ContinuousClock.Instant)
        case stop
    }

    /// The next set this worker runs; nil once stopped.
    private func take(gathering: Bool) async -> [Job]? {
        while true {
            let next = state.withLock { s -> Next in
                if s.stopped { return .stop }
                guard let oldest = s.queue.first else { return .wait }
                if s.queue.count >= lanes { return .set(Self.removeSet(&s.queue, lanes: lanes)) }
                guard gathering else { return .wait }
                let deadline = oldest.since + window
                return clock.now >= deadline ? .set(Self.removeSet(&s.queue, lanes: lanes)) : .waitUntil(deadline)
            }
            switch next {
            case .set(let set): return set
            case .stop: return nil
            case .waitUntil(let deadline):
                // Woken early by a new job (which may fill the set) or at the deadline.
                try? await Task.sleep(until: min(deadline, clock.now + .milliseconds(2)), clock: clock)
            case .wait:
                await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                    let now = state.withLock { s -> Bool in
                        if s.stopped || s.queue.count >= lanes || (gathering && !s.queue.isEmpty) { return true }
                        s.sleeping.append(wake)
                        return false
                    }
                    if now { wake.resume() }
                }
            }
        }
    }

    /// Takes the oldest job and up to `lanes - 1` more of the same cost (every hash of a set runs the same rounds).
    private static func removeSet(_ queue: inout [Job], lanes: Int) -> [Job] {
        let cost = queue[0].cost
        var set: [Job] = []
        set.reserveCapacity(lanes)
        var rest: [Job] = []
        rest.reserveCapacity(queue.count)
        for job in queue {
            if set.count < lanes, job.cost == cost { set.append(job) } else { rest.append(job) }
        }
        queue = rest
        return set
    }

    private static func lockstep(_ set: borrowing [Job]) -> [BcryptDigest] {
        switch set.count {
        case 1: lockstep(set, InlineArray<1, BcryptKey>.self)
        case 2: lockstep(set, InlineArray<2, BcryptKey>.self)
        case 3: lockstep(set, InlineArray<3, BcryptKey>.self)
        case 4: lockstep(set, InlineArray<4, BcryptKey>.self)
        case 5: lockstep(set, InlineArray<5, BcryptKey>.self)
        default: lockstep(set, InlineArray<6, BcryptKey>.self)
        }
    }

    private static func lockstep<let n: Int>(_ set: borrowing [Job], _: InlineArray<n, BcryptKey>.Type) -> [BcryptDigest] {
        let keys = InlineArray<n, BcryptKey> { set[$0].key }
        let digests = bcryptDigests(keys, cost: set[0].cost)
        return (0..<n).map { digests[$0] }
    }

    /// How many hashes to run in lockstep on this CPU: more lanes hide more load latency until their S-boxes (4 KB
    /// each) stop fitting the core's L1 alongside each other, which differs between CPUs. Times widths 1 to 6 at cost
    /// 6 and keeps the fastest per hash, or a narrower one within 3% of it, since a narrower set fills sooner.
    static func calibrate() -> (lanes: Int, perHash: [Duration]) {
        let times = [time(InlineArray<1, BcryptKey>.self), time(InlineArray<2, BcryptKey>.self),
                     time(InlineArray<3, BcryptKey>.self), time(InlineArray<4, BcryptKey>.self),
                     time(InlineArray<5, BcryptKey>.self), time(InlineArray<6, BcryptKey>.self)]
        var best = 0
        for i in 1..<times.count where times[i] < times[best] * 0.97 { best = i }
        return (best + 1, times)
    }

    private static func time<let n: Int>(_: InlineArray<n, BcryptKey>.Type) -> Duration {
        let password = Array("calibration".utf8)
        let keys = InlineArray<n, BcryptKey>(repeating: BcryptKey(password: password.span, salt: InlineArray(repeating: 7)))
        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            best = min(best, clock.measure { _ = bcryptDigests(keys, cost: 6) } / n)
        }
        return best
    }
}

/// bcrypt for the handlers: cost 10 (SPEC.md), at most 72 bytes of password (beyond that bcrypt would ignore the rest).
extension BcryptWorkers {
    func hash(_ password: String) async throws -> String {
        let utf8 = Array(password.utf8)
        guard utf8.count <= 72 else { throw ApiError(.unprocessableContent, "password is too long") }
        var random = SystemRandomNumberGenerator()
        var salt = InlineArray<16, UInt8>(repeating: 0)
        for i in 0..<16 { salt[i] = random.next() }
        let digest = try await self.digest(BcryptKey(password: utf8.span, salt: salt), cost: 10)
        return BcryptHash(cost: 10, salt: salt, digest: digest).string
    }

    /// Whether `password` is the one `hash` was made from. The digests are compared in constant time.
    func verify(_ password: String, hash: String) async throws -> Bool {
        let utf8 = Array(password.utf8)
        guard utf8.count <= 72, let stored = BcryptHash(hash) else { return false }
        let digest = try await self.digest(BcryptKey(password: utf8.span, salt: stored.salt), cost: stored.cost)
        var difference: UInt8 = 0
        for i in 0..<23 { difference |= digest[i] ^ stored.digest[i] }
        return difference == 0
    }
}
