//! bcrypt on dedicated threads, so a login never stalls an event loop.
//!
//! A Blowfish round is a chain of dependent S-box loads, so one hash leaves the core mostly waiting. Up to four
//! queued hashes run in lockstep (`run::<N>`), each its own complete EksBlowfish with all 2^cost key-schedule
//! rounds; the lanes only fill each other's load stalls (about 3x the throughput of one at a time).

use std::io::Read;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::alphabet::BCRYPT;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use tokio::sync::oneshot;

use crate::blowfish_consts::{P, S};

const COST: u32 = 10;
const LANES: usize = 4;
const B64: GeneralPurpose = GeneralPurpose::new(
    &BCRYPT,
    GeneralPurposeConfig::new()
        .with_encode_padding(false)
        .with_decode_padding_mode(DecodePaddingMode::RequireNone)
        .with_decode_allow_trailing_bits(true),
);

struct Job {
    cost: u32,
    salt: [u8; 16],
    key: Vec<u8>,
    tx: oneshot::Sender<[u8; 24]>,
}

static POOL: OnceLock<Sender<Job>> = OnceLock::new();

/// `threads` workers; a worker holding a job waits up to `window` for more to fill its lanes.
pub fn init(threads: usize, window: Duration) {
    let (tx, rx) = mpsc::channel::<Job>();
    let rx = Arc::new(Mutex::new(rx));
    for _ in 0..threads {
        let rx = rx.clone();
        std::thread::spawn(move || {
            while let Some(jobs) = take(&rx, window) {
                let out: Vec<_> = jobs.chunk_by(|a, b| a.cost == b.cost).flat_map(|g| lanes(g[0].cost, g)).collect();
                for (j, h) in jobs.into_iter().zip(out) {
                    let _ = j.tx.send(h);
                }
            }
        });
    }
    let _ = POOL.set(tx);
}

fn take(rx: &Mutex<Receiver<Job>>, window: Duration) -> Option<Vec<Job>> {
    let rx = rx.lock().unwrap();
    let mut jobs = vec![rx.recv().ok()?];
    let end = Instant::now() + window;
    while jobs.len() < LANES {
        match rx.recv_timeout(end.saturating_duration_since(Instant::now())) {
            Ok(j) => jobs.push(j),
            Err(RecvTimeoutError::Timeout) => break,
            Err(RecvTimeoutError::Disconnected) => return None,
        }
    }
    jobs.sort_by_key(|j| j.cost);
    Some(jobs)
}

async fn raw(cost: u32, salt: [u8; 16], password: &str) -> [u8; 24] {
    // $2b$: the password's bytes and a NUL, cut to 72 bytes
    let mut key = password.as_bytes().to_vec();
    key.push(0);
    key.truncate(72);
    let (tx, rx) = oneshot::channel();
    let _ = POOL.get().unwrap().send(Job { cost, salt, key, tx });
    rx.await.expect("bcrypt worker")
}

/// A new `$2b$10$` hash with a random salt.
pub async fn hash(password: &str) -> String {
    let mut salt = [0u8; 16];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut salt)).expect("/dev/urandom");
    let h = raw(COST, salt, password).await;
    format!("$2b${COST}${}{}", B64.encode(salt), B64.encode(&h[..23]))
}

/// Whether `password` matches a stored `$2a$`/`$2b$`/`$2y$` hash.
pub async fn verify(password: &str, stored: &str) -> bool {
    let b = stored.as_bytes();
    if b.len() != 60 || !matches!(&b[..4], b"$2a$" | b"$2b$" | b"$2y$") || b[6] != b'$' {
        return false;
    }
    let (Some(cost), Ok(salt)) = (stored[4..6].parse::<u32>().ok().filter(|c| (4..=31).contains(c)), B64.decode(&b[7..29])) else {
        return false;
    };
    let Ok(salt) = <[u8; 16]>::try_from(salt) else { return false };
    let h = B64.encode(&raw(cost, salt, password).await[..23]);
    h.bytes().zip(&b[29..]).fold(0, |d, (x, &y)| d | (x ^ y)) == 0
}

#[derive(Clone)]
struct St {
    p: [u32; 18],
    s: [[u32; 256]; 4],
}

#[inline(always)]
fn f(s: &[[u32; 256]; 4], x: u32) -> u32 {
    (s[0][(x >> 24) as u8 as usize].wrapping_add(s[1][(x >> 16) as u8 as usize]) ^ s[2][(x >> 8) as u8 as usize])
        .wrapping_add(s[3][x as u8 as usize])
}

/// Blowfish-encrypts one block per lane, the lanes interleaved round by round.
#[inline(always)]
fn enc<const N: usize>(st: &[St; N], l: &mut [u32; N], r: &mut [u32; N]) {
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
        let (a, b) = (r[k] ^ st[k].p[17], l[k] ^ st[k].p[16]);
        l[k] = a;
        r[k] = b;
    }
}

