//! bcrypt ($2a$/$2b$/$2y$), run N hashes in lockstep.
//!
//! One bcrypt is a long chain of dependent S-box loads, so a single hash leaves most of a core's load ports idle.
//! `hash_lanes` runs up to `LANES` independent hashes round by round, interleaving their Blowfish encryptions so the
//! core overlaps them. Every hash still does all 2^cost rounds of the expensive key schedule.

use crate::bf_consts::{P, S0, S1, S2, S3};

/// Release build, dev box (ms of one core per hash): 1 lane 66, 2 lanes 36, 3 lanes 28, 4 lanes 24, 5-6 lanes 22.
pub const LANES: usize = 6;

#[derive(Clone)]
struct State {
    p: [u32; 18],
    s: [[u32; 256]; 4],
}

impl State {
    fn new() -> State {
        State { p: P, s: [S0, S1, S2, S3] }
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

/// Encrypt one block in each of `n` states at once: the 16 rounds of every lane are interleaved.
#[inline(always)]
fn encrypt_n<const N: usize>(st: &[&mut State; N], l: &mut [u32; N], r: &mut [u32; N]) {
    for i in (0..16).step_by(2) {
        for k in 0..N {
            l[k] ^= st[k].p[i];
            r[k] ^= f(&st[k].s, l[k]);
        }
        for k in 0..N {
            r[k] ^= st[k].p[i + 1];
            l[k] ^= f(&st[k].s, r[k]);
        }
    }
    for k in 0..N {
        let t = l[k] ^ st[k].p[16];
        l[k] = r[k] ^ st[k].p[17];
        r[k] = t;
    }
}

/// The key as bcrypt cycles it: the password bytes plus a NUL, repeated, read 4 bytes big-endian at a time.
fn stream_word(data: &[u8], pos: &mut usize) -> u32 {
    let mut w = 0u32;
    for _ in 0..4 {
        w = (w << 8) | data[*pos] as u32;
        *pos = (*pos + 1) % data.len();
    }
    w
}

/// The 18 words XORed into P (the cyclic key stream, computed once rather than byte by byte in the hot loop).
fn words18(data: &[u8]) -> [u32; 18] {
    let mut pos = 0;
    std::array::from_fn(|_| stream_word(data, &mut pos))
}

/// Blowfish key expansion in all lanes: XOR `xor_p` into P, then re-key P and S by encrypting a running block, which
/// with `salt` has the salt's 4 words mixed in cyclically.
#[inline(always)]
fn expand_n<const N: usize>(st: &mut [&mut State; N], xor_p: &[[u32; 18]; N], salt: Option<&[[u32; 4]; N]>) {
    for k in 0..N {
        for i in 0..18 {
            st[k].p[i] ^= xor_p[k][i];
        }
    }
    let mut l = [0u32; N];
    let mut r = [0u32; N];
    let mut si = 0usize;
    let mut block = |st: &mut [&mut State; N], l: &mut [u32; N], r: &mut [u32; N]| {
        if let Some(s) = salt {
            for k in 0..N {
                l[k] ^= s[k][si & 3];
                r[k] ^= s[k][(si + 1) & 3];
            }
            si += 2;
        }
        encrypt_n(st, l, r);
    };
    for i in (0..18).step_by(2) {
        block(st, &mut l, &mut r);
        for k in 0..N {
            st[k].p[i] = l[k];
            st[k].p[i + 1] = r[k];
        }
    }
    for b in 0..4 {
        for i in (0..256).step_by(2) {
            block(st, &mut l, &mut r);
            for k in 0..N {
                st[k].s[b][i] = l[k];
                st[k].s[b][i + 1] = r[k];
            }
        }
    }
}

const CTEXT: &[u8; 24] = b"OrpheanBeholderScryDoubt";

/// The 23 hash bytes of EksBlowfish for each lane (`cost` is the same for every lane).
fn eks_n<const N: usize>(cost: u32, key: &[&[u8]; N], salt: &[[u8; 16]; N]) -> [[u8; 23]; N] {
    // Each lane's state is its own heap allocation: one 16 KB stack array of all lanes compiled ~2x slower (4 lanes).
    let mut boxes: Vec<Box<State>> = (0..N).map(|_| Box::new(State::new())).collect();
    let mut it = boxes.iter_mut();
    let mut st: [&mut State; N] = std::array::from_fn(|_| &mut **it.next().unwrap());
    let kw: [[u32; 18]; N] = std::array::from_fn(|k| words18(key[k]));
    let sw: [[u32; 18]; N] = std::array::from_fn(|k| words18(&salt[k]));
    let s4: [[u32; 4]; N] = std::array::from_fn(|k| std::array::from_fn(|i| sw[k][i]));
    expand_n(&mut st, &kw, Some(&s4));
    for _ in 0..(1u64 << cost) {
        expand_n(&mut st, &kw, None);
        expand_n(&mut st, &sw, None);
    }
    let mut words = [[0u32; 6]; N];
    for k in 0..N {
        for i in 0..6 {
            words[k][i] = u32::from_be_bytes(CTEXT[i * 4..i * 4 + 4].try_into().unwrap());
        }
    }
    for _ in 0..64 {
        for i in (0..6).step_by(2) {
            let mut l: [u32; N] = std::array::from_fn(|k| words[k][i]);
            let mut r: [u32; N] = std::array::from_fn(|k| words[k][i + 1]);
            encrypt_n(&st, &mut l, &mut r);
            for k in 0..N {
                words[k][i] = l[k];
                words[k][i + 1] = r[k];
            }
        }
    }
    std::array::from_fn(|k| {
        let mut out = [0u8; 24];
        for i in 0..6 {
            out[i * 4..i * 4 + 4].copy_from_slice(&words[k][i].to_be_bytes());
        }
        out[..23].try_into().unwrap()
    })
}

// ---- bcrypt's radix-64 ----

const B64: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

fn b64_encode(src: &[u8], out: &mut Vec<u8>) {
    let mut i = 0;
    while i < src.len() {
        let c1 = src[i];
        out.push(B64[(c1 >> 2) as usize]);
        let mut c = (c1 & 0x03) << 4;
        if i + 1 >= src.len() {
            out.push(B64[c as usize]);
            break;
        }
        let c2 = src[i + 1];
        c |= c2 >> 4;
        out.push(B64[c as usize]);
        c = (c2 & 0x0f) << 2;
        if i + 2 >= src.len() {
            out.push(B64[c as usize]);
            break;
        }
        let c3 = src[i + 2];
        c |= c3 >> 6;
        out.push(B64[c as usize]);
        out.push(B64[(c3 & 0x3f) as usize]);
        i += 3;
    }
}

fn b64_val(c: u8) -> Option<u8> {
    B64.iter().position(|&x| x == c).map(|p| p as u8)
}

fn b64_decode_salt(s: &[u8]) -> Option<[u8; 16]> {
    // 22 chars -> 16 bytes (the last char carries 4 meaningful bits)
    let mut out = [0u8; 16];
    let mut n = 0;
    let mut i = 0;
    while n < 16 {
        let c1 = b64_val(*s.get(i)?)?;
        let c2 = b64_val(*s.get(i + 1)?)?;
        out[n] = (c1 << 2) | ((c2 & 0x30) >> 4);
        n += 1;
        if n == 16 {
            break;
        }
        let c3 = b64_val(*s.get(i + 2)?)?;
        out[n] = ((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2);
        n += 1;
        if n == 16 {
            break;
        }
        let c4 = b64_val(*s.get(i + 3)?)?;
        out[n] = ((c3 & 0x03) << 6) | c4;
        n += 1;
        i += 4;
    }
    Some(out)
}

/// A parsed `$2x$cc$<22 salt><31 hash>` string.
pub struct Parsed {
    pub variant: u8,
    pub cost: u32,
    pub salt: [u8; 16],
    pub salt_text: [u8; 22],
}

pub fn parse(hash: &[u8]) -> Option<Parsed> {
    if hash.len() != 60 || hash[0] != b'$' || hash[1] != b'2' || hash[3] != b'$' || hash[6] != b'$' {
        return None;
    }
    let variant = hash[2];
    if !matches!(variant, b'a' | b'b' | b'y') {
        return None;
    }
    let cost = std::str::from_utf8(&hash[4..6]).ok()?.parse::<u32>().ok()?;
    if !(4..=31).contains(&cost) {
        return None;
    }
    let salt_text: [u8; 22] = hash[7..29].try_into().ok()?;
    Some(Parsed { variant, cost, salt: b64_decode_salt(&salt_text)?, salt_text })
}

/// The key bcrypt hashes: the password with a NUL appended, at most 72 bytes.
fn key_of(password: &[u8]) -> Vec<u8> {
    let mut k: Vec<u8> = password.iter().copied().take(72).collect();
    if k.len() < 72 {
        k.push(0);
    }
    k
}

fn format(variant: u8, cost: u32, salt_text: &[u8; 22], raw: &[u8; 23]) -> Vec<u8> {
    let mut out = Vec::with_capacity(60);
    out.extend_from_slice(b"$2");
    out.push(variant);
    out.push(b'$');
    out.push(b'0' + (cost / 10) as u8);
    out.push(b'0' + (cost % 10) as u8);
    out.push(b'$');
    out.extend_from_slice(salt_text);
    b64_encode(raw, &mut out);
    out
}

/// One job: a password and the salt/cost/variant to hash it with.
pub struct Job<'a> {
    pub password: &'a [u8],
    pub variant: u8,
    pub cost: u32,
    pub salt: [u8; 16],
    pub salt_text: [u8; 22],
}

/// Full `$2x$..` strings for up to LANES jobs of the same cost, computed in lockstep.
pub fn hash_lanes(jobs: &[Job]) -> Vec<Vec<u8>> {
    assert!(!jobs.is_empty() && jobs.len() <= LANES);
    let cost = jobs[0].cost;
    assert!(jobs.iter().all(|j| j.cost == cost));
    let keys: Vec<Vec<u8>> = jobs.iter().map(|j| key_of(j.password)).collect();
    let raws: Vec<[u8; 23]> = match jobs.len() {
        1 => lanes::<1>(cost, &keys, jobs),
        2 => lanes::<2>(cost, &keys, jobs),
        3 => lanes::<3>(cost, &keys, jobs),
        4 => lanes::<4>(cost, &keys, jobs),
        5 => lanes::<5>(cost, &keys, jobs),
        _ => lanes::<6>(cost, &keys, jobs),
    };
    jobs.iter().zip(raws).map(|(j, raw)| format(j.variant, cost, &j.salt_text, &raw)).collect()
}

fn lanes<const N: usize>(cost: u32, keys: &[Vec<u8>], jobs: &[Job]) -> Vec<[u8; 23]> {
    let key: [&[u8]; N] = std::array::from_fn(|k| &keys[k][..]);
    let salt: [[u8; 16]; N] = std::array::from_fn(|k| jobs[k].salt);
    eks_n::<N>(cost, &key, &salt).to_vec()
}

/// A fresh cost-10 `$2b$` salt from the OS CSPRNG.
pub fn new_salt() -> ([u8; 16], [u8; 22]) {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).expect("getrandom");
    let mut text = Vec::with_capacity(22);
    b64_encode(&salt, &mut text);
    (salt, text[..22].try_into().unwrap())
}

/// Constant-time byte comparison.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verify_one(password: &[u8], hash: &[u8]) -> bool {
        let p = parse(hash).unwrap();
        let out = hash_lanes(&[Job { password, variant: p.variant, cost: p.cost, salt: p.salt, salt_text: p.salt_text }]);
        ct_eq(&out[0], hash)
    }

    #[test]
    fn matches_reference_crate() {
        for (i, pw) in ["password123", "", "a", "correct horse battery staple", &"x".repeat(80)].iter().enumerate() {
            let h = bcrypt::hash(pw, 4 + (i as u32 % 3)).unwrap();
            assert!(verify_one(pw.as_bytes(), h.as_bytes()), "{pw:?} {h}");
            assert!(!verify_one(b"wrong", h.as_bytes()));
        }
    }

    #[test]
    fn lanes_match_single() {
        let pws: Vec<String> = (0..LANES).map(|i| format!("pw-{i}")).collect();
        let salts: Vec<_> = (0..LANES).map(|_| new_salt()).collect();
        for n in 1..=LANES {
            let jobs: Vec<Job> = (0..n)
                .map(|k| Job { password: pws[k].as_bytes(), variant: b'b', cost: 5, salt: salts[k].0, salt_text: salts[k].1 })
                .collect();
            let out = hash_lanes(&jobs);
            for k in 0..n {
                let s = std::str::from_utf8(&out[k]).unwrap();
                assert!(bcrypt::verify(&pws[k], s).unwrap(), "lane {k} of {n}");
            }
        }
    }

    #[test]
    fn seed_hash() {
        // the seed's users all have password123 at cost 10, $2a$
        let h = bcrypt::hash_with_salt("password123", 10, [7u8; 16]).unwrap().format_for_version(bcrypt::Version::TwoA);
        assert!(verify_one(b"password123", h.as_bytes()));
    }
}

#[cfg(test)]
mod bench {
    use super::*;
    #[test]
    #[ignore]
    fn throughput() {
        let (salt, text) = new_salt();
        for n in [1usize, 2, 3, 4, 5, 6] {
            let pws: Vec<String> = (0..n).map(|i| format!("pw-{i}")).collect();
            let jobs: Vec<Job> = pws.iter().map(|p| Job { password: p.as_bytes(), variant: b'b', cost: 10, salt, salt_text: text }).collect();
            let t = std::time::Instant::now();
            let reps = 4;
            for _ in 0..reps {
                std::hint::black_box(hash_lanes(&jobs));
            }
            let per = t.elapsed().as_secs_f64() * 1000.0 / (reps * n) as f64;
            eprintln!("lanes {n}: {per:.1} ms of one core per hash");
        }
    }
}
