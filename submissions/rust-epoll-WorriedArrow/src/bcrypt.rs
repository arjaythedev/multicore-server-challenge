//! bcrypt ($2a$, cost 10 in practice) with N independent hashes run in lockstep.
//!
//! Every hash still runs all 2^cost rounds of the full EksBlowfish setup. Running several independent hashes in the
//! same loop only gives the CPU independent dependency chains to overlap: a single bcrypt is one long chain of
//! dependent S-box loads, so one core sits mostly idle waiting on L1 latency.

use crate::bf_consts::{P, S};

const ALPHABET: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const MAGIC: [u32; 6] = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274]; // "OrpheanBeholderScryDoubt"

#[derive(Clone)]
#[repr(C)]
struct State {
    p: [u32; 18],
    s: [[u32; 256]; 4],
}

// The generated expand0 kernels (build.rs): `bc_expand0_<style>_<n>(lanes)` over n contiguous States.
#[cfg(target_arch = "x86_64")]
std::arch::global_asm!(include_str!(concat!(env!("OUT_DIR"), "/expand0.s")));

#[cfg(target_arch = "x86_64")]
unsafe extern "C" {
    fn bc_expand0_ah_1(s: *mut State);
    fn bc_expand0_ah_2(s: *mut State);
    fn bc_expand0_ah_3(s: *mut State);
    fn bc_expand0_ah_4(s: *mut State);
    fn bc_expand0_ah_5(s: *mut State);
    fn bc_expand0_ah_6(s: *mut State);
    fn bc_expand0_ah_7(s: *mut State);
    fn bc_expand0_ah_8(s: *mut State);
    fn bc_expand0_bextr_1(s: *mut State);
    fn bc_expand0_bextr_2(s: *mut State);
    fn bc_expand0_bextr_3(s: *mut State);
    fn bc_expand0_bextr_4(s: *mut State);
    fn bc_expand0_bextr_5(s: *mut State);
    fn bc_expand0_bextr_6(s: *mut State);
    fn bc_expand0_bextr_7(s: *mut State);
    fn bc_expand0_bextr_8(s: *mut State);
}

/// Which expand0 the cost loop runs: the Rust one, or a generated kernel in one of its two index styles.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kernel {
    Rust = 0,
    Ah = 1,
    Bextr = 2,
}

static KERNEL: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

fn kernel() -> Kernel {
    match KERNEL.load(std::sync::atomic::Ordering::Relaxed) {
        1 => Kernel::Ah,
        2 => Kernel::Bextr,
        _ => Kernel::Rust,
    }
}

/// The kernels that can run here: the generated ones need BMI1 (bextr) and BMI2 (rorx).
pub fn kernels() -> Vec<Kernel> {
    #[cfg(target_arch = "x86_64")]
    if std::arch::is_x86_feature_detected!("bmi1") && std::arch::is_x86_feature_detected!("bmi2") {
        return vec![Kernel::Rust, Kernel::Ah, Kernel::Bextr];
    }
    vec![Kernel::Rust]
}

#[cfg(target_arch = "x86_64")]
fn asm_expand0(k: Kernel, lanes: &mut [State]) {
    type F = unsafe extern "C" fn(*mut State);
    const AH: [F; 8] = [bc_expand0_ah_1, bc_expand0_ah_2, bc_expand0_ah_3, bc_expand0_ah_4, bc_expand0_ah_5, bc_expand0_ah_6, bc_expand0_ah_7, bc_expand0_ah_8];
    const BX: [F; 8] = [
        bc_expand0_bextr_1,
        bc_expand0_bextr_2,
        bc_expand0_bextr_3,
        bc_expand0_bextr_4,
        bc_expand0_bextr_5,
        bc_expand0_bextr_6,
        bc_expand0_bextr_7,
        bc_expand0_bextr_8,
    ];
    let f = if k == Kernel::Ah { AH[lanes.len() - 1] } else { BX[lanes.len() - 1] };
    // SAFETY: the lanes are contiguous repr(C) States of 1042 words (the kernel's stride), and `kernels()` checked
    // for the BMI1/BMI2 instructions the kernel uses.
    unsafe { f(lanes.as_mut_ptr()) }
}

