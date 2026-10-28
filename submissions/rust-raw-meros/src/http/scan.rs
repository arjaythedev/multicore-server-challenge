//! Finding the end of the header block (`\r\n\r\n`).
//!
//! The scan looks for `\n` bytes 16 at a time with SSE2 (part of the x86_64 baseline, so no runtime detection)
//! and checks the three bytes before each hit. A typical request has about 8 line ends in 150 bytes, so the
//! check runs rarely. Other targets use the scalar version, which is also the reference for the tests.

/// Index one past the first `\r\n\r\n` in `buf`, or `None` when the block is not complete yet.
#[inline]
pub fn find_header_end(buf: &[u8]) -> Option<usize> {
    #[cfg(target_arch = "x86_64")]
    {
        find_header_end_sse2(buf)
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        find_header_end_scalar(buf)
    }
}

/// True when the four bytes ending at `buf[lf]` (inclusive) are `\r\n\r\n`.
#[inline]
fn ends_block(buf: &[u8], lf: usize) -> bool {
    lf >= 3 && &buf[lf - 3..=lf] == b"\r\n\r\n"
}

/// Portable reference implementation.
#[cfg_attr(target_arch = "x86_64", allow(dead_code))]
pub fn find_header_end_scalar(buf: &[u8]) -> Option<usize> {
    (3..buf.len())
        .find(|&i| buf[i] == b'\n' && ends_block(buf, i))
        .map(|i| i + 1)
}

#[cfg(target_arch = "x86_64")]
pub fn find_header_end_sse2(buf: &[u8]) -> Option<usize> {
    use std::arch::x86_64::{
        __m128i, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_movemask_epi8, _mm_set1_epi8,
    };
    const LANES: usize = 16;
    let mut i = 0;
    while i + LANES <= buf.len() {
        // SAFETY: `i + 16 <= buf.len()` bounds the unaligned 16-byte load; SSE2 is in the x86_64 baseline.
        let mut mask = unsafe {
            let chunk = _mm_loadu_si128(buf.as_ptr().add(i).cast::<__m128i>());
            _mm_movemask_epi8(_mm_cmpeq_epi8(chunk, _mm_set1_epi8(b'\n' as i8))) as u32
        };
        while mask != 0 {
            let lf = i + mask.trailing_zeros() as usize;
            if ends_block(buf, lf) {
                return Some(lf + 1);
            }
            mask &= mask - 1; // clear the lowest set bit
        }
        i += LANES;
    }
    // Tail shorter than one vector; `ends_block` looks backwards so no byte is missed at the seam.
    (i.max(3)..buf.len())
        .find(|&j| buf[j] == b'\n' && ends_block(buf, j))
        .map(|j| j + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_end_at_every_position() {
        for pad in 0..70 {
            let mut v = vec![b'x'; pad];
            v.extend_from_slice(b"\r\n\r\nBODY");
            assert_eq!(find_header_end(&v), Some(pad + 4), "pad {pad}");
            assert_eq!(find_header_end_scalar(&v), Some(pad + 4));
        }
    }

    #[test]
    fn incomplete_and_near_misses() {
        for case in [
            &b""[..],
            b"\r\n\r",
            b"GET / HTTP/1.1\r\nA: b\r\n",
            b"\n\n\n\n",
            b"\r\n\r\r\n",
        ] {
            assert_eq!(find_header_end(case), None, "{case:?}");
        }
    }

    #[test]
    fn sse2_equals_scalar_on_random_data() {
        let mut seed = 0x9E37_79B9_7F4A_7C15u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        const ALPHABET: &[u8] = b"\r\n\r\nab";
        for _ in 0..20_000 {
            let len = (next() % 80) as usize;
            let buf: Vec<u8> = (0..len)
                .map(|_| ALPHABET[(next() % ALPHABET.len() as u64) as usize])
                .collect();
            assert_eq!(
                find_header_end(&buf),
                find_header_end_scalar(&buf),
                "{buf:?}"
            );
        }
    }
}
