// Writes Sources/Conduit/BcryptKernels.swift, the bcrypt key-schedule kernels, as the Rust's build.rs writes its
// bc_expand0 assembly: one kernel per lane count (1 to 6), each lane's two halves in scalar locals and all 16 rounds
// of every lane written out, interleaved half-round by half-round, so the compiler has nothing left to decide but
// registers. Two families, as the Rust has several (calibration picks one at start-up):
//   constant  bytes extracted with constant shifts; the compiler picks the instructions (BMI1 bextr on AMD).
//   shrx      the shifts by 24 and 16 take their count from a register (an atomic's value, which the optimizer can't
//             fold), which on BMI2 is shrx: three operands, the input kept, no copy before each shift (the Rust's
//             shrx kernel, for Intel). Worse without BMI2, where a variable shift's count must be in cl, and on
//             arm64, whose ubfx extracts a constant field in one instruction: compiled on x86-64 only.
// From the submission folder:
//   swift scripts/generate-bcrypt-kernels.swift > Sources/Conduit/BcryptKernels.swift

/// The generator: the kernel families, and the source text of each kernel.
enum KernelSource {
    static let maxLanes = 6

    struct Family {
        let name: String         // the Bcrypt.Kernel case
        let x86Only: Bool        // compiled on x86-64 only
        let suffix: String       // the kernels' name suffix
        let extraParams: String  // F's and the encipher's extra parameters
        let extraArgs: String    // passing them on
        let feistel: [String]    // F's body
        let prologue: [String]   // the expansion's first lines (loading the counts)
    }

    static let families = [
        Family(name: "constant", x86Only: false, suffix: "", extraParams: "", extraArgs: "",
               feistel: ["    ((st[k].s[Int(x >> 24)] &+ st[k].s[256 + Int(x >> 16 & 0xFF)]) ^ st[k].s[512 + Int(x >> 8 & 0xFF)])",
                         "        &+ st[k].s[768 + Int(x & 0xFF)]"],
               prologue: []),
        Family(name: "shrx", x86Only: true, suffix: "Shrx", extraParams: ", _ by24: UInt32, _ by16: UInt32", extraArgs: ", by24, by16",
               feistel: ["    ((st[k].s[Int(x &>> by24)] &+ st[k].s[256 + Int(x &>> by16 & 0xFF)]) ^ st[k].s[512 + Int(x >> 8 & 0xFF)])",
                         "        &+ st[k].s[768 + Int(x & 0xFF)]"],
               prologue: ["    let by24 = shiftBy24.load(ordering: .relaxed), by16 = shiftBy16.load(ordering: .relaxed)"]),
    ]

    static func lanes(_ n: Int, _ body: (Int) -> String) -> [String] { (0..<n).map(body) }

    static func feistel(_ f: Family) -> [String] {
        ["/// F of lane `k`, its S-boxes read in place.",
         "@inline(__always) private static func blowfishF\(f.suffix)<let m: Int>(_ st: borrowing InlineArray<m, State>, _ k: Int, _ x: UInt32\(f.extraParams)) -> UInt32 {"]
            + f.feistel + ["}"]
    }

    static func encipher(_ n: Int, _ f: Family) -> [String] {
        var out = ["/// One Blowfish encryption in each of \(n) lane(s): `L ^= P[0]`, sixteen half-rounds `y ^= P[r] ^ F(x)`, then",
                   "/// `(L, R) = (R ^ P[17], L)` (the order bc_expand0 runs them in).",
                   "@inline(__always) private static func encipher\(f.suffix)\(n)<let m: Int>(_ st: borrowing InlineArray<m, State>,",
                   "    " + lanes(n) { "_ l\($0): inout UInt32, _ r\($0): inout UInt32" }.joined(separator: ", ") + "\(f.extraParams)) {"]
        out += lanes(n) { "    l\($0) ^= st[\($0)].p[0]" }
        for round in 1...16 {
            let (x, y) = round % 2 == 1 ? ("l", "r") : ("r", "l")
            // The P word and F as two statements: in one expression, lending `st` to F while reading it would copy it.
            out += lanes(n) { "    \(y)\($0) ^= st[\($0)].p[\(round)]" }
            out += lanes(n) { "    \(y)\($0) ^= blowfishF\(f.suffix)(st, \($0), \(x)\($0)\(f.extraArgs))" }
        }
        out += lanes(n) { "    (l\($0), r\($0)) = (r\($0) ^ st[\($0)].p[17], l\($0))" }
        out.append("}")
        return out
    }

