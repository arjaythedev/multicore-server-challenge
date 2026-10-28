//! Binary value codecs: encoding of bind parameters, decoding of result columns, one-dimensional arrays.
//!
//! Everything uses Postgres' binary formats (big endian integers, UTF-8 text, the array header documented in
//! `array_send`). Only the types this server uses exist; there is no registry of types.
//!
//! Arrays: encoding supports `int8[]` and `text[]` without NULL elements. Decoding accepts the same shapes (zero or
//! one dimension, any lower bound, no NULL elements) and refuses everything else with a protocol error.

use super::error::PgError;
use super::wire::put_i32;

/// Type OIDs from `pg_type`.
pub const BOOL: u32 = 16;
pub const INT8: u32 = 20;
pub const INT4: u32 = 23;
pub const TEXT: u32 = 25;
pub const TEXT_ARRAY: u32 = 1009;
pub const INT8_ARRAY: u32 = 1016;
pub const TIMESTAMPTZ: u32 = 1184;

/// Length prefix that marks a NULL value.
pub(super) const NULL_LEN: i32 = -1;
/// Bytes of the length prefix before every value and array element.
const LEN_PREFIX: usize = 4;
/// Array header: ndim, has-null flag, element OID (three i32).
const ARRAY_HEADER: usize = 12;
/// Per-dimension part of the array header: length and lower bound (two i32).
const ARRAY_DIM: usize = 8;

/// A bind parameter. Borrowed data is copied into the outgoing buffer by `push`, so it only has to live that long.
#[derive(Debug, Clone, Copy)]
pub enum Param<'a> {
    Null,
    Int8(i64),
    Int4(i32),
    Bool(bool),
    Text(&'a str),
    Int8Array(&'a [i64]),
    TextArray(&'a [&'a str]),
}

/// Appends one length-prefixed parameter value. The length is written last, so nothing is built twice.
pub(super) fn encode_param(out: &mut Vec<u8>, param: &Param<'_>) -> Result<(), PgError> {
    let len_pos = out.len();
    put_i32(out, NULL_LEN);
    match *param {
        Param::Null => return Ok(()),
        Param::Int8(v) => out.extend_from_slice(&v.to_be_bytes()),
        Param::Int4(v) => out.extend_from_slice(&v.to_be_bytes()),
        Param::Bool(v) => out.push(u8::from(v)),
        Param::Text(s) => out.extend_from_slice(s.as_bytes()),
        Param::Int8Array(values) => {
            put_array_header(out, INT8, values.len())?;
            for v in values {
                put_i32(out, 8);
                out.extend_from_slice(&v.to_be_bytes());
            }
        }
        Param::TextArray(values) => {
            put_array_header(out, TEXT, values.len())?;
            for s in values {
                put_i32(out, length_i32(s.len())?);
                out.extend_from_slice(s.as_bytes());
            }
        }
    }
    let len = length_i32(out.len() - len_pos - LEN_PREFIX)?;
    out[len_pos..len_pos + LEN_PREFIX].copy_from_slice(&len.to_be_bytes());
    Ok(())
}

fn length_i32(len: usize) -> Result<i32, PgError> {
    i32::try_from(len).map_err(|_| PgError::protocol("value larger than 2 GiB"))
}

/// An empty array is `ndim = 0` and carries no dimension block; otherwise one dimension with lower bound 1.
fn put_array_header(out: &mut Vec<u8>, elem_oid: u32, count: usize) -> Result<(), PgError> {
    let ndim = i32::from(count != 0);
    put_i32(out, ndim);
    put_i32(out, 0); // has-null flag
    out.extend_from_slice(&elem_oid.to_be_bytes());
    if count != 0 {
        put_i32(out, length_i32(count)?);
        put_i32(out, 1); // lower bound
    }
    Ok(())
}

fn fixed<const N: usize>(bytes: &[u8], what: &str) -> Result<[u8; N], PgError> {
    <[u8; N]>::try_from(bytes)
        .map_err(|_| PgError::protocol(format!("{what}: expected {N} bytes, got {}", bytes.len())))
}

pub fn decode_i64(bytes: &[u8]) -> Result<i64, PgError> {
    Ok(i64::from_be_bytes(fixed(bytes, "int8")?))
}

pub fn decode_i32(bytes: &[u8]) -> Result<i32, PgError> {
    Ok(i32::from_be_bytes(fixed(bytes, "int4")?))
}

pub fn decode_bool(bytes: &[u8]) -> Result<bool, PgError> {
    Ok(fixed::<1>(bytes, "bool")?[0] != 0)
}

pub fn decode_str(bytes: &[u8]) -> Result<&str, PgError> {
    std::str::from_utf8(bytes).map_err(|_| PgError::protocol("text value is not valid UTF-8"))
}

