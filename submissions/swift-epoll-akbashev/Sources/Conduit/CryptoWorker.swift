// engine.rs's crypto workers: each takes up to `lanes` bcrypt jobs at a time (logins to verify, passwords to hash for
// a sign-up or a password change) and runs them in lockstep. Cost-10 hashes (all of the seed's and all new ones) run
// together; any other cost runs on its own. Verified logins answer straight to the reactors; hashed passwords go back
// to the scheduler as writes, ahead of the queue.

/// The digests of `mats` at `cost`, in lockstep sets of up to 6 (`dispatch_lanes`), by `kernel`'s kernels.
private func dispatchLanes(_ mats: [KeyMaterial], cost: Int, kernel: BcryptKernel) -> [BcryptDigest] {
    var out: [BcryptDigest] = []
    out.reserveCapacity(mats.count)
    var i = 0
    func run<let n: Int>(_: InlineArray<n, KeyMaterial>.Type) {
        let input = InlineArray<n, KeyMaterial> { mats[i + $0] }
        let digests = bcryptLanes(input, cost: cost, kernel: kernel)
        for k in 0..<n { out.append(digests[k]) }
        i += n
    }
    while i < mats.count {
        switch mats.count - i {
        case 1: run(InlineArray<1, KeyMaterial>.self)
        case 2: run(InlineArray<2, KeyMaterial>.self)
        case 3: run(InlineArray<3, KeyMaterial>.self)
        case 4: run(InlineArray<4, KeyMaterial>.self)
        case 5: run(InlineArray<5, KeyMaterial>.self)
        default: run(InlineArray<6, KeyMaterial>.self)
        }
    }
    return out
}

private func storedCost(_ task: CryptoTask) -> Int? {
    switch task {
    case .verifyLogin(_, let hash, _, _): parseBcrypt(hash.span)?.cost
    case .hashPassword: 10
    }
}

actor CryptoWorker {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let scheduler: Scheduler
    private let reactors: [Reactor]
    private let signer: TokenSigner
    private let kernel: BcryptKernel

    init(loop: EventLoop, scheduler: Scheduler, reactors: [Reactor], signer: TokenSigner, kernel: BcryptKernel) {
        self.loop = loop
        self.scheduler = scheduler
        self.reactors = reactors
        self.signer = signer
        self.kernel = kernel
    }

    func run() async {
        await withDiscardingTaskGroup { group in
            var finished: CryptoBatchDone?
            while true {
                let batch = await scheduler.nextCrypto(finished: finished)
                let t0 = monotonicNanos()
                var standard: [CryptoTask] = []
                var other: [CryptoTask] = []
                for t in batch {
                    if storedCost(t) == 10 { standard.append(t) } else { other.append(t) }
                }
                var replies: [OutgoingReply] = []
                var writes: [WriteTask] = []
                execute(standard, cost: 10, &replies, &writes)
                finished = CryptoBatchDone(standardUs: standard.isEmpty ? nil : Int((monotonicNanos() - t0) / 1000))
                for t in other {
                    if let cost = storedCost(t) {
                        execute([t], cost: cost, &replies, &writes)
                    } else if case .verifyLogin(_, _, _, let addr) = t {
                        replies.append(errorReply(addr, 401, "invalid credentials"))
                    }
                }
                if !writes.isEmpty {
                    let scheduler = scheduler
                    let work = Submission(writesFront: writes)
                    group.addTask(executorPreference: scheduler.loop) { await scheduler.submit(work) }
                }
                deliverReplies(replies, to: reactors, &group)
            }
        }
    }

    /// `execute_bcrypt_batch`: one lockstep run over every task of `tasks` (all at `cost`).
    private func execute(_ tasks: [CryptoTask], cost: Int, _ replies: inout [OutgoingReply], _ writes: inout [WriteTask]) {
        guard !tasks.isEmpty else { return }
        var salts: [BcryptSalt] = []
        var expected: [BcryptDigest?] = []
        var mats: [KeyMaterial] = []
        salts.reserveCapacity(tasks.count)
        for t in tasks {
            switch t {
            case .verifyLogin(let password, let hash, _, _):
                let parsed = parseBcrypt(hash.span)!
                salts.append(parsed.salt)
                expected.append(parsed.digest)
                mats.append(KeyMaterial(password: password, salt: parsed.salt))
            case .hashPassword(let password, _):
                var salt = BcryptSalt(repeating: 0)
                var saltSpan = salt.mutableSpan
                guard saltSpan.withUnsafeMutableBytes({ fillRandom($0) }) else { fatalError("getrandom failed") }
                salts.append(salt)
                expected.append(nil)
                mats.append(KeyMaterial(password: password, salt: salt))
            }
        }
        let digests = dispatchLanes(mats, cost: cost, kernel: kernel)
        for (i, t) in tasks.enumerated() {
            switch t {
            case .verifyLogin(_, _, let user, let addr):
                guard constantTimeDigestEqual(digests[i], expected[i]!) else {
                    replies.append(errorReply(addr, 401, "invalid credentials"))
                    continue
                }
                let token = signer.issue(user.id)
                var body = ByteBuffer(capacity: 512)
                writeUserEnvelope(&body, email: user.email.span, token: token.span, username: user.username.span,
                                  bio: user.bio?.span, image: user.image?.span)
                replies.append(OutgoingReply(addr: addr, status: 200, body: body.take()))
            case .hashPassword(_, var write):
                let formatted = formatBcrypt(cost: cost, salt: salts[i], digest: digests[i])
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
