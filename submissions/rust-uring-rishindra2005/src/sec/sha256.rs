//! Implementation of FIPS 180-4 Secure Hash Standard (SHA-256).
//!
//! Plain portable Rust without unsafe blocks or architecture intrinsics.

pub const SHA256_H0: [u32; 8] = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
];

const ROUND_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

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

#[inline(always)]
fn choose(e: u32, f: u32, g: u32) -> u32 {
    (e & f) ^ (!e & g)
}

#[inline(always)]
fn majority(a: u32, b: u32, c: u32) -> u32 {
    (a & b) ^ (a & c) ^ (b & c)
}

pub fn compress_block(state: &mut [u32; 8], block: &[u8; 64]) {
    let mut sched = [0u32; 64];
    let mut idx = 0;
    while idx < 16 {
        let p = idx * 4;
        let quad = [block[p], block[p + 1], block[p + 2], block[p + 3]];
        sched[idx] = u32::from_be_bytes(quad);
        idx += 1;
    }
    for t in 16..64 {
        let s0 = small_sigma0(sched[t - 15]);
        let s1 = small_sigma1(sched[t - 2]);
        sched[t] = sched[t - 16].wrapping_add(s0).wrapping_add(sched[t - 7]).wrapping_add(s1);
    }

    let mut v = *state;
    for t in 0..64 {
        let t1 = v[7]
            .wrapping_add(big_sigma1(v[4]))
            .wrapping_add(choose(v[4], v[5], v[6]))
            .wrapping_add(ROUND_K[t])
            .wrapping_add(sched[t]);
        let t2 = big_sigma0(v[0]).wrapping_add(majority(v[0], v[1], v[2]));

        v[7] = v[6];
        v[6] = v[5];
        v[5] = v[4];
        v[4] = v[3].wrapping_add(t1);
        v[3] = v[2];
        v[2] = v[1];
        v[1] = v[0];
        v[0] = t1.wrapping_add(t2);
    }

    for i in 0..8 {
        state[i] = state[i].wrapping_add(v[i]);
    }
}

#[derive(Clone, Debug)]
pub struct Sha256 {
    pub h: [u32; 8],
    pub pending: [u8; 64],
    pub pending_len: usize,
    pub total_len: u64,
}

impl Sha256 {
    pub fn new() -> Self {
        Self {
            h: SHA256_H0,
            pending: [0u8; 64],
            pending_len: 0,
            total_len: 0,
        }
    }

    pub fn resume(h: [u32; 8], bytes_already_hashed: u64) -> Self {
        Self {
            h,
            pending: [0u8; 64],
            pending_len: 0,
            total_len: bytes_already_hashed,
        }
    }

    pub fn update(&mut self, data: &[u8]) {
        self.total_len += data.len() as u64;
        let mut cursor = 0;
        while cursor < data.len() {
            let avail = 64 - self.pending_len;
            let take = std::cmp::min(avail, data.len() - cursor);
            self.pending[self.pending_len..self.pending_len + take]
                .copy_from_slice(&data[cursor..cursor + take]);
            self.pending_len += take;
            cursor += take;
            if self.pending_len == 64 {
                compress_block(&mut self.h, &self.pending);
                self.pending_len = 0;
            }
        }
    }

    pub fn finish(mut self) -> [u8; 32] {
        let bit_len = self.total_len.wrapping_mul(8);
        self.pending[self.pending_len] = 0x80;
        self.pending_len += 1;

        if self.pending_len > 56 {
            for b in &mut self.pending[self.pending_len..64] {
                *b = 0;
            }
            compress_block(&mut self.h, &self.pending);
            self.pending = [0u8; 64];
            self.pending_len = 0;
        }

        for b in &mut self.pending[self.pending_len..56] {
            *b = 0;
        }
        self.pending[56..64].copy_from_slice(&bit_len.to_be_bytes());
        compress_block(&mut self.h, &self.pending);

        let mut out = [0u8; 32];
        for (i, word) in self.h.iter().enumerate() {
            out[i * 4..(i + 1) * 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }
}

impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finish()
}

pub fn sha256_digest(data: &[u8]) -> [u8; 32] {
    sha256(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex_bytes_32(s: &str) -> [u8; 32] {
        let mut res = [0u8; 32];
        let b = s.as_bytes();
        let mut idx = 0;
        while idx < 32 {
            let high = match b[idx * 2] {
                b'0'..=b'9' => b[idx * 2] - b'0',
                b'a'..=b'f' => b[idx * 2] - b'a' + 10,
                _ => 0,
            };
            let low = match b[idx * 2 + 1] {
                b'0'..=b'9' => b[idx * 2 + 1] - b'0',
                b'a'..=b'f' => b[idx * 2 + 1] - b'a' + 10,
                _ => 0,
            };
            res[idx] = (high << 4) | low;
            idx += 1;
        }
        res
    }

    #[test]
    fn test_empty_string() {
        let exp = hex_bytes_32("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256(b""), exp);
        assert_eq!(sha256_digest(b""), exp);
    }

    #[test]
    fn test_abc() {
        let exp = hex_bytes_32("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(sha256(b"abc"), exp);
    }

    #[test]
    fn test_56_bytes_nist() {
        let msg = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        let exp = hex_bytes_32("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
        assert_eq!(sha256(msg), exp);
    }

    #[test]
    fn test_one_million_a() {
        let mut hasher = Sha256::new();
        let chunk = [b'a'; 1000];
        for _ in 0..1000 {
            hasher.update(&chunk);
        }
        let exp = hex_bytes_32("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        assert_eq!(hasher.finish(), exp);
    }

    #[test]
    fn test_streaming_pieces() {
        let whole = sha256(b"abc");
        let mut streamer = Sha256::new();
        streamer.update(b"a");
        streamer.update(b"b");
        streamer.update(b"c");
        let piece_digest = streamer.finish();
        assert_eq!(piece_digest, whole);
    }
}