#[inline(always)]
fn f(s: &[[u32; 256]; 4], x: u32) -> u32 {
    let a = s[0][(x >> 24) as usize];
    let b = s[1][((x >> 16) & 0xff) as usize];
    let c = s[2][((x >> 8) & 0xff) as usize];
    let d = s[3][(x & 0xff) as usize];
    (a.wrapping_add(b) ^ c).wrapping_add(d)
}

/// Encrypts one block in each of the N states, interleaved round by round.
#[inline(always)]
fn encrypt_n<const N: usize>(st: &[&mut State; N], l: &mut [u32; N], r: &mut [u32; N]) {
    for i in 0..8 {
        for k in 0..N {
            l[k] ^= st[k].p[2 * i];
            r[k] ^= f(&st[k].s, l[k]);
        }
        for k in 0..N {
            r[k] ^= st[k].p[2 * i + 1];
            l[k] ^= f(&st[k].s, r[k]);
        }
    }
    for k in 0..N {
        l[k] ^= st[k].p[16];
        r[k] ^= st[k].p[17];
        std::mem::swap(&mut l[k], &mut r[k]);
    }
}

#[inline(always)]
fn word(buf: &[u8], pos: &mut usize) -> u32 {
    let mut v = 0u32;
    for _ in 0..4 {
        if *pos >= buf.len() {
            *pos = 0;
        }
        v = (v << 8) | buf[*pos] as u32;
        *pos += 1;
    }
    v
}

/// Precomputed key and salt words: both expansions XOR the same 18 words into P, and the salted one reuses the salt's
/// 4 words cyclically, so neither needs the byte-wise wraparound inside the hot loop.
struct Words {
    key: [u32; 18],
    salt: [u32; 4],
    salt18: [u32; 18],
}

impl Words {
    fn new(key: &[u8], salt: &[u8; 16]) -> Words {
        let mut kp = 0;
        let mut k = [0u32; 18];
        for w in &mut k {
            *w = word(key, &mut kp);
        }
        let mut sp = 0;
        let mut s = [0u32; 4];
        for w in &mut s {
            *w = word(salt, &mut sp);
        }
        let mut s18 = [0u32; 18];
        for (i, w) in s18.iter_mut().enumerate() {
            *w = s[i % 4];
        }
        Words { key: k, salt: s, salt18: s18 }
    }
}

/// ExpandKey(state, salt, key) for N states at once. With `salted`, the salt words are mixed into each block.
#[inline(always)]
fn expand_n<const N: usize>(st: &mut [&mut State; N], xor_p: [&[u32; 18]; N], salt: Option<[&[u32; 4]; N]>) {
    for k in 0..N {
        for i in 0..18 {
            st[k].p[i] ^= xor_p[k][i];
        }
    }
    let mut l = [0u32; N];
    let mut r = [0u32; N];
    let mut si = 0usize;
    for i in 0..9 {
        if let Some(s) = salt {
            for k in 0..N {
                l[k] ^= s[k][si & 3];
                r[k] ^= s[k][(si + 1) & 3];
            }
            si += 2;
        }
        encrypt_n(&*st, &mut l, &mut r);
        for k in 0..N {
            st[k].p[2 * i] = l[k];
            st[k].p[2 * i + 1] = r[k];
        }
    }
    for b in 0..4 {
        for j in 0..128 {
            if let Some(s) = salt {
                for k in 0..N {
                    l[k] ^= s[k][si & 3];
                    r[k] ^= s[k][(si + 1) & 3];
                }
                si += 2;
            }
            encrypt_n(&*st, &mut l, &mut r);
            for k in 0..N {
                st[k].s[b][2 * j] = l[k];
                st[k].s[b][2 * j + 1] = r[k];
            }
        }
    }
}

/// One bcrypt job: the password bytes (already validated to <= 72 bytes), the 16-byte salt, the cost.
pub struct Job<'a> {
    pub password: &'a [u8],
    pub salt: [u8; 16],
}

