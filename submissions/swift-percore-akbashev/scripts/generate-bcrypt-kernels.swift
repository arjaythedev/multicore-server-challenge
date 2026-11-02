// Writes Sources/Conduit/BcryptKernels.swift: bcrypt's key-only expansion (ExpandKey(state, 0, key), the cost loop's
// work) written out per lane count, 1 to 6, as swift-epoll-akbashev's generator does after rust-epoll-theCatWisel's
// build.rs (#154). Each lane's two halves are scalar locals and all 16 rounds of every lane are written out,
// interleaved half-round by half-round, so the compiler has nothing left to decide but registers. Written as generic
// Swift (rounds in a loop, lanes in an InlineArray), the same work was 5-7% slower, and with the rounds written out
// but the lanes still generic, 5 times slower at 4 lanes (most likely copying their states).
//
// Two families, as the Rust has several (BcryptWorkers.calibrate picks one at start-up):
//   constant  bytes extracted with constant shifts; the compiler picks the instructions (BMI1's bextr on AMD).
//   shrx      the shifts by 24 and 16 take their count from a register (an atomic's value, which the optimizer can't
//             fold), which with BMI2 is shrx: three operands, the input kept, so no copy before each shift (the Rust's
//             shrx kernel, for Intel). Worse without BMI2, where a variable shift's count must be in cl.
// From the submission folder:
//   swift scripts/generate-bcrypt-kernels.swift > Sources/Conduit/BcryptKernels.swift

let maxLanes = 6

struct Family {
    var name: String         // the BcryptKernel case
    var suffix: String       // the kernels' name suffix
    var extraParams: String  // feistel's and encrypt's extra parameters
    var extraArgs: String    // passing them on
    var feistel: [String]    // feistel's body
    var prologue: [String]   // the expansion's first lines (loading the counts)
}

let families = [
    Family(name: "constant", suffix: "", extraParams: "", extraArgs: "",
           feistel: ["    ((states[k].s[Int(x >> 24)] &+ states[k].s[256 + Int(x >> 16 & 0xFF)]) ^ states[k].s[512 + Int(x >> 8 & 0xFF)])",
                     "        &+ states[k].s[768 + Int(x & 0xFF)]"],
           prologue: []),
    Family(name: "shrx", suffix: "Shrx", extraParams: ", _ by24: UInt32, _ by16: UInt32", extraArgs: ", by24, by16",
           feistel: ["    ((states[k].s[Int(x &>> by24)] &+ states[k].s[256 + Int(x &>> by16 & 0xFF)])",
                     "        ^ states[k].s[512 + Int(x >> 8 & 0xFF)]) &+ states[k].s[768 + Int(x & 0xFF)]"],
           prologue: ["    let by24 = bcryptShiftBy24.load(ordering: .relaxed), by16 = bcryptShiftBy16.load(ordering: .relaxed)"]),
]

func lanes(_ n: Int, _ body: (Int) -> String) -> [String] { (0..<n).map(body) }

func feistel(_ f: Family) -> [String] {
    ["/// F of lane `k`, its S-boxes read in place.",
     "@inline(__always) private func feistel\(f.suffix)<let m: Int>(_ states: borrowing InlineArray<m, BlowfishState>, _ k: Int,",
     "    _ x: UInt32\(f.extraParams)) -> UInt32 {"] + f.feistel + ["}"]
}

func encrypt(_ n: Int, _ f: Family) -> [String] {
    var out = ["/// One Blowfish block encryption in each of \(n) lane(s): `L ^= P[0]`, sixteen half-rounds `y ^= P[r] ^ F(x)`,",
               "/// then `(L, R) = (R ^ P[17], L)`.",
               "@inline(__always) private func encrypt\(f.suffix)\(n)<let m: Int>(_ states: borrowing InlineArray<m, BlowfishState>,",
               "    " + lanes(n) { "_ l\($0): inout UInt32, _ r\($0): inout UInt32" }.joined(separator: ", ") + "\(f.extraParams)) {"]
    out += lanes(n) { "    l\($0) ^= states[\($0)].p[0]" }
    for round in 1...16 {
        let (x, y) = round % 2 == 1 ? ("l", "r") : ("r", "l")
        // P and F as two statements: in one expression, lending `states` to feistel while reading it would copy it.
        out += lanes(n) { "    \(y)\($0) ^= states[\($0)].p[\(round)]" }
        out += lanes(n) { "    \(y)\($0) ^= feistel\(f.suffix)(states, \($0), \(x)\($0)\(f.extraArgs))" }
    }
    out += lanes(n) { "    (l\($0), r\($0)) = (r\($0) ^ states[\($0)].p[17], l\($0))" }
    out.append("}")
    return out
}

func expand(_ n: Int, _ f: Family) -> [String] {
    let args = lanes(n) { "&l\($0), &r\($0)" }.joined(separator: ", ") + f.extraArgs
    var out = ["/// The key-only expansion of \(n) lane(s): 521 encryptions chained from zero, filling P and then the S-boxes.",
               "/// Generic over the array's size (always \(n)) so the states are reached in place, never copied.",
               "@inline(__always) private func expandKeyOnly\(f.suffix)\(n)<let m: Int>(_ states: inout InlineArray<m, BlowfishState>) {"]
    out += f.prologue
    out += ["    " + lanes(n) { "var l\($0): UInt32 = 0, r\($0): UInt32 = 0" }.joined(separator: "; "),
            "    for i in 0..<9 {",
            "        encrypt\(f.suffix)\(n)(states, \(args))"]
    out += lanes(n) { "        states[\($0)].p[2 * i] = l\($0); states[\($0)].p[2 * i + 1] = r\($0)" }
    out += ["    }", "    for i in 0..<512 {", "        encrypt\(f.suffix)\(n)(states, \(args))"]
    out += lanes(n) { "        states[\($0)].s[2 * i] = l\($0); states[\($0)].s[2 * i + 1] = r\($0)" }
    out += ["    }", "}"]
    return out
}

var file = ["// Generated by scripts/generate-bcrypt-kernels.swift; don't edit. bcrypt's key-only expansion written out per lane",
            "// count and kernel family: every lane's halves in locals, all 16 rounds of every lane in order.",
            "import Synchronization",
            "",
            "/// The shrx kernels' shift counts, so the shifts take their count from a register. Not `private`: a private",
            "/// global is internal to the object file, where the optimizer sees every access and folds the loads back to",
            "/// constants (the kernels then compile to the constant family's, which is only slower where that's slower);",
            "/// a module-internal one is an external symbol, whose value it can't assume.",
            "let bcryptShiftBy24 = Atomic<UInt32>(24)",
            "let bcryptShiftBy16 = Atomic<UInt32>(16)",
            "",
            "/// ExpandKey(state, 0, key) in every lane (P already mixed with the key), by `kernel`'s kernel written out for",
            "/// `n` lanes (1 to \(maxLanes)).",
            "@inline(__always) func expandKeyOnly<let n: Int>(_ states: inout InlineArray<n, BlowfishState>, _ kernel: BcryptKernel) {",
            "    switch kernel {"]
for f in families {
    file += ["    case .\(f.name):", "        switch n {"]
    file += (1...maxLanes).map { "        case \($0): expandKeyOnly\(f.suffix)\($0)(&states)" }
    file += ["        default: fatalError(\"no bcrypt kernel for \\(n) lanes\")", "        }"]
}
file += ["    }", "}"]
for f in families {
    file += [""] + feistel(f)
    for n in 1...maxLanes { file += [""] + encrypt(n, f) + [""] + expand(n, f) }
}

print(file.joined(separator: "\n"))
