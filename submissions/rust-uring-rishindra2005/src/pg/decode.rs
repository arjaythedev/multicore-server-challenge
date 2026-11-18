//! Binary protocol decoder for PostgreSQL 18 wire format.
//!
//! Provides zero-copy parsing of PostgreSQL binary representation for:
//! - 16, 32, and 64-bit big-endian integers
//! - Strings (&str without UTF-8 re-validation where safe)
//! - Booleans (1 byte: 0 = false, non-zero = true)
//! - Timestamps (i64 microseconds since 2000-01-01 00:00:00 UTC)
//! - 1D Arrays (int4[], int8[], text[])

use std::str;

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    BufferTooShort,
    InvalidUtf8,
    InvalidArrayHeader,
    UnexpectedNull,
}

/// Reads a big-endian i16 from the front of the slice.
#[inline(always)]
pub fn read_i16(buf: &[u8]) -> Result<(i16, &[u8]), DecodeError> {
    if buf.len() < 2 {
        return Err(DecodeError::BufferTooShort);
    }
    let val = i16::from_be_bytes([buf[0], buf[1]]);
    Ok((val, &buf[2..]))
}

/// Reads a big-endian i32 from the front of the slice.
#[inline(always)]
pub fn read_i32(buf: &[u8]) -> Result<(i32, &[u8]), DecodeError> {
    if buf.len() < 4 {
        return Err(DecodeError::BufferTooShort);
    }
    let val = i32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
    Ok((val, &buf[4..]))
}

/// Reads a big-endian i64 from the front of the slice.
#[inline(always)]
pub fn read_i64(buf: &[u8]) -> Result<(i64, &[u8]), DecodeError> {
    if buf.len() < 8 {
        return Err(DecodeError::BufferTooShort);
    }
    let val = i64::from_be_bytes([
        buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
    ]);
    Ok((val, &buf[8..]))
}

/// Reads a boolean from the front of the slice (1 byte: 0=false, otherwise true).
#[inline(always)]
pub fn read_bool(buf: &[u8]) -> Result<(bool, &[u8]), DecodeError> {
    if buf.is_empty() {
        return Err(DecodeError::BufferTooShort);
    }
    Ok((buf[0] != 0, &buf[1..]))
}

/// Decodes a string slice without copying.
#[inline(always)]
pub fn decode_str(buf: &[u8]) -> Result<&str, DecodeError> {
    str::from_utf8(buf).map_err(|_| DecodeError::InvalidUtf8)
}

/// Reads a string column from PostgreSQL wire format (col_len followed by UTF-8 bytes).
#[inline(always)]
pub fn read_str(buf: &[u8]) -> Result<(&str, &[u8]), DecodeError> {
    let (col_opt, rest) = read_col_raw(buf)?;
    match col_opt {
        Some(bytes) => {
            let s = decode_str(bytes)?;
            Ok((s, rest))
        }
        None => Err(DecodeError::UnexpectedNull),
    }
}

/// Reads a column value length header (-1 indicates SQL NULL).
#[inline(always)]
pub fn read_col_raw(buf: &[u8]) -> Result<(Option<&[u8]>, &[u8]), DecodeError> {
    let (len, rest) = read_i32(buf)?;
    if len < 0 {
        Ok((None, rest))
    } else {
        let ulen = len as usize;
        if rest.len() < ulen {
            return Err(DecodeError::BufferTooShort);
        }
        Ok((Some(&rest[..ulen]), &rest[ulen..]))
    }
}

/// Zero-copy PostgreSQL binary DataRow reader.
#[derive(Clone, Copy, Debug)]
pub struct BinaryRow<'a> {
    raw: &'a [u8],
    num_cols: usize,
}

impl<'a> BinaryRow<'a> {
    pub fn new(raw: &'a [u8]) -> Self {
        let num_cols = if raw.len() >= 2 {
            i16::from_be_bytes([raw[0], raw[1]]) as usize
        } else {
            0
        };
        Self { raw, num_cols }
    }