/// Runs N jobs of the same cost in lockstep and returns each raw 23-byte digest.
pub fn raw_n<const N: usize>(jobs: &[Job; N], cost: u32) -> [[u8; 23]; N] {
    raw_with::<N>(jobs, cost, kernel())
}

fn raw_with<const N: usize>(jobs: &[Job; N], cost: u32, k: Kernel) -> [[u8; 23]; N] {
    let mut keys: Vec<Vec<u8>> = Vec::with_capacity(N);
    for j in jobs {
        // $2a$: the key is the password followed by its NUL terminator (as golang.org/x/crypto/bcrypt does).
        let mut kb = Vec::with_capacity(j.password.len() + 1);
        kb.extend_from_slice(j.password);
        kb.push(0);
        keys.push(kb);
    }
    let words: Vec<Words> = (0..N).map(|i| Words::new(&keys[i], &jobs[i].salt)).collect();
    // One contiguous block, as the generated kernels address every lane from one base.
    let mut lanes: Vec<State> = vec![State { p: P, s: S }; N];
    let kp: [&[u32; 18]; N] = std::array::from_fn(|i| &words[i].key);
    let sp: [&[u32; 18]; N] = std::array::from_fn(|i| &words[i].salt18);
    let s4: [&[u32; 4]; N] = std::array::from_fn(|i| &words[i].salt);
    {
        let mut it = lanes.iter_mut();
        let mut st: [&mut State; N] = std::array::from_fn(|_| it.next().unwrap());
        expand_n(&mut st, kp, Some(s4));
    }
    let rounds = 1u64 << cost;
    match k {
        #[cfg(target_arch = "x86_64")]
        Kernel::Ah | Kernel::Bextr => {
            for _ in 0..rounds {
                for xor in [&kp, &sp] {
                    for (st, w) in lanes.iter_mut().zip(xor.iter()) {
                        for i in 0..18 {
                            st.p[i] ^= w[i];
                        }
                    }
                    asm_expand0(k, &mut lanes);
                }
            }
        }
        _ => {
            let mut it = lanes.iter_mut();
            let mut st: [&mut State; N] = std::array::from_fn(|_| it.next().unwrap());
            for _ in 0..rounds {
                expand_n(&mut st, kp, None);
                expand_n(&mut st, sp, None);
            }
        }
    }
    let mut it = lanes.iter_mut();
    let st: [&mut State; N] = std::array::from_fn(|_| it.next().unwrap());
    let mut out = [[0u8; 23]; N];
    let mut c: [[u32; 6]; N] = [MAGIC; N];
    for _ in 0..64 {
        for half in 0..3 {
            let mut l: [u32; N] = std::array::from_fn(|i| c[i][2 * half]);
            let mut r: [u32; N] = std::array::from_fn(|i| c[i][2 * half + 1]);
            encrypt_n(&st, &mut l, &mut r);
            for i in 0..N {
                c[i][2 * half] = l[i];
                c[i][2 * half + 1] = r[i];
            }
        }
    }
    for i in 0..N {
        let mut bytes = [0u8; 24];
        for (j, w) in c[i].iter().enumerate() {
            bytes[4 * j..4 * j + 4].copy_from_slice(&w.to_be_bytes());
        }
        out[i].copy_from_slice(&bytes[..23]);
    }
    out
}

/// Picks the expand0 kernel and the number of hashes to run in lockstep on this CPU, and returns the width: more
/// lanes hide more load latency until the lanes' S-boxes (4 KB each) and chains stop fitting the core's L1 and
/// registers, and which index style decodes faster differs between CPUs. Times every kernel at every width from 1 to
/// 6 on throwaway keys at a low cost and keeps the lowest time per hash (a narrower width when within 3%, since a
/// narrower set fills sooner).
pub fn calibrate() -> usize {
    fn per_hash<const N: usize>(k: Kernel) -> f64 {
        let salt = [7u8; 16];
        let jobs: [Job; N] = std::array::from_fn(|_| Job { password: b"calibration", salt });
        let mut best = f64::MAX;
        for _ in 0..6 {
            let t = std::time::Instant::now();
            std::hint::black_box(raw_with::<N>(std::hint::black_box(&jobs), 7, k));
            best = best.min(t.elapsed().as_secs_f64() / N as f64);
        }
        best
    }
    let mut pick = (Kernel::Rust, 1, f64::MAX);
    for k in kernels() {
        let times = [per_hash::<1>(k), per_hash::<2>(k), per_hash::<3>(k), per_hash::<4>(k), per_hash::<5>(k), per_hash::<6>(k)];
        let mut best = 0;
        for n in 1..times.len() {
            if times[n] < times[best] * 0.97 {
                best = n;
            }
        }
        if times[best] < pick.2 {
            pick = (k, best + 1, times[best]);
        }
    }
    KERNEL.store(pick.0 as u8, std::sync::atomic::Ordering::Relaxed);
    eprintln!("bcrypt: {:?} kernel x {} lanes, {:.1} ms per cost-10 hash", pick.0, pick.1, pick.2 * 8000.0);
    pick.1
}