    static func expand0(_ n: Int, _ f: Family) -> [String] {
        let args = lanes(n) { "&l\($0), &r\($0)" }.joined(separator: ", ") + f.extraArgs
        var out = ["/// The key-only expansion of \(n) lane(s) (`bc_expand0_*_\(n)`): 521 encryptions chained from zero, filling P",
                   "/// and then the S-boxes. Generic over the array's size (always \(n)) so the states are reached by address and",
                   "/// never copied.",
                   "@inline(__always) private static func expand0\(f.suffix)Lanes\(n)<let m: Int>(_ st: inout InlineArray<m, State>) {"]
        out += f.prologue
        out += ["    " + lanes(n) { "var l\($0): UInt32 = 0, r\($0): UInt32 = 0" }.joined(separator: "; "),
                "    for i in 0..<9 {",
                "        encipher\(f.suffix)\(n)(st, \(args))"]
        out += lanes(n) { "        st[\($0)].p[2 * i] = l\($0); st[\($0)].p[2 * i + 1] = r\($0)" }
        out += ["    }", "    for i in 0..<512 {", "        encipher\(f.suffix)\(n)(st, \(args))"]
        out += lanes(n) { "        st[\($0)].s[2 * i] = l\($0); st[\($0)].s[2 * i + 1] = r\($0)" }
        out += ["    }", "}"]
        return out
    }

    /// The whole file: everything inside `extension Bcrypt`.
    static func source() -> String {
        var body = ["#if arch(x86_64)",
                    "/// The shrx kernels' shift counts, so the shifts take their count from a register. Not `private`: the",
                    "/// optimizer sees every access to a private one, and folds the loads back to constants (the kernels then",
                    "/// compile to the constant family's, which is only slower where that's slower); a module-internal one is",
                    "/// an external symbol, whose value it can't assume.",
                    "static let shiftBy24 = Atomic<UInt32>(24)",
                    "static let shiftBy16 = Atomic<UInt32>(16)",
                    "#endif",
                    "",
                    "/// The key-only expansion of every lane, by `kernel`'s kernel written out for `n` lanes (1 to \(maxLanes)).",
                    "@inline(__always) static func expand0<let n: Int>(_ st: inout InlineArray<n, State>, _ kernel: Kernel) {",
                    "    switch kernel {"]
        for f in families {
            if f.x86Only { body.append("    #if arch(x86_64)") }
            body.append("    case .\(f.name):")
            body.append("        switch n {")
            body += (1...maxLanes).map { "        case \($0): expand0\(f.suffix)Lanes\($0)(&st)" }
            body += ["        default: fatalError(\"no bcrypt kernel for \\(n) lanes\")", "        }"]
            if f.x86Only { body.append("    #endif") }
        }
        body += ["    }", "}"]
        for f in families {
            if f.x86Only { body += ["", "#if arch(x86_64)"] }
            body += [""] + feistel(f)
            for n in 1...maxLanes { body += [""] + encipher(n, f) + [""] + expand0(n, f) }
            if f.x86Only { body += ["", "#endif"] }
        }
        let file = ["// Generated by scripts/generate-bcrypt-kernels.swift; don't edit. The bcrypt key-schedule kernels (the Rust's",
                    "// build.rs bc_expand0, in Swift): one per lane count and family, every lane's 16 rounds written out.",
                    "import Synchronization",
                    "",
                    "extension Bcrypt {"]
            + body.map { $0.isEmpty ? $0 : "    " + $0 } + ["}"]
        return file.joined(separator: "\n")
    }
}

print(KernelSource.source())