    #[inline(always)]
    pub fn num_cols(&self) -> usize {
        self.num_cols
    }

    /// Returns the raw slice for the column at `idx` (None if NULL).
    pub fn get_raw(&self, idx: usize) -> Option<&'a [u8]> {
        if idx >= self.num_cols || self.raw.len() < 2 {
            return None;
        }
        let mut curr = &self.raw[2..];
        for i in 0..=idx {
            if curr.len() < 4 {
                return None;
            }
            let len = i32::from_be_bytes([curr[0], curr[1], curr[2], curr[3]]);
            curr = &curr[4..];
            if len < 0 {
                if i == idx {
                    return None;
                }
            } else {
                let ulen = len as usize;
                if curr.len() < ulen {
                    return None;
                }
                if i == idx {
                    return Some(&curr[..ulen]);
                }
                curr = &curr[ulen..];
            }
        }
        None
    }

    #[inline(always)]
    pub fn get_i16(&self, idx: usize) -> Option<i16> {
        let bytes = self.get_raw(idx)?;
        if bytes.len() >= 2 {
            Some(i16::from_be_bytes([bytes[0], bytes[1]]))
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn get_i32(&self, idx: usize) -> Option<i32> {
        let bytes = self.get_raw(idx)?;
        if bytes.len() >= 4 {
            Some(i32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn get_i64(&self, idx: usize) -> Option<i64> {
        let bytes = self.get_raw(idx)?;
        if bytes.len() >= 8 {
            Some(i64::from_be_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]))
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn get_bool(&self, idx: usize) -> Option<bool> {
        let bytes = self.get_raw(idx)?;
        if !bytes.is_empty() {
            Some(bytes[0] != 0)
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn get_str(&self, idx: usize) -> Option<&'a str> {
        let bytes = self.get_raw(idx)?;
        str::from_utf8(bytes).ok()
    }
}

/// High-level utility decoder for PostgreSQL binary wire structures.
pub struct BinaryDecoder;

impl BinaryDecoder {
    #[inline(always)]
    pub fn row(raw: &[u8]) -> BinaryRow<'_> {
        BinaryRow::new(raw)
    }

    #[inline(always)]
    pub fn decode_int4_array(buf: &[u8], out: &mut Vec<i32>) -> Result<(), DecodeError> {
        decode_int4_array(buf, out)
    }

    #[inline(always)]
    pub fn decode_int8_array(buf: &[u8], out: &mut Vec<i64>) -> Result<(), DecodeError> {
        decode_int8_array(buf, out)
    }

    #[inline(always)]
    pub fn decode_text_array<'a>(buf: &'a [u8], out: &mut Vec<&'a str>) -> Result<(), DecodeError> {
        decode_text_array(buf, out)
    }
}

/// High-level utility encoder for PostgreSQL binary wire structures.
pub struct BinaryEncoder;

impl BinaryEncoder {
    #[inline(always)]
    pub fn encode_text_array<S: AsRef<str>>(tags: &[S], out: &mut Vec<u8>) {
        encode_text_array(tags, out)
    }
}

/// Decodes a 1D int4 array from Postgres binary representation.
pub fn decode_int4_array<'a>(buf: &'a [u8], out: &mut Vec<i32>) -> Result<(), DecodeError> {
    out.clear();
    if buf.is_empty() {
        return Ok(());
    }
    let (ndim, rest) = read_i32(buf)?;
    if ndim == 0 {
        return Ok(());
    }
    if ndim != 1 {
        return Err(DecodeError::InvalidArrayHeader);
    }
    let (_has_null, rest) = read_i32(rest)?;
    let (_elem_oid, rest) = read_i32(rest)?;
    let (dim_len, rest) = read_i32(rest)?;
    let (_lbound, mut curr) = read_i32(rest)?;

    if dim_len <= 0 {
        return Ok(());
    }
    let count = dim_len as usize;
    out.reserve(count);

    for _ in 0..count {
        let (val_opt, rest) = read_col_raw(curr)?;
        curr = rest;
        match val_opt {
            Some(v) => {
                let (elem, _) = read_i32(v)?;
                out.push(elem);
            }
            None => {
                out.push(0);
            }
        }
    }
    Ok(())
}

/// Decodes a 1D int8 array from Postgres binary representation.
pub fn decode_int8_array<'a>(buf: &'a [u8], out: &mut Vec<i64>) -> Result<(), DecodeError> {
    out.clear();
    if buf.is_empty() {
        return Ok(());
    }
    let (ndim, rest) = read_i32(buf)?;
    if ndim == 0 {
        return Ok(());
    }
    if ndim != 1 {
        return Err(DecodeError::InvalidArrayHeader);
    }
    let (_has_null, rest) = read_i32(rest)?;
    let (_elem_oid, rest) = read_i32(rest)?;
    let (dim_len, rest) = read_i32(rest)?;
    let (_lbound, mut curr) = read_i32(rest)?;

    if dim_len <= 0 {
        return Ok(());
    }
    let count = dim_len as usize;
    out.reserve(count);

    for _ in 0..count {
        let (val_opt, rest) = read_col_raw(curr)?;
        curr = rest;
        match val_opt {
            Some(v) => {
                let (elem, _) = read_i64(v)?;
                out.push(elem);
            }
            None => {
                out.push(0);
            }
        }
    }
    Ok(())
}

/// Decodes a 1D text/varchar array from Postgres binary representation into string slices.
pub fn decode_text_array<'a>(buf: &'a [u8], out: &mut Vec<&'a str>) -> Result<(), DecodeError> {
    out.clear();
    if buf.is_empty() {
        return Ok(());
    }
    let (ndim, rest) = read_i32(buf)?;
    if ndim == 0 {
        return Ok(());
    }
    if ndim != 1 {
        return Err(DecodeError::InvalidArrayHeader);
    }
    let (_has_null, rest) = read_i32(rest)?;
    let (_elem_oid, rest) = read_i32(rest)?;
    let (dim_len, rest) = read_i32(rest)?;
    let (_lbound, mut curr) = read_i32(rest)?;

    if dim_len <= 0 {
        return Ok(());
    }
    let count = dim_len as usize;
    out.reserve(count);

    for _ in 0..count {
        let (val_opt, rest) = read_col_raw(curr)?;
        curr = rest;
        if let Some(v) = val_opt {
            let s = decode_str(v)?;
            out.push(s);
        }
    }
    Ok(())
}