/// Validated view of the elements of a one-dimensional array.
struct ArrayBody<'a> {
    count: usize,
    elements: &'a [u8],
}

/// Checks the header (shape, no NULLs, element type) and returns the element bytes.
fn parse_array(bytes: &[u8], expected_oid: u32) -> Result<ArrayBody<'_>, PgError> {
    let header = bytes
        .get(..ARRAY_HEADER)
        .ok_or_else(|| PgError::protocol("array header truncated"))?;
    let word = |i: usize| {
        i32::from_be_bytes([
            header[i * 4],
            header[i * 4 + 1],
            header[i * 4 + 2],
            header[i * 4 + 3],
        ])
    };
    let (ndim, has_null, oid) = (word(0), word(1), word(2) as u32);
    if oid != expected_oid {
        return Err(PgError::protocol(format!(
            "array element oid {oid}, expected {expected_oid}"
        )));
    }
    if has_null != 0 {
        return Err(PgError::protocol(
            "array with NULL elements is not supported",
        ));
    }
    match ndim {
        0 => Ok(ArrayBody {
            count: 0,
            elements: &[],
        }),
        1 => {
            let dim = bytes
                .get(ARRAY_HEADER..ARRAY_HEADER + ARRAY_DIM)
                .ok_or_else(|| PgError::protocol("array dimension truncated"))?;
            let count = i32::from_be_bytes([dim[0], dim[1], dim[2], dim[3]]);
            let count =
                usize::try_from(count).map_err(|_| PgError::protocol("negative array length"))?;
            Ok(ArrayBody {
                count,
                elements: &bytes[ARRAY_HEADER + ARRAY_DIM..],
            })
        }
        n => Err(PgError::protocol(format!(
            "{n}-dimensional arrays are not supported"
        ))),
    }
}

/// Splits the next `[len][bytes]` element off `rest`. Callers have validated the structure beforehand.
fn next_element<'a>(rest: &mut &'a [u8]) -> Option<&'a [u8]> {
    let (len, tail) = rest.split_first_chunk::<LEN_PREFIX>()?;
    let len = usize::try_from(i32::from_be_bytes(*len)).ok()?;
    let value = tail.get(..len)?;
    *rest = &tail[len..];
    Some(value)
}

/// Iterator over a `text[]` column. Construction validated structure and UTF-8, so iteration cannot fail.
#[derive(Debug, Clone)]
pub struct TextArray<'a> {
    rest: &'a [u8],
    remaining: usize,
}

impl<'a> TextArray<'a> {
    pub fn parse(bytes: &'a [u8]) -> Result<Self, PgError> {
        let ArrayBody { count, elements } = parse_array(bytes, TEXT)?;
        let mut rest = elements;
        for _ in 0..count {
            let value = next_element(&mut rest)
                .ok_or_else(|| PgError::protocol("text array element out of bounds"))?;
            decode_str(value)?;
        }
        if !rest.is_empty() {
            return Err(PgError::protocol("trailing bytes after array elements"));
        }
        Ok(TextArray {
            rest: elements,
            remaining: count,
        })
    }
}

impl<'a> Iterator for TextArray<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        if self.remaining == 0 {
            return None;
        }
        self.remaining -= 1;
        // Validated in `parse`; the fallback is unreachable and only keeps this function total.
        Some(std::str::from_utf8(next_element(&mut self.rest)?).unwrap_or_default())
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}

impl ExactSizeIterator for TextArray<'_> {}

/// Iterator over an `int8[]` column. Construction validated the structure, so iteration cannot fail.
#[derive(Debug, Clone)]
pub struct Int8Array<'a> {
    rest: &'a [u8],
    remaining: usize,
}

/// Bytes of one int8 array element on the wire: length prefix plus the 8 value bytes.
const INT8_ELEMENT: usize = LEN_PREFIX + 8;

impl<'a> Int8Array<'a> {
    pub fn parse(bytes: &'a [u8]) -> Result<Self, PgError> {
        let ArrayBody { count, elements } = parse_array(bytes, INT8)?;
        // Fixed-width elements: the whole body can be validated with one multiplication.
        if count.checked_mul(INT8_ELEMENT) != Some(elements.len()) {
            return Err(PgError::protocol("int8 array body has the wrong size"));
        }
        let all_eight = (elements.as_chunks::<INT8_ELEMENT>().0.iter())
            .all(|e| e[..LEN_PREFIX] == 8_i32.to_be_bytes());
        if !all_eight {
            return Err(PgError::protocol(
                "int8 array element with a length other than 8",
            ));
        }
        Ok(Int8Array {
            rest: elements,
            remaining: count,
        })
    }
}