fn b64_encode(src: &[u8], out: &mut Vec<u8>) {
    let mut i = 0;
    while i < src.len() {
        let c1 = src[i];
        i += 1;
        out.push(ALPHABET[(c1 >> 2) as usize]);
        let mut c = (c1 & 0x03) << 4;
        if i >= src.len() {
            out.push(ALPHABET[c as usize]);
            break;
        }
        let c2 = src[i];
        i += 1;
        c |= c2 >> 4;
        out.push(ALPHABET[c as usize]);
        c = (c2 & 0x0f) << 2;
        if i >= src.len() {
            out.push(ALPHABET[c as usize]);
            break;
        }
        let c3 = src[i];
        i += 1;
        c |= c3 >> 6;
        out.push(ALPHABET[c as usize]);
        out.push(ALPHABET[(c3 & 0x3f) as usize]);
    }
}

fn b64_value(c: u8) -> Option<u8> {
    ALPHABET.iter().position(|&a| a == c).map(|p| p as u8)
}

fn b64_decode(src: &[u8], n: usize) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(n);
    let mut i = 0;
    while out.len() < n {
        let c1 = b64_value(*src.get(i)?)?;
        let c2 = b64_value(*src.get(i + 1)?)?;
        out.push((c1 << 2) | ((c2 & 0x30) >> 4));
        if out.len() >= n {
            break;
        }
        let c3 = b64_value(*src.get(i + 2)?)?;
        out.push(((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2));
        if out.len() >= n {
            break;
        }
        let c4 = b64_value(*src.get(i + 3)?)?;
        out.push(((c3 & 0x03) << 6) | c4);
        i += 4;
    }
    Some(out)
}

/// A parsed `$2a$10$<22 salt><31 hash>` string.
pub struct Parsed {
    pub cost: u32,
    pub salt: [u8; 16],
    pub digest: [u8; 23],
}

pub fn parse(hash: &[u8]) -> Option<Parsed> {
    if hash.len() != 60 || hash[0] != b'$' || hash[1] != b'2' || hash[3] != b'$' || hash[6] != b'$' {
        return None;
    }
    if !matches!(hash[2], b'a' | b'b' | b'y') {
        return None;
    }
    let cost = (hash[4] as char).to_digit(10)? * 10 + (hash[5] as char).to_digit(10)?;
    if !(4..=31).contains(&cost) {
        return None;
    }
    let salt: [u8; 16] = b64_decode(&hash[7..29], 16)?.try_into().ok()?;
    let digest: [u8; 23] = b64_decode(&hash[29..60], 23)?.try_into().ok()?;
    Some(Parsed { cost, salt, digest })
}

/// Formats `$2a$<cost>$<salt><digest>`.
pub fn format(cost: u32, salt: &[u8; 16], digest: &[u8; 23]) -> String {
    let mut out = Vec::with_capacity(60);
    out.extend_from_slice(b"$2a$");
    out.push(b'0' + (cost / 10) as u8);
    out.push(b'0' + (cost % 10) as u8);
    out.push(b'$');
    b64_encode(salt, &mut out);
    b64_encode(digest, &mut out);
    String::from_utf8(out).expect("ascii")
}

