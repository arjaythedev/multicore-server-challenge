//! SHA-256 compression with the x86-64 SHA extensions.
//!
//! The instructions work on the state split as `ABEF` / `CDGH` and do two rounds per `sha256rnds2`; the message
//! schedule is built four words at a time with `sha256msg1` / `sha256msg2`. The loop structure follows the layout
//! in Intel's "Intel SHA Extensions" white paper, compressed into one 16-iteration loop that the compiler unrolls.

use super::sha256::{BLOCK_LEN, K};
use std::arch::x86_64::*;

/// Byte shuffle that turns four big-endian message words into native `u32` lanes.
const BYTE_SWAP_MASK: (i64, i64) = (0x0c0d_0e0f_0809_0a0b, 0x0405_0607_0001_0203);
/// Four-round groups per block (64 rounds / 4).
const GROUPS: usize = 16;

/// Whether this CPU has everything `compress` needs.
pub(super) fn is_supported() -> bool {
    is_x86_feature_detected!("sha")
        && is_x86_feature_detected!("sse2")
        && is_x86_feature_detected!("ssse3")
        && is_x86_feature_detected!("sse4.1")
}

/// Safe entry point. Callers only reach it through a `Sha256` whose back end passed [`is_supported`].
pub(super) fn compress(state: &mut [u32; 8], blocks: &[u8]) {
    debug_assert!(is_supported());
    // SAFETY: `Sha256::with_backend` selects `ShaNi` only when `is_supported()` was true on this CPU, which is
    // exactly the feature set `compress_impl` is compiled for.
    unsafe { compress_impl(state, blocks) }
}

/// # Safety
/// The CPU must support SHA, SSE2, SSSE3 and SSE4.1.
#[target_feature(enable = "sha,sse2,ssse3,sse4.1")]
unsafe fn compress_impl(state: &mut [u32; 8], blocks: &[u8]) {
    // SAFETY (whole body): every load reads inside `state` (8 words), a 64-byte `block` or `K` (64 words), through
    // unaligned-load intrinsics; every store writes inside `state`. The CPU features are guaranteed by the caller.
    unsafe {
        let swap = _mm_set_epi64x(BYTE_SWAP_MASK.0, BYTE_SWAP_MASK.1);
        // Rearrange [A B C D][E F G H] into the ABEF / CDGH halves the instructions expect.
        let dcba = _mm_loadu_si128(state.as_ptr().cast());
        let hgfe = _mm_loadu_si128(state.as_ptr().add(4).cast());
        let cdab = _mm_shuffle_epi32::<0xB1>(dcba);
        let efgh = _mm_shuffle_epi32::<0x1B>(hgfe);
        let mut abef = _mm_alignr_epi8::<8>(cdab, efgh);
        let mut cdgh = _mm_blend_epi16::<0xF0>(efgh, cdab);

        for block in blocks.as_chunks::<BLOCK_LEN>().0 {
            let (saved_abef, saved_cdgh) = (abef, cdgh);
            let src = block.as_ptr().cast::<__m128i>();
            // Ring of the last four schedule vectors W[4g..4g+4].
            let mut ring = [
                _mm_shuffle_epi8(_mm_loadu_si128(src), swap),
                _mm_shuffle_epi8(_mm_loadu_si128(src.add(1)), swap),
                _mm_shuffle_epi8(_mm_loadu_si128(src.add(2)), swap),
                _mm_shuffle_epi8(_mm_loadu_si128(src.add(3)), swap),
            ];
            for group in 0..GROUPS {
                let w = if group < 4 {
                    ring[group]
                } else {
                    // W[g] from W[g-4] (ring[g%4]) .. W[g-1] (ring[(g+3)%4]).
                    let t = _mm_sha256msg1_epu32(ring[group % 4], ring[(group + 1) % 4]);
                    let t = _mm_add_epi32(
                        t,
                        _mm_alignr_epi8::<4>(ring[(group + 3) % 4], ring[(group + 2) % 4]),
                    );
                    let next = _mm_sha256msg2_epu32(t, ring[(group + 3) % 4]);
                    ring[group % 4] = next;
                    next
                };
                let k = _mm_loadu_si128(K.as_ptr().add(group * 4).cast());
                let wk = _mm_add_epi32(w, k);
                cdgh = _mm_sha256rnds2_epu32(cdgh, abef, wk);
                abef = _mm_sha256rnds2_epu32(abef, cdgh, _mm_shuffle_epi32::<0x0E>(wk));
            }
            abef = _mm_add_epi32(abef, saved_abef);
            cdgh = _mm_add_epi32(cdgh, saved_cdgh);
        }

        let feba = _mm_shuffle_epi32::<0x1B>(abef);
        let dchg = _mm_shuffle_epi32::<0xB1>(cdgh);
        let dcba = _mm_blend_epi16::<0xF0>(feba, dchg);
        let hgfe = _mm_alignr_epi8::<8>(dchg, feba);
        _mm_storeu_si128(state.as_mut_ptr().cast(), dcba);
        _mm_storeu_si128(state.as_mut_ptr().add(4).cast(), hgfe);
    }
}