/// Encodes a slice of strings into PostgreSQL 1D text array binary representation (OID 1009).
pub fn encode_text_array<S: AsRef<str>>(tags: &[S], out: &mut Vec<u8>) {
    if tags.is_empty() {
        out.extend_from_slice(&0i32.to_be_bytes()); // ndim = 0
        out.extend_from_slice(&0i32.to_be_bytes()); // has_null = 0
        out.extend_from_slice(&25i32.to_be_bytes()); // elem_oid = 25 (text)
        return;
    }
    out.extend_from_slice(&1i32.to_be_bytes()); // ndim = 1
    out.extend_from_slice(&0i32.to_be_bytes()); // has_null = 0
    out.extend_from_slice(&25i32.to_be_bytes()); // elem_oid = 25
    out.extend_from_slice(&(tags.len() as i32).to_be_bytes()); // dim_len
    out.extend_from_slice(&1i32.to_be_bytes()); // lbound = 1
    for t in tags {
        let b = t.as_ref().as_bytes();
        out.extend_from_slice(&(b.len() as i32).to_be_bytes());
        out.extend_from_slice(b);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_primitive_decoding() {
        let b16 = 42i16.to_be_bytes();
        let (val16, rest) = read_i16(&b16).unwrap();
        assert_eq!(val16, 42);
        assert!(rest.is_empty());

        let b32 = 123456i32.to_be_bytes();
        let (val32, rest) = read_i32(&b32).unwrap();
        assert_eq!(val32, 123456);
        assert!(rest.is_empty());

        let b64 = 9876543210i64.to_be_bytes();
        let (val64, rest) = read_i64(&b64).unwrap();
        assert_eq!(val64, 9876543210);
        assert!(rest.is_empty());
    }

    #[test]
    fn test_col_raw() {
        // null column
        let mut buf = Vec::new();
        buf.extend_from_slice(&(-1i32).to_be_bytes());
        let (res, rest) = read_col_raw(&buf).unwrap();
        assert_eq!(res, None);
        assert!(rest.is_empty());

        // value column
        let mut buf2 = Vec::new();
        let text = b"hello postgres";
        buf2.extend_from_slice(&(text.len() as i32).to_be_bytes());
        buf2.extend_from_slice(text);
        let (res2, rest2) = read_col_raw(&buf2).unwrap();
        assert_eq!(res2, Some(&text[..]));
        assert!(rest2.is_empty());
        assert_eq!(decode_str(res2.unwrap()).unwrap(), "hello postgres");
    }

    #[test]
    fn test_binary_row() {
        let mut data = Vec::new();
        // 3 columns
        data.extend_from_slice(&3i16.to_be_bytes());
        // col 0: i64 = 1001
        data.extend_from_slice(&8i32.to_be_bytes());
        data.extend_from_slice(&1001i64.to_be_bytes());
        // col 1: null
        data.extend_from_slice(&(-1i32).to_be_bytes());
        // col 2: text = "conduit"
        data.extend_from_slice(&7i32.to_be_bytes());
        data.extend_from_slice(b"conduit");

        let row = BinaryRow::new(&data);
        assert_eq!(row.num_cols(), 3);
        assert_eq!(row.get_i64(0), Some(1001));
        assert_eq!(row.get_raw(1), None);
        assert_eq!(row.get_str(2), Some("conduit"));
    }

    #[test]
    fn test_decode_text_array() {
        let mut buf = Vec::new();
        // ndim = 1
        buf.extend_from_slice(&1i32.to_be_bytes());
        // has_null = 0
        buf.extend_from_slice(&0i32.to_be_bytes());
        // elem_oid = 25 (text)
        buf.extend_from_slice(&25i32.to_be_bytes());
        // dim_len = 2
        buf.extend_from_slice(&2i32.to_be_bytes());
        // lbound = 1
        buf.extend_from_slice(&1i32.to_be_bytes());
        // elem 0: "dragons"
        buf.extend_from_slice(&7i32.to_be_bytes());
        buf.extend_from_slice(b"dragons");
        // elem 1: "training"
        buf.extend_from_slice(&8i32.to_be_bytes());
        buf.extend_from_slice(b"training");

        let mut out = Vec::new();
        BinaryDecoder::decode_text_array(&buf, &mut out).unwrap();
        assert_eq!(out, vec!["dragons", "training"]);
    }

    #[test]
    fn test_encode_decode_text_array() {
        // Test non-empty array
        let tags = ["rust", "uring", "fast"];
        let mut encoded = Vec::new();
        BinaryEncoder::encode_text_array(&tags, &mut encoded);

        let mut decoded = Vec::new();
        BinaryDecoder::decode_text_array(&encoded, &mut decoded).unwrap();
        assert_eq!(decoded, vec!["rust", "uring", "fast"]);

        // Test empty array
        let empty_tags: [&str; 0] = [];
        let mut empty_encoded = Vec::new();
        BinaryEncoder::encode_text_array(&empty_tags, &mut empty_encoded);

        let mut empty_decoded = Vec::new();
        BinaryDecoder::decode_text_array(&empty_encoded, &mut empty_decoded).unwrap();
        assert!(empty_decoded.is_empty());
    }
}
