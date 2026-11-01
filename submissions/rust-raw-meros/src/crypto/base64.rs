//! Base64 (RFC 4648) in the two flavours this server needs.
//!
//! * standard alphabet **with** `=` padding (SCRAM messages);
//! * URL-safe alphabet **without** padding (JWT segments).
//!
//! Decoding is strict: characters outside the alphabet, padding in the wrong place or amount, impossible lengths
//! and non-zero trailing bits are all rejected (so each byte string has exactly one accepted text form). Not
//! handled: line breaks or whitespace inside the input (MIME style).

const SYMBOLS_62_63_STANDARD: [u8; 2] = *b"+/";
const SYMBOLS_62_63_URL: [u8; 2] = *b"-_";
const PAD: u8 = b'=';
/// Marker in the decode table for bytes outside the alphabet. Valid symbols decode to 0..64.
const INVALID: u8 = 0xFF;
/// Any decoded value with one of these bits set is not a 6-bit symbol (so it is `INVALID`).
const NOT_A_SYMBOL_MASK: u8 = 0xC0;

/// An alphabet plus its padding rule, with both lookup tables built at compile time.
struct Alphabet {
    encode: [u8; 64],
    decode: [u8; 256],
    padded: bool,
}

const fn alphabet(tail: [u8; 2], padded: bool) -> Alphabet {
    let mut encode = [0u8; 64];
    let mut decode = [INVALID; 256];
    let mut i = 0;
    while i < 64 {
        encode[i] = match i {
            0..=25 => b'A' + i as u8,
            26..=51 => b'a' + (i as u8 - 26),
            52..=61 => b'0' + (i as u8 - 52),
            62 => tail[0],
            _ => tail[1],
        };
        decode[encode[i] as usize] = i as u8;
        i += 1;
    }
    Alphabet {
        encode,
        decode,
        padded,
    }
}

static STANDARD: Alphabet = alphabet(SYMBOLS_62_63_STANDARD, true);
static URL_SAFE: Alphabet = alphabet(SYMBOLS_62_63_URL, false);

/// Length of the encoding of `len` bytes, with or without padding.
pub const fn encoded_len(len: usize, padded: bool) -> usize {
    let full = len / 3 * 4;
    match (len % 3, padded) {
        (0, _) => full,
        (_, true) => full + 4,
        (1, false) => full + 2,
        _ => full + 3,
    }
}

/// Upper bound on the decoded size of `encoded_len` input bytes (exact for valid unpadded input).
pub const fn decoded_capacity(encoded_len: usize) -> usize {
    encoded_len / 4 * 3 + 2
}

/// Appends the standard, padded encoding of `input` to `out`.
pub fn encode(input: &[u8], out: &mut Vec<u8>) {
    encode_with(&STANDARD, input, out);
}

/// Decodes standard, padded base64. `None` on any invalid input.
pub fn decode(input: &[u8]) -> Option<Vec<u8>> {
    decode_to_vec(&STANDARD, input)
}

/// Appends the URL-safe, unpadded encoding of `input` to `out`.
pub fn encode_url(input: &[u8], out: &mut Vec<u8>) {
    encode_with(&URL_SAFE, input, out);
}

/// Decodes URL-safe, unpadded base64. `None` on any invalid input.
pub fn decode_url(input: &[u8]) -> Option<Vec<u8>> {
    decode_to_vec(&URL_SAFE, input)
}

/// Allocation-free URL-safe decode into a caller buffer; returns the number of bytes written.
///
/// `None` if the input is invalid or `out` is smaller than the decoded size. The JWT hot
/// path uses this with stack buffers.
pub fn decode_url_into(input: &[u8], out: &mut [u8]) -> Option<usize> {
    decode_into(&URL_SAFE, input, out)
}

fn encode_with(alphabet: &Alphabet, input: &[u8], out: &mut Vec<u8>) {
    out.reserve(encoded_len(input.len(), alphabet.padded));
    let sym = |value: u32, shift: u32| alphabet.encode[((value >> shift) & 0x3F) as usize];
    let (triples, remainder) = input.as_chunks::<3>();
    for c in triples {
        let v = u32::from(c[0]) << 16 | u32::from(c[1]) << 8 | u32::from(c[2]);
        out.extend_from_slice(&[sym(v, 18), sym(v, 12), sym(v, 6), sym(v, 0)]);
    }
    match *remainder {
        [a] => {
            let v = u32::from(a) << 16;
            out.extend_from_slice(&[sym(v, 18), sym(v, 12)]);
            if alphabet.padded {
                out.extend_from_slice(&[PAD, PAD]);
            }
        }
        [a, b] => {
            let v = u32::from(a) << 16 | u32::from(b) << 8;
            out.extend_from_slice(&[sym(v, 18), sym(v, 12), sym(v, 6)]);
            if alphabet.padded {
                out.push(PAD);
            }
        }
        _ => {}
    }
}

fn decode_to_vec(alphabet: &Alphabet, input: &[u8]) -> Option<Vec<u8>> {
    let mut out = vec![0u8; decoded_capacity(input.len())];
    let written = decode_into(alphabet, input, &mut out)?;
    out.truncate(written);
    Some(out)
}

/// Removes the padding and checks that the amount fits the length; `None` if it does not.
fn strip_padding<'a>(alphabet: &Alphabet, input: &'a [u8]) -> Option<&'a [u8]> {
    if !alphabet.padded {
        return Some(input);
    }
    if !input.len().is_multiple_of(4) {
        return None;
    }
    let pad = input
        .iter()
        .rev()
        .take(2)
        .take_while(|&&b| b == PAD)
        .count();
    Some(&input[..input.len() - pad])
}