impl Iterator for Int8Array<'_> {
    type Item = i64;

    fn next(&mut self) -> Option<i64> {
        if self.remaining == 0 {
            return None;
        }
        self.remaining -= 1;
        let (element, tail) = self.rest.split_first_chunk::<INT8_ELEMENT>()?;
        self.rest = tail;
        Some(i64::from_be_bytes([
            element[4],
            element[5],
            element[6],
            element[7],
            element[8],
            element[9],
            element[10],
            element[11],
        ]))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}

impl ExactSizeIterator for Int8Array<'_> {}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded(param: Param<'_>) -> Vec<u8> {
        let mut out = Vec::new();
        encode_param(&mut out, &param).unwrap();
        out
    }

    /// Strips the 4-byte length prefix (after checking it).
    fn value_of(param: Param<'_>) -> Vec<u8> {
        let out = encoded(param);
        let len = i32::from_be_bytes(out[..4].try_into().unwrap());
        assert_eq!(len as usize, out.len() - 4);
        out[4..].to_vec()
    }

    #[test]
    fn scalars() {
        assert_eq!(encoded(Param::Null), (-1_i32).to_be_bytes());
        assert_eq!(value_of(Param::Int8(-2)), (-2_i64).to_be_bytes());
        assert_eq!(value_of(Param::Int4(0x0102_0304)), [1, 2, 3, 4]);
        assert_eq!(value_of(Param::Bool(true)), [1]);
        assert_eq!(value_of(Param::Bool(false)), [0]);
        assert_eq!(value_of(Param::Text("åäö")), "åäö".as_bytes());
        assert_eq!(value_of(Param::Text("")), b"");
    }

    #[test]
    fn int8_array_layout_and_round_trip() {
        let v = value_of(Param::Int8Array(&[1, -5]));
        // ndim 1, no nulls, oid 20, length 2, lower bound 1, then two (len 8, value) elements.
        assert_eq!(
            &v[..20],
            b"\0\0\0\x01\0\0\0\0\0\0\0\x14\0\0\0\x02\0\0\0\x01"
        );
        assert_eq!(v.len(), 20 + 2 * 12);
        assert_eq!(Int8Array::parse(&v).unwrap().collect::<Vec<_>>(), [1, -5]);
    }

    #[test]
    fn empty_arrays_have_no_dimension_block() {
        let v = value_of(Param::Int8Array(&[]));
        assert_eq!(v, b"\0\0\0\0\0\0\0\0\0\0\0\x14");
        assert_eq!(Int8Array::parse(&v).unwrap().count(), 0);
        let v = value_of(Param::TextArray(&[]));
        assert_eq!(v.len(), 12);
        assert_eq!(TextArray::parse(&v).unwrap().count(), 0);
    }

    #[test]
    fn text_array_round_trip() {
        let v = value_of(Param::TextArray(&["a", "", "ö"]));
        let it = TextArray::parse(&v).unwrap();
        assert_eq!(it.len(), 3);
        assert_eq!(it.collect::<Vec<_>>(), ["a", "", "ö"]);
    }

    #[test]
    fn array_parser_rejects_bad_input() {
        let ok = value_of(Param::TextArray(&["ab"]));
        assert!(
            TextArray::parse(&ok[..ok.len() - 1]).is_err(),
            "truncated element"
        );
        let mut trailing = ok.clone();
        trailing.push(0);
        assert!(TextArray::parse(&trailing).is_err(), "trailing bytes");
        let mut bad_utf8 = ok.clone();
        *bad_utf8.last_mut().unwrap() = 0xff;
        assert!(TextArray::parse(&bad_utf8).is_err(), "invalid UTF-8");
        assert!(Int8Array::parse(&ok).is_err(), "wrong element oid");
        assert!(TextArray::parse(&[0; 5]).is_err(), "short header");
        let mut with_null = ok.clone();
        with_null[7] = 1;
        assert!(TextArray::parse(&with_null).is_err(), "has-null flag");
        let mut two_dim = ok;
        two_dim[3] = 2;
        assert!(TextArray::parse(&two_dim).is_err(), "two dimensions");
    }

    #[test]
    fn int8_array_rejects_wrong_sizes() {
        let ok = value_of(Param::Int8Array(&[7]));
        assert!(Int8Array::parse(&ok[..ok.len() - 1]).is_err());
        let mut bad_len = ok;
        bad_len[23] = 4;
        assert!(Int8Array::parse(&bad_len).is_err());
    }

    #[test]
    fn scalar_decoders_check_width() {
        assert_eq!(decode_i64(&5_i64.to_be_bytes()).unwrap(), 5);
        assert!(decode_i64(&[0; 4]).is_err());
        assert_eq!(decode_i32(&[0, 0, 1, 0]).unwrap(), 256);
        assert!(decode_bool(&[]).is_err());
        assert!(decode_bool(&[1]).unwrap());
        assert!(decode_str(&[0xc3]).is_err());
    }
}
