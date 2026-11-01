//! Blowfish state and block encryption for `N` independent lanes in lockstep.
//!
//! bcrypt is latency-bound: every Feistel half-round does four dependent S-box loads, so one hash keeps the
//! core mostly idle. Running `N` unrelated hashes through the same half-round, lane after lane, gives the
//! out-of-order core `N` independent dependency chains to overlap. All loops over lanes have a constant trip
//! count, so the compiler unrolls them and keeps the lane words in registers.
//!
//! Not handled on purpose: decryption (bcrypt never needs it) and variable key lengths (see `eks`).

// Lane loops index several parallel per-lane arrays by the same constant `i`; this is clearer than zipping
// four iterators and compiles to the same unrolled code.
#![allow(clippy::needless_range_loop)]

use super::tables::{P_INIT, S_INIT};

/// Words in the P-array.
pub const P_WORDS: usize = 18;
/// Number of S-boxes.
pub const S_BOXES: usize = 4;
/// Words per S-box (one per byte value).
pub const S_WORDS: usize = 256;

/// One lane's S-boxes. Fixed-size arrays let the compiler prove that a byte index is in range, so the
/// lookups carry no bounds check and no `unsafe` is needed.
type SBoxes = [[u32; S_WORDS]; S_BOXES];

/// Blowfish state (P-array and S-boxes) of `N` lanes. Lane `i` only ever touches `p[i]` and `s[i]`.
///
/// 4 KiB of S-boxes per lane: six lanes are 24 KiB and fit a 32 KiB L1 data cache together with the stack.
pub struct Lanes<const N: usize> {
    pub p: [[u32; P_WORDS]; N],
    pub s: [SBoxes; N],
}

impl<const N: usize> Lanes<N> {
    /// All lanes start from the digits of pi. Boxed: the state is too large to pass around by value.
    pub fn new() -> Box<Self> {
        Box::new(Self {
            p: [P_INIT; N],
            s: [S_INIT; N],
        })
    }

    /// Encrypts one 64-bit block per lane in place: `l[i]`/`r[i]` are the left and right halves of lane `i`.
    ///
    /// Written as `l ^= p[0]`, then eight times "half-round on `r`, half-round on `l`" with the P-array words
    /// folded in, which is the standard 16-round network without the per-round swap.
    #[inline(always)]
    pub fn encrypt(&self, l: &mut [u32; N], r: &mut [u32; N]) {
        // Work on local copies so the halves can live in registers instead of behind the `&mut` borrows.
        let (mut a, mut b) = (*l, *r);
        for i in 0..N {
            a[i] ^= self.p[i][0];
        }
        // Unrolled by hand: a counted loop makes the compiler rotate the lane registers every iteration and,
        // from four lanes up, spill them (measured, see the benchmark in `tests.rs`).
        self.round_pair(0, &mut a, &mut b);
        self.round_pair(1, &mut a, &mut b);
        self.round_pair(2, &mut a, &mut b);
        self.round_pair(3, &mut a, &mut b);
        self.round_pair(4, &mut a, &mut b);
        self.round_pair(5, &mut a, &mut b);
        self.round_pair(6, &mut a, &mut b);
        self.round_pair(7, &mut a, &mut b);
        for i in 0..N {
            // The network ends with the halves swapped and P[17] folded into the old right half.
            l[i] = b[i] ^ self.p[i][P_WORDS - 1];
            r[i] = a[i];
        }
    }
}

impl<const N: usize> Lanes<N> {
    /// Two Feistel rounds (rounds `2 * pair` and `2 * pair + 1`) for every lane.
    #[inline(always)]
    fn round_pair(&self, pair: usize, a: &mut [u32; N], b: &mut [u32; N]) {
        for i in 0..N {
            b[i] ^= feistel(&self.s[i], a[i]) ^ self.p[i][2 * pair + 1];
        }
        for i in 0..N {
            a[i] ^= feistel(&self.s[i], b[i]) ^ self.p[i][2 * pair + 2];
        }
    }
}

/// The Blowfish round function: `((S0[a] + S1[b]) ^ S2[c]) + S3[d]` for the bytes `a..d` of `x`, high to low.
#[inline(always)]
fn feistel(s: &SBoxes, x: u32) -> u32 {
    let a = s[0][(x >> 24) as usize];
    let b = s[1][((x >> 16) & 0xff) as usize];
    let c = s[2][((x >> 8) & 0xff) as usize];
    let d = s[3][(x & 0xff) as usize];
    (a.wrapping_add(b) ^ c).wrapping_add(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tables_start_with_the_digits_of_pi() {
        assert_eq!(P_INIT[0], 0x243f6a88);
        assert_eq!(P_INIT[1], 0x85a308d3);
        assert_eq!(S_INIT[0][0], 0xd1310ba6);
        assert_eq!(S_INIT[3][255], 0x3ac372e6);
    }

    /// Eric Young's Blowfish test: key of 8 zero bytes, plaintext zero, ciphertext 4EF997456198DD78.
    /// The key schedule is XOR with the key words (zero here) followed by the usual chained re-encryption,
    /// which `eks` implements; this test goes through it to pin the cipher end to end.
    #[test]
    fn single_block_matches_published_vector() {
        let mut st = Lanes::<1>::new();
        super::super::eks::expand_key(&mut st, &[[0; P_WORDS]], &[[0; 4]]);
        let (mut l, mut r) = ([0u32], [0u32]);
        st.encrypt(&mut l, &mut r);
        assert_eq!((l[0], r[0]), (0x4ef99745, 0x6198dd78));
    }
}