/// 18 big-endian words of `b` read cyclically (Blowfish's key stream).
fn words18(b: &[u8]) -> [u32; 18] {
    let mut w = [0u32; 18];
    let mut j = 0;
    for x in w.iter_mut() {
        for _ in 0..4 {
            *x = (*x << 8) | b[j] as u32;
            j = (j + 1) % b.len();
        }
    }
    w
}

/// ExpandKey: P ^= key stream, then re-encrypt P and the S-boxes in place, XORing in the salt words when given
/// (the cost loop's ExpandKey(state, 0, key) has none).
#[inline(always)]
fn expand<const N: usize>(st: &mut [St; N], key: &[[u32; 18]; N], salt: Option<&[[u32; 4]; N]>) {
    for k in 0..N {
        for i in 0..18 {
            st[k].p[i] ^= key[k][i];
        }
    }
    let (mut l, mut r) = ([0u32; N], [0u32; N]);
    let mut j = 0;
    let mut step = |st: &mut [St; N], l: &mut [u32; N], r: &mut [u32; N]| {
        if let Some(s) = salt {
            for k in 0..N {
                l[k] ^= s[k][j];
                r[k] ^= s[k][j + 1];
            }
            j ^= 2;
        }
        enc(st, l, r);
    };
    for i in (0..18).step_by(2) {
        step(st, &mut l, &mut r);
        for k in 0..N {
            st[k].p[i] = l[k];
            st[k].p[i + 1] = r[k];
        }
    }
    for b in 0..4 {
        for i in (0..256).step_by(2) {
            step(st, &mut l, &mut r);
            for k in 0..N {
                st[k].s[b][i] = l[k];
                st[k].s[b][i + 1] = r[k];
            }
        }
    }
}

/// Raw bcrypt (24 bytes) of N jobs with the same cost.
fn run<const N: usize>(cost: u32, jobs: &[Job]) -> Vec<[u8; 24]> {
    let mut st: [St; N] = std::array::from_fn(|_| St { p: P, s: S });
    let key: [[u32; 18]; N] = std::array::from_fn(|k| words18(&jobs[k].key));
    let salt_key: [[u32; 18]; N] = std::array::from_fn(|k| words18(&jobs[k].salt));
    let salt: [[u32; 4]; N] = std::array::from_fn(|k| std::array::from_fn(|i| salt_key[k][i]));
    expand(&mut st, &key, Some(&salt));
    for _ in 0..1u32 << cost {
        expand(&mut st, &key, None);
        expand(&mut st, &salt_key, None);
    }
    // "OrpheanBeholderScryDoubt", encrypted 64 times
    let mut c = [[0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274u32]; N];
    for _ in 0..64 {
        for j in (0..6).step_by(2) {
            let mut l: [u32; N] = std::array::from_fn(|k| c[k][j]);
            let mut r: [u32; N] = std::array::from_fn(|k| c[k][j + 1]);
            enc(&st, &mut l, &mut r);
            for k in 0..N {
                c[k][j] = l[k];
                c[k][j + 1] = r[k];
            }
        }
    }
    c.iter()
        .map(|w| {
            let mut o = [0u8; 24];
            for (i, x) in w.iter().enumerate() {
                o[i * 4..i * 4 + 4].copy_from_slice(&x.to_be_bytes());
            }
            o
        })
        .collect()
}

fn lanes(cost: u32, jobs: &[Job]) -> Vec<[u8; 24]> {
    match jobs.len() {
        1 => run::<1>(cost, jobs),
        2 => run::<2>(cost, jobs),
        3 => run::<3>(cost, jobs),
        _ => run::<4>(cost, jobs),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_reference_bcrypt() {
        init(1, Duration::from_millis(20));
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            // the seed's hash for "password123", and every lane count, both ways against the bcrypt crate
            let seeded = ::bcrypt::hash_with_salt("password123", 10, [3; 16]).unwrap().format_for_version(::bcrypt::Version::TwoA);
            assert!(verify("password123", &seeded).await);
            assert!(!verify("password124", &seeded).await);
            for n in 1..=4 {
                let pws: Vec<String> = (0..n).map(|i| format!("pw{i}{}", "x".repeat(i * 25))).collect();
                let tasks: Vec<_> = pws.iter().cloned().map(|p| tokio::spawn(async move { hash(&p).await })).collect();
                let mut hs = Vec::new();
                for t in tasks {
                    hs.push(t.await.unwrap());
                }
                for (p, h) in pws.iter().zip(&hs) {
                    assert!(::bcrypt::verify(p, h).unwrap(), "{p} {h}");
                    assert!(verify(p, &::bcrypt::hash(p, 4).unwrap()).await);
                }
            }
            assert!(!verify("x", "$2b$10$short").await);
        });
    }

}
