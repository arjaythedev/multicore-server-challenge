//! SHA-256 (FIPS 180-4) with two interchangeable compression back ends.
//!
//! * [`Backend::Portable`]: scalar Rust, the 64 rounds unrolled eight at a time so the working variables never
//!   move between registers (the variable rotation is done by renaming in the macro arguments).
//! * [`Backend::ShaNi`]: the x86-64 SHA extensions (`sha256rnds2` and friends), see `sha256_ni.rs`.
//!
//! The back end is chosen once per process by CPU feature detection and then stored in each hasher, so a test can
//! run both paths side by side. Not handled: messages of 2^61 bytes or more (the bit counter wraps, as in the spec's
//! 64-bit length field).

use std::sync::OnceLock;

/// Digest size in bytes.
pub const DIGEST_LEN: usize = 32;
/// Compression block size in bytes.
pub const BLOCK_LEN: usize = 64;

/// Padding marker byte appended after the message (a single 1 bit).
const PAD_MARKER: u8 = 0x80;
/// Bytes of the final block(s) that hold the message length in bits.
const LENGTH_FIELD_LEN: usize = 8;

/// Initial hash value H(0): fractional parts of the square roots of the first eight primes.
const INITIAL_STATE: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// Round constants: fractional parts of the cube roots of the first 64 primes.
pub(super) const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Which implementation of the compression function a hasher uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// Scalar Rust; works everywhere.
    Portable,
    /// x86-64 SHA extensions; only when the CPU reports them.
    ShaNi,
}

impl Backend {
    /// Every back end, for tests and benchmarks (filter with [`Backend::is_supported`]).
    pub const ALL: [Backend; 2] = [Backend::Portable, Backend::ShaNi];

    /// The best back end for this CPU, detected once per process.
    pub fn selected() -> Backend {
        static SELECTED: OnceLock<Backend> = OnceLock::new();
        *SELECTED.get_or_init(|| {
            if Backend::ShaNi.is_supported() {
                Backend::ShaNi
            } else {
                Backend::Portable
            }
        })
    }

    /// Whether this CPU and build can run the back end.
    pub fn is_supported(self) -> bool {
        match self {
            Backend::Portable => true,
            #[cfg(target_arch = "x86_64")]
            Backend::ShaNi => super::sha256_ni::is_supported(),
            #[cfg(not(target_arch = "x86_64"))]
            Backend::ShaNi => false,
        }
    }
}

/// Incremental SHA-256 hasher. `Clone` snapshots the state, which HMAC uses to reuse its pad blocks.
#[derive(Clone)]
pub struct Sha256 {
    state: [u32; 8],
    /// Bytes of the current partial block.
    buf: [u8; BLOCK_LEN],
    buf_len: usize,
    total_len: u64,
    backend: Backend,
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256 {
    /// New hasher on the best back end for this CPU.
    pub fn new() -> Self {
        Self::with_backend(Backend::selected())
    }

    /// New hasher on a chosen back end. An unsupported choice falls back to [`Backend::Portable`], so the SIMD
    /// code can never run on a CPU without the instructions.
    pub fn with_backend(backend: Backend) -> Self {
        let backend = if backend.is_supported() {
            backend
        } else {
            Backend::Portable
        };
        Sha256 {
            state: INITIAL_STATE,
            buf: [0; BLOCK_LEN],
            buf_len: 0,
            total_len: 0,
            backend,
        }
    }

    /// Absorbs more message bytes.
    pub fn update(&mut self, mut data: &[u8]) {
        self.total_len = self.total_len.wrapping_add(data.len() as u64);
        if self.buf_len > 0 {
            let take = data.len().min(BLOCK_LEN - self.buf_len);
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&data[..take]);
            self.buf_len += take;
            data = &data[take..];
            if self.buf_len < BLOCK_LEN {
                return;
            }
            compress(self.backend, &mut self.state, &self.buf);
            self.buf_len = 0;
        }
        let whole = data.len() - data.len() % BLOCK_LEN;
        compress(self.backend, &mut self.state, &data[..whole]);
        let rest = &data[whole..];
        self.buf[..rest.len()].copy_from_slice(rest);
        self.buf_len = rest.len();
    }

