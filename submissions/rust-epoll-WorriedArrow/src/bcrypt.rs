//! bcrypt ($2a$, cost 10 in practice) with N independent hashes run in lockstep.
//!
//! Every hash still runs all 2^cost rounds of the full EksBlowfish setup. Running several independent hashes in the
//! same loop only gives the CPU independent dependency chains to overlap: a single bcrypt is one long chain of
//! dependent S-box loads, so one core sits mostly idle waiting on L1 latency.

use crate::bf_consts::{P, S};

const ALPHABET: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const MAGIC: [u32; 6] = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274]; // "OrpheanBeholderScryDoubt"

#[derive(Clone)]
struct State {
    p: [u32; 18],
    s: [[u32; 256]; 4],
}

impl State {
    fn new() -> Box<State> {
        Box::new(State { p: P, s: S })
    }
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
    let mut keys: Vec<Vec<u8>> = Vec::with_capacity(N);
    for j in jobs {
        // $2a$: the key is the password followed by its NUL terminator (as golang.org/x/crypto/bcrypt does).
        let mut k = Vec::with_capacity(j.password.len() + 1);
        k.extend_from_slice(j.password);
        k.push(0);
        keys.push(k);
    }
    let words: Vec<Words> = (0..N).map(|k| Words::new(&keys[k], &jobs[k].salt)).collect();
    let mut boxes: Vec<Box<State>> = (0..N).map(|_| State::new()).collect();
    {
        let mut it = boxes.iter_mut();
        let mut st: [&mut State; N] = std::array::from_fn(|_| &mut **it.next().unwrap());
        let kp: [&[u32; 18]; N] = std::array::from_fn(|k| &words[k].key);
        let sp: [&[u32; 18]; N] = std::array::from_fn(|k| &words[k].salt18);
        let s4: [&[u32; 4]; N] = std::array::from_fn(|k| &words[k].salt);
        expand_n(&mut st, kp, Some(s4));
        let rounds = 1u64 << cost;
        for _ in 0..rounds {
            expand_n(&mut st, kp, None);
            expand_n(&mut st, sp, None);
        }
        let mut out = [[0u8; 23]; N];
        let mut c: [[u32; 6]; N] = [MAGIC; N];
        for _ in 0..64 {
            for half in 0..3 {
                let mut l: [u32; N] = std::array::from_fn(|k| c[k][2 * half]);
                let mut r: [u32; N] = std::array::from_fn(|k| c[k][2 * half + 1]);
                encrypt_n(&st, &mut l, &mut r);
                for k in 0..N {
                    c[k][2 * half] = l[k];
                    c[k][2 * half + 1] = r[k];
                }
            }
        }
        for k in 0..N {
            let mut bytes = [0u8; 24];
            for (i, w) in c[k].iter().enumerate() {
                bytes[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
            }
            out[k].copy_from_slice(&bytes[..23]);
        }
        out
    }
}

/// The number of hashes to run in lockstep on this CPU: more lanes hide more load latency until the lanes' S-boxes
/// (4 KB each) and chains stop fitting the core's L1 and registers, which differs between CPUs. Times every width
/// from 1 to 6 on throwaway keys at a low cost and returns the one with the lowest time per hash (the narrower one
/// when within 3%, since a narrower set fills sooner).
pub fn calibrate() -> usize {
    fn per_hash<const N: usize>() -> f64 {
        let salt = [7u8; 16];
        let jobs: [Job; N] = std::array::from_fn(|_| Job { password: b"calibration", salt });
        let mut best = f64::MAX;
        for _ in 0..6 {
            let t = std::time::Instant::now();
            std::hint::black_box(raw_n::<N>(std::hint::black_box(&jobs), 7));
            best = best.min(t.elapsed().as_secs_f64() / N as f64);
        }
        best
    }
    let times = [per_hash::<1>(), per_hash::<2>(), per_hash::<3>(), per_hash::<4>(), per_hash::<5>(), per_hash::<6>()];
    let mut best = 0;
    for n in 1..times.len() {
        if times[n] < times[best] * 0.97 {
            best = n;
        }
    }
    best + 1
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
        raw_n::<1>(&[Job { password: pw, salt }], cost)[0]
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
    fn run<const N: usize>() {
        let jobs: [Job; N] = std::array::from_fn(|i| Job { password: b"password123", salt: [i as u8; 16] });
        let t = std::time::Instant::now();
        let reps = 3;
        for _ in 0..reps {
            std::hint::black_box(raw_n::<N>(&jobs, 10));
        }
        let per = t.elapsed().as_secs_f64() * 1000.0 / (reps * N) as f64;
        eprintln!("lanes={N} ms/hash={per:.2}");
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
        run::<1>();
        run::<2>();
        run::<3>();
        run::<4>();
        run::<6>();
        run::<8>();
    }
}
