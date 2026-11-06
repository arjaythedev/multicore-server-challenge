#![allow(dead_code)]

#[inline]
fn is_ws(c: u8) -> bool {
    c == b' ' || c == b'\n' || c == b'\r' || c == b'\t'
}

#[inline]
fn ws(p: &[u8], mut i: usize, stop: usize) -> usize {
    while i < stop && is_ws(p[i]) {
        i += 1;
    }
    i
}

#[inline]
fn hex_val(c: u8) -> i32 {
    match c {
        b'0'..=b'9' => (c - b'0') as i32,
        b'a'..=b'f' => (c - b'a' + 10) as i32,
        b'A'..=b'F' => (c - b'A' + 10) as i32,
        _ => -1,
    }
}

fn hex4(p: &[u8], i: usize, stop: usize) -> i32 {
    if i + 4 > stop {
        return -1;
    }
    let mut v = 0i32;
    for k in 0..4 {
        let d = hex_val(p[i + k]);
        if d < 0 {
            return -1;
        }
        v = (v << 4) | d;
    }
    v
}

#[inline]
fn put_utf8(out: &mut Vec<u8>, cp: u32) {
    if cp < 0x80 {
        out.push(cp as u8);
    } else if cp < 0x800 {
        out.push((0xC0 | (cp >> 6)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else if cp < 0x10000 {
        out.push((0xE0 | (cp >> 12)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else {
        out.push((0xF0 | (cp >> 18)) as u8);
        out.push((0x80 | ((cp >> 12) & 0x3F)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    }
}

/// Scans a JSON string starting at `p[i] == '"'`; returns the index after the closing quote, or `None`.
fn skip_string(p: &[u8], mut i: usize, stop: usize) -> Option<usize> {
    if i >= stop || p[i] != b'"' {
        return None;
    }
    i += 1;
    while i < stop {
        let c = p[i];
        if c == b'"' {
            return Some(i + 1);
        }
        if c < 0x20 {
            return None;
        }
        if c == b'\\' {
            if i + 1 >= stop {
                return None;
            }
            let e = p[i + 1];
            if e == b'u' {
                if hex4(p, i + 2, stop) < 0 {
                    return None;
                }
                i += 6;
            } else if matches!(e, b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't') {
                i += 2;
            } else {
                return None;
            }
        } else {
            i += 1;
        }
    }
    None
}

/// Decodes a JSON string at `p[i..stop]` (where `p[i] == '"'`) into `out`.
/// Rejects unpaired UTF-16 surrogates.
pub fn decode_string(p: &[u8], mut i: usize, stop: usize, out: &mut Vec<u8>) -> Option<usize> {
    out.clear();
    if i >= stop || p[i] != b'"' {
        return None;
    }
    i += 1;
    let mut run = i;
    while i < stop {
        let c = p[i];
        if c == b'"' {
            if i > run {
                out.extend_from_slice(&p[run..i]);
            }
            return Some(i + 1);
        }
        if c < 0x20 {
            return None;
        }
        if c == b'\\' {
            if i > run {
                out.extend_from_slice(&p[run..i]);
            }
            if i + 1 >= stop {
                return None;
            }
            let e = p[i + 1];
            match e {
                b'"' | b'\\' | b'/' => {
                    out.push(e);
                    i += 2;
                }
                b'b' => {
                    out.push(8);
                    i += 2;
                }
                b'f' => {
                    out.push(12);
                    i += 2;
                }
                b'n' => {
                    out.push(b'\n');
                    i += 2;
                }
                b'r' => {
                    out.push(b'\r');
                    i += 2;
                }
                b't' => {
                    out.push(b'\t');
                    i += 2;
                }
                b'u' => {
                    let u = hex4(p, i + 2, stop);
                    if u < 0 {
                        return None;
                    }
                    i += 6;
                    let mut cp = u as u32;
                    if (0xD800..=0xDBFF).contains(&cp) {
                        if i + 6 > stop || p[i] != b'\\' || p[i + 1] != b'u' {
                            return None;
                        }
                        let low = hex4(p, i + 2, stop);
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return None;
                        }
                        i += 6;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + ((low as u32) - 0xDC00);
                    } else if (0xDC00..=0xDFFF).contains(&cp) {
                        return None;
                    }
                    put_utf8(out, cp);
                }
                _ => return None,
            }
            run = i;
        } else {
            i += 1;
        }
    }
    None
}

fn key_equals(p: &[u8], i: usize, stop: usize, key: &[u8], scratch: &mut Vec<u8>) -> bool {
    if stop >= i + 2 && &p[i + 1..stop - 1] == key {
        return true;
    }
    if stop < i + 2 || !p[i + 1..stop - 1].contains(&b'\\') {
        return false;
    }
    decode_string(p, i, stop, scratch).is_some() && scratch.as_slice() == key
}

fn skip_number(p: &[u8], mut i: usize, stop: usize) -> Option<usize> {
    if i < stop && p[i] == b'-' {
        i += 1;
    }
    if i >= stop {
        return None;
    }
    if p[i] == b'0' {
        i += 1;
    } else if p[i].is_ascii_digit() {
        while i < stop && p[i].is_ascii_digit() {
            i += 1;
        }
    } else {
        return None;
    }
    if i < stop && p[i] == b'.' {
        i += 1;
        if i >= stop || !p[i].is_ascii_digit() {
            return None;
        }
        while i < stop && p[i].is_ascii_digit() {
            i += 1;
        }
    }
    if i < stop && (p[i] == b'e' || p[i] == b'E') {
        i += 1;
        if i < stop && (p[i] == b'+' || p[i] == b'-') {
            i += 1;
        }
        if i >= stop || !p[i].is_ascii_digit() {
            return None;
        }
        while i < stop && p[i].is_ascii_digit() {
            i += 1;
        }
    }
    Some(i)
}

fn skip_value(p: &[u8], i: usize, stop: usize, depth: u32) -> Option<usize> {
    let i = ws(p, i, stop);
    if i >= stop || depth > 64 {
        return None;
    }
    match p[i] {
        b'"' => skip_string(p, i, stop),
        b'{' => {
            let mut j = ws(p, i + 1, stop);
            if j < stop && p[j] == b'}' {
                return Some(j + 1);
            }
            loop {
                if j >= stop || p[j] != b'"' {
                    return None;
                }
                j = skip_string(p, j, stop)?;
                j = ws(p, j, stop);
                if j >= stop || p[j] != b':' {
                    return None;
                }
                j = skip_value(p, j + 1, stop, depth + 1)?;
                j = ws(p, j, stop);
                if j < stop && p[j] == b',' {
                    j = ws(p, j + 1, stop);
                } else if j < stop && p[j] == b'}' {
                    return Some(j + 1);
                } else {
                    return None;
                }
            }
        }
        b'[' => {
            let mut j = ws(p, i + 1, stop);
            if j < stop && p[j] == b']' {
                return Some(j + 1);
            }
            loop {
                j = skip_value(p, j, stop, depth + 1)?;
                j = ws(p, j, stop);
                if j < stop && p[j] == b',' {
                    j += 1;
                } else if j < stop && p[j] == b']' {
                    return Some(j + 1);
                } else {
                    return None;
                }
            }
        }
        b't' => (i + 4 <= stop && &p[i..i + 4] == b"true").then_some(i + 4),
        b'f' => (i + 5 <= stop && &p[i..i + 5] == b"false").then_some(i + 5),
        b'n' => (i + 4 <= stop && &p[i..i + 4] == b"null").then_some(i + 4),
        _ => skip_number(p, i, stop),
    }
}

/// Checks if `p` is a valid RFC 8259 JSON document.
pub fn valid(p: &[u8]) -> bool {
    let Some(i) = skip_value(p, 0, p.len(), 0) else {
        return false;
    };
    ws(p, i, p.len()) == p.len()
}

/// In a valid JSON object `p`, finds the last top-level member `key` and returns its value span `(start, stop)`.
pub fn find(p: &[u8], key: &[u8]) -> Option<(usize, usize)> {
    let stop = p.len();
    let mut i = ws(p, 0, stop);
    if i >= stop || p[i] != b'{' {
        return None;
    }
    i = ws(p, i + 1, stop);
    let mut found: Option<(usize, usize)> = None;
    let mut scratch = Vec::new();
    while i < stop && p[i] == b'"' {
        let kstart = i;
        let kend = skip_string(p, i, stop)?;
        let matches = key_equals(p, kstart, kend, key, &mut scratch);
        i = ws(p, ws(p, kend, stop) + 1, stop);
        let vend = skip_value(p, i, stop, 1)?;
        if matches {
            found = Some((i, vend));
        }
        i = ws(p, vend, stop);
        if i < stop && p[i] == b',' {
            i = ws(p, i + 1, stop);
        }
    }
    found
}

/// Parses a validated JSON number value `p[start..stop]` as an `f64`.
pub fn number(p: &[u8], start: usize, stop: usize) -> Option<f64> {
    if start >= stop || stop > p.len() || stop - start > 63 {
        return None;
    }
    if !(p[start] == b'-' || p[start].is_ascii_digit()) {
        return None;
    }
    let s = std::str::from_utf8(&p[start..stop]).ok()?;
    let v: f64 = s.parse().ok()?;
    if !v.is_finite() {
        return None;
    }
    Some(v)
}

/// Validates `p` as a JSON object and returns `(start, stop)` of its top-level member `key` if that member is an object `{...}`.
pub fn object(p: &[u8], key: &[u8]) -> Option<(usize, usize)> {
    if !valid(p) {
        return None;
    }
    let stop = p.len();
    let mut i = ws(p, 0, stop);
    if i >= stop || p[i] != b'{' {
        return None;
    }
    i = ws(p, i + 1, stop);
    if i < stop && p[i] == b'}' {
        return None;
    }
    let mut scratch = Vec::new();
    let mut found: Option<(usize, usize)> = None;
    while i < stop {
        let kstart = i;
        i = skip_string(p, i, stop)?;
        let hit = key_equals(p, kstart, i, key, &mut scratch);
        i = ws(p, i, stop) + 1;
        let vstart = ws(p, i, stop);
        i = skip_value(p, vstart, stop, 1)?;
        if hit {
            found = if p[vstart] == b'{' {
                Some((vstart, i))
            } else {
                None
            };
        }
        i = ws(p, i, stop);
        if i < stop && p[i] == b',' {
            i = ws(p, i + 1, stop);
        } else {
            break;
        }
    }
    found
}

/// Extracts string or null field `key` from a validated JSON object slice `p[start..stop]`.
/// Returns:
/// - `0`: key absent
/// - `1`: string decoded into `out`
/// - `2`: explicit `null`
/// - `-1`: present with wrong type or invalid UTF-16 surrogate
pub fn field(p: &[u8], start: usize, stop: usize, key: &[u8], out: &mut Vec<u8>) -> i32 {
    let mut i = ws(p, start + 1, stop);
    if i < stop && p[i] == b'}' {
        return 0;
    }
    let mut scratch = Vec::new();
    let mut status = 0i32;
    let mut vstart = 0usize;
    let mut vstop = 0usize;
    while i < stop {
        let kstart = i;
        let Some(kend) = skip_string(p, i, stop) else {
            return -1;
        };
        let hit = key_equals(p, kstart, kend, key, &mut scratch);
        i = ws(p, kend, stop) + 1;
        let vs = ws(p, i, stop);
        let Some(ve) = skip_value(p, vs, stop, 1) else {
            return -1;
        };
        i = ve;
        if hit {
            vstart = vs;
            vstop = ve;
            status = 1;
        }
        i = ws(p, i, stop);
        if i < stop && p[i] == b',' {
            i = ws(p, i + 1, stop);
        } else {
            break;
        }
    }
    if status == 0 {
        return 0;
    }
    if p[vstart] == b'n' {
        return 2;
    }
    if p[vstart] == b'"' && decode_string(p, vstart, vstop, out).is_some() {
        return 1;
    }
    -1
}

/// Extracts a string array field `key` from a validated JSON object slice `p[start..stop]`.
/// Appends each element's raw quoted span `(elem_start, elem_stop)` in `p` to `items`.
/// Returns `0` if absent, `1` if valid string array, `-1` if invalid/wrong type.
pub fn string_array(
    p: &[u8],
    start: usize,
    stop: usize,
    key: &[u8],
    items: &mut Vec<(usize, usize)>,
) -> i32 {
    items.clear();
    let mut i = ws(p, start + 1, stop);
    if i < stop && p[i] == b'}' {
        return 0;
    }
    let mut scratch = Vec::new();
    let mut vstart = 0usize;
    let mut vstop = 0usize;
    let mut found = false;
    while i < stop {
        let kstart = i;
        let Some(kend) = skip_string(p, i, stop) else {
            return -1;
        };
        let hit = key_equals(p, kstart, kend, key, &mut scratch);
        i = ws(p, kend, stop) + 1;
        let vs = ws(p, i, stop);
        let Some(ve) = skip_value(p, vs, stop, 1) else {
            return -1;
        };
        i = ve;
        if hit {
            vstart = vs;
            vstop = ve;
            found = true;
        }
        i = ws(p, i, stop);
        if i < stop && p[i] == b',' {
            i = ws(p, i + 1, stop);
        } else {
            break;
        }
    }
    if !found || p[vstart] == b'n' {
        return 0;
    }
    if p[vstart] != b'[' {
        return -1;
    }
    let mut j = ws(p, vstart + 1, vstop);
    if j < vstop && p[j] == b']' {
        return 1;
    }
    while j < vstop {
        j = ws(p, j, vstop);
        if j >= vstop || p[j] != b'"' {
            return -1;
        }
        let s = j;
        let Some(e) = decode_string(p, s, vstop, &mut scratch) else {
            return -1;
        };
        items.push((s, e));
        j = ws(p, e, vstop);
        if j < vstop && p[j] == b',' {
            j += 1;
        } else {
            break;
        }
    }
    1
}

/// In a validated JSON array `p[..stop]`, starting at `i` (after `[` or previous element),
/// returns `(elem_start, elem_stop)` of the next element, or `None` if at `]`.
pub fn next_element(p: &[u8], mut i: usize, stop: usize) -> Option<(usize, usize)> {
    i = ws(p, i, stop);
    if i < stop && p[i] == b',' {
        i = ws(p, i + 1, stop);
    }
    if i >= stop || p[i] == b']' {
        return None;
    }
    let e = skip_value(p, i, stop, 1)?;
    Some((i, e))
}

/// Validates `p` as JSON and returns the sub-slice `&p[s..e]` of the top-level object member `key`.
pub fn body_object<'a>(p: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let (s, e) = object(p, key)?;
    Some(&p[s..e])
}

/// Extracts field `key` from a validated JSON object slice `obj`:
/// `1` = string (decoded into `out`), `0` = absent or `null`, `-1` = other type.
pub fn obj_field(obj: &[u8], key: &[u8], out: &mut Vec<u8>) -> i32 {
    out.clear();
    let Some((fs, fe)) = find(obj, key) else {
        return 0;
    };
    if obj[fs] == b'n' {
        return 0;
    }
    if obj[fs] == b'"' && decode_string(obj, fs, fe, out) == Some(fe) {
        1
    } else {
        -1
    }
}

pub fn required(obj: &[u8], key: &[u8], out: &mut Vec<u8>) -> bool {
    obj_field(obj, key, out) == 1 && !out.is_empty()
}