    /// Applies the padding and returns the digest.
    pub fn finalize(mut self) -> [u8; DIGEST_LEN] {
        let bit_len = self.total_len.wrapping_mul(8);
        // Message tail + marker + zeros + 8-byte length: one block if it fits, else two.
        let mut tail = [0u8; 2 * BLOCK_LEN];
        tail[..self.buf_len].copy_from_slice(&self.buf[..self.buf_len]);
        tail[self.buf_len] = PAD_MARKER;
        let tail_len = if self.buf_len + 1 + LENGTH_FIELD_LEN <= BLOCK_LEN {
            BLOCK_LEN
        } else {
            2 * BLOCK_LEN
        };
        tail[tail_len - LENGTH_FIELD_LEN..tail_len].copy_from_slice(&bit_len.to_be_bytes());
        compress(self.backend, &mut self.state, &tail[..tail_len]);

        let mut out = [0u8; DIGEST_LEN];
        for (chunk, word) in out.as_chunks_mut::<4>().0.iter_mut().zip(self.state) {
            *chunk = word.to_be_bytes();
        }
        out
    }
}

/// One-shot digest on the best back end.
pub fn digest(data: &[u8]) -> [u8; DIGEST_LEN] {
    digest_with(Backend::selected(), data)
}

/// One-shot digest on a chosen back end (tests, benchmarks).
pub fn digest_with(backend: Backend, data: &[u8]) -> [u8; DIGEST_LEN] {
    let mut hasher = Sha256::with_backend(backend);
    hasher.update(data);
    hasher.finalize()
}

/// Runs the compression function over whole 64-byte blocks (a trailing partial block is ignored).
///
/// `backend` must come from a [`Sha256`] (so `ShaNi` implies the CPU support was checked).
fn compress(backend: Backend, state: &mut [u32; 8], blocks: &[u8]) {
    match backend {
        Backend::Portable => compress_portable(state, blocks),
        #[cfg(target_arch = "x86_64")]
        Backend::ShaNi => super::sha256_ni::compress(state, blocks),
        #[cfg(not(target_arch = "x86_64"))]
        Backend::ShaNi => compress_portable(state, blocks),
    }
}

fn compress_portable(state: &mut [u32; 8], blocks: &[u8]) {
    for block in blocks.as_chunks::<BLOCK_LEN>().0 {
        compress_block_portable(state, block);
    }
}

#[inline(always)]
fn ch(x: u32, y: u32, z: u32) -> u32 {
    (x & y) ^ (!x & z)
}

#[inline(always)]
fn maj(x: u32, y: u32, z: u32) -> u32 {
    (x & y) ^ (x & z) ^ (y & z)
}

#[inline(always)]
fn big_sigma0(x: u32) -> u32 {
    x.rotate_right(2) ^ x.rotate_right(13) ^ x.rotate_right(22)
}

#[inline(always)]
fn big_sigma1(x: u32) -> u32 {
    x.rotate_right(6) ^ x.rotate_right(11) ^ x.rotate_right(25)
}

#[inline(always)]
fn small_sigma0(x: u32) -> u32 {
    x.rotate_right(7) ^ x.rotate_right(18) ^ (x >> 3)
}

#[inline(always)]
fn small_sigma1(x: u32) -> u32 {
    x.rotate_right(17) ^ x.rotate_right(19) ^ (x >> 10)
}

/// Expands one 64-byte block into the 64-word message schedule.
#[inline(always)]
fn message_schedule(block: &[u8; BLOCK_LEN]) -> [u32; 64] {
    let mut w = [0u32; 64];
    for (word, bytes) in w.iter_mut().zip(block.as_chunks::<4>().0) {
        *word = u32::from_be_bytes(*bytes);
    }
    for i in 16..64 {
        w[i] = small_sigma1(w[i - 2])
            .wrapping_add(w[i - 7])
            .wrapping_add(small_sigma0(w[i - 15]))
            .wrapping_add(w[i - 16]);
    }
    w
}

/// One SHA-256 round. Instead of shifting the eight working variables after each round, the next round is
/// invoked with the names rotated by one, so the compiler keeps everything in registers.
macro_rules! round {
    ($a:ident, $b:ident, $c:ident, $d:ident, $e:ident, $f:ident, $g:ident, $h:ident, $kw:expr) => {
        let t1 = $h
            .wrapping_add(big_sigma1($e))
            .wrapping_add(ch($e, $f, $g))
            .wrapping_add($kw);
        let t2 = big_sigma0($a).wrapping_add(maj($a, $b, $c));
        $d = $d.wrapping_add(t1);
        $h = t1.wrapping_add(t2);
    };
}