/// Constant-time comparison of two digests.
pub fn digest_eq(a: &[u8; 23], b: &[u8; 23]) -> bool {
    let mut d = 0u8;
    for i in 0..23 {
        d |= a[i] ^ b[i];
    }
    d == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(pw: &[u8], salt: [u8; 16], cost: u32) -> [u8; 23] {
        raw_with::<1>(&[Job { password: pw, salt }], cost, Kernel::Rust)[0]
    }

    #[test]
    fn matches_reference_crate() {
        let salt = *b"0123456789abcdef";
        for pw in [&b"password123"[..], b"", b"x", &[0x80u8; 72][..], b"correct horse battery staple"] {
            let mine = format(5, &salt, &one(pw, salt, 5));
            let theirs = bcrypt::hash_with_salt(pw, 5, salt).unwrap().format_for_version(bcrypt::Version::TwoA);
            assert_eq!(mine, theirs, "pw {:?}", pw);
        }
    }

    #[test]
    fn lanes_match_single() {
        let pws: [&[u8]; 4] = [b"a", b"bb", b"password123", b"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"];
        let salts: [[u8; 16]; 4] = std::array::from_fn(|i| [i as u8 * 7 + 1; 16]);
        let jobs: [Job; 4] = std::array::from_fn(|i| Job { password: pws[i], salt: salts[i] });
        let many = raw_n::<4>(&jobs, 4);
        for i in 0..4 {
            assert_eq!(many[i], one(pws[i], salts[i], 4));
        }
    }

    #[test]
    fn kernels_match_reference() {
        let pws: [&[u8]; 8] = [b"a", b"", b"password123", &[0x80u8; 72], b"x", b"correct horse battery staple", b"bb", b"zz"];
        let salts: [[u8; 16]; 8] = std::array::from_fn(|i| [i as u8 * 7 + 1; 16]);
        let want: Vec<[u8; 23]> = (0..8).map(|i| one(pws[i], salts[i], 4)).collect();
        for k in kernels() {
            macro_rules! check {
                ($n:literal) => {{
                    let jobs: [Job; $n] = std::array::from_fn(|i| Job { password: pws[i], salt: salts[i] });
                    let got = raw_with::<$n>(&jobs, 4, k);
                    for i in 0..$n {
                        assert_eq!(got[i], want[i], "{k:?} n={} lane {i}", $n);
                    }
                }};
            }
            check!(1);
            check!(2);
            check!(3);
            check!(4);
            check!(5);
            check!(6);
            check!(7);
            check!(8);
        }
    }

    #[test]
    fn verifies_seed_hash() {
        let h = b"$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
        let p = parse(h).unwrap();
        assert!(digest_eq(&one(b"password123", p.salt, p.cost), &p.digest));
        assert!(!digest_eq(&one(b"password124", p.salt, p.cost), &p.digest));
        assert_eq!(format(p.cost, &p.salt, &p.digest).as_bytes(), h);
    }
}

#[cfg(test)]
mod speed {
    use super::*;
    fn run<const N: usize>(k: Kernel) {
        let jobs: [Job; N] = std::array::from_fn(|i| Job { password: b"password123", salt: [i as u8; 16] });
        let cpu = || {
            let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut t) };
            t.tv_sec as f64 * 1e3 + t.tv_nsec as f64 / 1e6
        };
        let (t, c) = (std::time::Instant::now(), cpu());
        let reps = 3;
        for _ in 0..reps {
            std::hint::black_box(raw_with::<N>(&jobs, 10, k));
        }
        let n = (reps * N) as f64;
        eprintln!("{k:?} lanes={N} wall ms/hash={:.2} cpu ms/hash={:.2}", t.elapsed().as_secs_f64() * 1000.0 / n, (cpu() - c) / n);
    }
    #[test]
    #[ignore]
    fn calibrate_picks() {
        for _ in 0..5 {
            eprintln!("calibrated lanes={}", calibrate());
        }
    }
    #[test]
    #[ignore]
    fn bcrypt_speed() {
        for k in kernels() {
            run::<1>(k);
            run::<2>(k);
            run::<3>(k);
            run::<4>(k);
            run::<5>(k);
            run::<6>(k);
            run::<8>(k);
        }
    }
}