fn decode_into(alphabet: &Alphabet, input: &[u8], out: &mut [u8]) -> Option<usize> {
    let body = strip_padding(alphabet, input)?;
    let tail_symbols = body.len() % 4;
    if tail_symbols == 1 {
        return None; // 6 bits cannot make a byte
    }
    let needed = body.len() / 4 * 3 + tail_symbols.saturating_sub(1);
    let out = out.get_mut(..needed)?;
    let sym = |b: u8| alphabet.decode[b as usize];

    let (quads, remainder) = body.as_chunks::<4>();
    for (c, o) in quads.iter().zip(out.as_chunks_mut::<3>().0) {
        let (a, b, c2, d) = (sym(c[0]), sym(c[1]), sym(c[2]), sym(c[3]));
        if (a | b | c2 | d) & NOT_A_SYMBOL_MASK != 0 {
            return None;
        }
        let v = u32::from(a) << 18 | u32::from(b) << 12 | u32::from(c2) << 6 | u32::from(d);
        *o = [(v >> 16) as u8, (v >> 8) as u8, v as u8];
    }
    let tail_out = &mut out[body.len() / 4 * 3..];
    match *remainder {
        [] => {}
        [a, b] => {
            let (a, b) = (sym(a), sym(b));
            if (a | b) & NOT_A_SYMBOL_MASK != 0 || b & 0x0F != 0 {
                return None; // invalid symbol, or non-zero trailing bits
            }
            tail_out[0] = a << 2 | b >> 4;
        }
        [a, b, c] => {
            let (a, b, c) = (sym(a), sym(b), sym(c));
            if (a | b | c) & NOT_A_SYMBOL_MASK != 0 || c & 0x03 != 0 {
                return None;
            }
            tail_out[0] = a << 2 | b >> 4;
            tail_out[1] = b << 4 | c >> 2;
        }
        _ => return None, // unreachable: remainder is 0..=3 symbols, 1 was rejected above
    }
    Some(needed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn enc(f: fn(&[u8], &mut Vec<u8>), input: &[u8]) -> String {
        let mut out = Vec::new();
        f(input, &mut out);
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn rfc4648_vectors() {
        let cases = [
            ("", "", ""),
            ("f", "Zg==", "Zg"),
            ("fo", "Zm8=", "Zm8"),
            ("foo", "Zm9v", "Zm9v"),
            ("foob", "Zm9vYg==", "Zm9vYg"),
            ("fooba", "Zm9vYmE=", "Zm9vYmE"),
            ("foobar", "Zm9vYmFy", "Zm9vYmFy"),
        ];
        for (plain, std, url) in cases {
            assert_eq!(enc(encode, plain.as_bytes()), std);
            assert_eq!(enc(encode_url, plain.as_bytes()), url);
            assert_eq!(decode(std.as_bytes()).unwrap(), plain.as_bytes());
            assert_eq!(decode_url(url.as_bytes()).unwrap(), plain.as_bytes());
        }
    }

    #[test]
    fn alphabets_differ_in_62_and_63() {
        let bytes = [0xfb, 0xff, 0xfe];
        assert_eq!(enc(encode, &bytes), "+//+");
        assert_eq!(enc(encode_url, &bytes), "-__-");
        assert!(decode(b"-__-").is_none());
        assert!(decode_url(b"+//+").is_none());
    }

    #[test]
    fn round_trips_every_length_and_byte_value() {
        let data: Vec<u8> = (0..=255).collect();
        for len in 0..data.len() {
            let slice = &data[..len];
            assert_eq!(decode(enc(encode, slice).as_bytes()).unwrap(), slice);
            assert_eq!(
                decode_url(enc(encode_url, slice).as_bytes()).unwrap(),
                slice
            );
        }
    }

    #[test]
    fn rejects_invalid_standard_input() {
        for bad in [
            "Zg=", "Zg", "Z===", "Zm9v=", "Zm=v", "Zm 9", "Zm9\n", "Zh==", "Zm9=", "====",
            "Zg==Zg==",
        ] {
            assert!(
                decode(bad.as_bytes()).is_none(),
                "{bad:?} should be rejected"
            );
        }
        assert!(decode(&[b'Z', b'm', 0xC3, 0xA9]).is_none());
    }

    #[test]
    fn rejects_invalid_url_input() {
        for bad in ["Z", "Zg==", "Zm9v=", "Zm 9", "Zh", "Zm9=", "ZmZmZ", "+/"] {
            assert!(
                decode_url(bad.as_bytes()).is_none(),
                "{bad:?} should be rejected"
            );
        }
    }

    #[test]
    fn decode_into_checks_capacity() {
        let mut small = [0u8; 2];
        assert_eq!(decode_url_into(b"Zm9v", &mut small), None);
        let mut exact = [0u8; 3];
        assert_eq!(decode_url_into(b"Zm9v", &mut exact), Some(3));
        assert_eq!(&exact, b"foo");
    }

    #[test]
    fn length_helpers() {
        for len in 0..40 {
            let data = vec![7u8; len];
            assert_eq!(enc(encode, &data).len(), encoded_len(len, true));
            assert_eq!(enc(encode_url, &data).len(), encoded_len(len, false));
            assert!(decoded_capacity(encoded_len(len, false)) >= len);
        }
    }
}