fn compress_block_portable(state: &mut [u32; 8], block: &[u8; BLOCK_LEN]) {
    let w = message_schedule(block);
    let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;
    // Eight rounds per iteration: after eight rotations the names line up again.
    for (k, w) in K.as_chunks::<8>().0.iter().zip(w.as_chunks::<8>().0) {
        round!(a, b, c, d, e, f, g, h, k[0].wrapping_add(w[0]));
        round!(h, a, b, c, d, e, f, g, k[1].wrapping_add(w[1]));
        round!(g, h, a, b, c, d, e, f, k[2].wrapping_add(w[2]));
        round!(f, g, h, a, b, c, d, e, k[3].wrapping_add(w[3]));
        round!(e, f, g, h, a, b, c, d, k[4].wrapping_add(w[4]));
        round!(d, e, f, g, h, a, b, c, k[5].wrapping_add(w[5]));
        round!(c, d, e, f, g, h, a, b, k[6].wrapping_add(w[6]));
        round!(b, c, d, e, f, g, h, a, k[7].wrapping_add(w[7]));
    }
    for (s, v) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
        *s = s.wrapping_add(v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Runs `check` once per back end that this CPU supports.
    fn for_each_backend(mut check: impl FnMut(Backend)) {
        for backend in Backend::ALL.into_iter().filter(|b| b.is_supported()) {
            check(backend);
        }
    }

    #[test]
    fn nist_vectors() {
        let long_448 = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        let long_896 = b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
        let cases: [(&[u8], &str); 4] = [
            (
                b"",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ),
            (
                b"abc",
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ),
            (
                long_448,
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            ),
            (
                long_896,
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
            ),
        ];
        for_each_backend(|backend| {
            for (msg, expected) in cases {
                assert_eq!(hex(&digest_with(backend, msg)), expected, "{backend:?}");
            }
        });
    }

    #[test]
    fn one_million_a() {
        let million = vec![b'a'; 1_000_000];
        for_each_backend(|backend| {
            assert_eq!(
                hex(&digest_with(backend, &million)),
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
                "{backend:?}"
            );
        });
    }

    /// Small deterministic generator so the cross-check needs no randomness source.
    fn pseudo_random_bytes(len: usize, seed: &mut u64) -> Vec<u8> {
        (0..len)
            .map(|_| {
                *seed = seed
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                (*seed >> 33) as u8
            })
            .collect()
    }

    #[test]
    fn backends_agree_on_all_lengths() {
        let mut seed = 0x1234_5678_9abc_def0;
        for len in 0..300 {
            let data = pseudo_random_bytes(len, &mut seed);
            let reference = digest_with(Backend::Portable, &data);
            for_each_backend(|backend| {
                assert_eq!(
                    digest_with(backend, &data),
                    reference,
                    "len {len} {backend:?}"
                )
            });
        }
    }

    #[test]
    fn incremental_matches_one_shot_for_every_split() {
        let mut seed = 7;
        let data = pseudo_random_bytes(200, &mut seed);
        let expected = digest(&data);
        for split in 0..=data.len() {
            let mut hasher = Sha256::new();
            hasher.update(&data[..split]);
            hasher.update(&data[split..]);
            assert_eq!(hasher.finalize(), expected, "split {split}");
        }
    }

    #[test]
    fn unsupported_backend_degrades_to_portable() {
        let hasher = Sha256::with_backend(Backend::ShaNi);
        assert!(hasher.backend.is_supported());
    }

    /// Run with `cargo test --release -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn bench_sha256_64_bytes() {
        let input = [0x5au8; 64];
        for_each_backend(|backend| {
            const ITERATIONS: u32 = 2_000_000;
            let mut sink = 0u8;
            let start = std::time::Instant::now();
            for i in 0..ITERATIONS {
                let mut data = input;
                data[0] = i as u8;
                sink ^= digest_with(backend, std::hint::black_box(&data))[0];
            }
            let ns = start.elapsed().as_nanos() as f64 / f64::from(ITERATIONS);
            println!("sha256 of 64 bytes, {backend:?}: {ns:.1} ns (sink {sink})");
        });
    }
}
