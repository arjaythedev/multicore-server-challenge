// engine.rs's crypto workers: each takes up to `lanes` bcrypt jobs at a time (logins to verify, passwords to hash for
// a sign-up or a password change) and runs them in lockstep. Cost-10 hashes (all of the seed's and all new ones) run
// together; any other cost runs on its own. Verified logins answer straight to the reactors; hashed passwords go back
// to the scheduler as writes, ahead of the queue.

actor CryptoWorker: LoopIsolated {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let scheduler: Scheduler
    private let reactors: [Reactor]
    /// Replies sorted by reactor for a delivery, kept from one to the next.
    private var buckets: [[OutgoingReply]] = []
    private let signer: TokenSigner
    private let kernel: Bcrypt.Kernel

    init(loop: EventLoop, scheduler: Scheduler, reactors: [Reactor], signer: TokenSigner, kernel: Bcrypt.Kernel) {
        self.loop = loop
        self.scheduler = scheduler
        self.reactors = reactors
        self.signer = signer
        self.kernel = kernel
    }

    func run() async {
        var finished: Scheduler.CryptoBatchDone?
        while true {
            let batch = await scheduler.nextCrypto(for: self, finished: finished)
            let t0 = Sys.monotonicNanos()
            var standard: [CryptoTask] = []
            var other: [CryptoTask] = []
            for t in batch {
                if Self.storedCost(t) == 10 { standard.append(t) } else { other.append(t) }
            }
            var replies: [OutgoingReply] = []
            var writes: [WriteTask] = []
            execute(standard, cost: 10, &replies, &writes)
            finished = Scheduler.CryptoBatchDone(standardUs: standard.isEmpty ? nil : Int((Sys.monotonicNanos() - t0) / 1000))
            for t in other {
                if let cost = Self.storedCost(t) {
                    execute([t], cost: cost, &replies, &writes)
                } else if case .verifyLogin(_, _, _, let addr) = t {
                    replies.append(OutgoingReply.error(addr, 401, "invalid credentials"))
                }
            }
            if !writes.isEmpty { scheduler.submit(Submission(writesFront: writes)) }
            var b: [[OutgoingReply]] = []
            swap(&b, &buckets)
            await OutgoingReply.deliver(replies, to: reactors, buckets: &b)
            swap(&b, &buckets)
        }
    }

    /// `execute_bcrypt_batch`: one lockstep run over every task of `tasks` (all at `cost`).
    private func execute(_ tasks: [CryptoTask], cost: Int, _ replies: inout [OutgoingReply], _ writes: inout [WriteTask]) {
        guard !tasks.isEmpty else { return }
        var salts: [Bcrypt.Salt] = []
        var expected: [Bcrypt.Digest?] = []
        var mats: [Bcrypt.KeyMaterial] = []
        salts.reserveCapacity(tasks.count)
        for t in tasks {
            switch t {
            case .verifyLogin(let password, let hash, _, _):
                let parsed = Bcrypt.parse(hash.span)!
                salts.append(parsed.salt)
                expected.append(parsed.digest)
                mats.append(Bcrypt.KeyMaterial(password: password, salt: parsed.salt))
            case .hashPassword(let password, _):
                var salt = Bcrypt.Salt(repeating: 0)
                var saltSpan = salt.mutableSpan
                guard saltSpan.withUnsafeMutableBytes({ Bytes.fillRandom($0) }) else { fatalError("getrandom failed") }
                salts.append(salt)
                expected.append(nil)
                mats.append(Bcrypt.KeyMaterial(password: password, salt: salt))
            }
        }
        let digests = Self.dispatchLanes(mats, cost: cost, kernel: kernel)
        for (i, t) in tasks.enumerated() {
            switch t {
            case .verifyLogin(_, _, let user, let addr):
                guard Bcrypt.digestsEqual(digests[i], expected[i]!) else {
                    replies.append(OutgoingReply.error(addr, 401, "invalid credentials"))
                    continue
                }
                let token = signer.issue(user.id)
                var body = ByteBuffer(capacity: 512)
                JSON.writeUser(&body, email: user.email.span, token: token.span, username: user.username.span,
                               bio: user.bio?.span, image: user.image?.span)
                replies.append(OutgoingReply(addr: addr, status: 200, body: body.take()))
            case .hashPassword(_, var write):
                let formatted = Bcrypt.format(cost: cost, salt: salts[i], digest: digests[i])
                switch write.op {
                case .register(let username, let email, _):
                    write.op = .register(username: username, email: email, hash: formatted)
                case .updateUser(let token, let email, let username, _, let bio, let image):
                    write.op = .updateUser(token: token, email: email, username: username, hash: formatted, bio: bio, image: image)
                default:
                    break
                }
                writes.append(write)
            }
        }
    }
}

extension CryptoWorker {
    /// The digests of `mats` at `cost`, in lockstep sets of up to 6 (`dispatch_lanes`), by `kernel`'s kernels.
    private static func dispatchLanes(_ mats: [Bcrypt.KeyMaterial], cost: Int, kernel: Bcrypt.Kernel) -> [Bcrypt.Digest] {
        var out: [Bcrypt.Digest] = []
        out.reserveCapacity(mats.count)
        var i = 0
        func run<let n: Int>(_: InlineArray<n, Bcrypt.KeyMaterial>.Type) {
            let input = InlineArray<n, Bcrypt.KeyMaterial> { mats[i + $0] }
            let digests = Bcrypt.hashLanes(input, cost: cost, kernel: kernel)
            for k in 0..<n { out.append(digests[k]) }
            i += n
        }
        while i < mats.count {
            switch mats.count - i {
            case 1: run(InlineArray<1, Bcrypt.KeyMaterial>.self)
            case 2: run(InlineArray<2, Bcrypt.KeyMaterial>.self)
            case 3: run(InlineArray<3, Bcrypt.KeyMaterial>.self)
            case 4: run(InlineArray<4, Bcrypt.KeyMaterial>.self)
            case 5: run(InlineArray<5, Bcrypt.KeyMaterial>.self)
            default: run(InlineArray<6, Bcrypt.KeyMaterial>.self)
            }
        }
        return out
    }

    private static func storedCost(_ task: CryptoTask) -> Int? {
        switch task {
        case .verifyLogin(_, let hash, _, _): Bcrypt.parse(hash.span)?.cost
        case .hashPassword: 10
        }
    }
}
