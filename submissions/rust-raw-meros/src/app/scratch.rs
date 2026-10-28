//! Text that cannot stay where the client sent it, and how it joins the request buffer afterwards.
//!
//! Almost every string the app needs (slug, username, tag, title, ...) is a plain byte range of the request buffer
//! and costs nothing ([`Field`]). A percent-escaped path segment or a JSON string with escape sequences has to be
//! decoded into new bytes. Those are collected here, and [`Scratch::commit`] appends them to the end of the request
//! buffer, so a job still owns exactly one buffer and its fields stay plain ranges.

use std::borrow::Cow;

use super::jobs::Field;

/// Marks a field whose bytes are in the scratch area (offset in the low 31 bits) until `commit` moves them.
const SCRATCH_BIT: u32 = 1 << 31;

/// Decoded text waiting to be appended to the request buffer.
#[derive(Default)]
pub struct Scratch {
    bytes: Vec<u8>,
}

/// The range of `part` inside `base`. `part` must be a subslice of `base`.
pub fn field_of(base: &[u8], part: &[u8]) -> Field {
    let start = (part.as_ptr() as usize).wrapping_sub(base.as_ptr() as usize);
    debug_assert!(
        start <= base.len() && start + part.len() <= base.len(),
        "not a subslice"
    );
    Field::new(start..start + part.len())
}

impl Scratch {
    /// A field for `text`, which is either a subslice of `base` (free) or newly decoded (copied once).
    #[allow(clippy::ptr_arg)] // the Borrowed/Owned variant is the point: borrowed text is free
    pub fn field(&mut self, base: &[u8], text: &Cow<'_, [u8]>) -> Field {
        match text {
            Cow::Borrowed(part) => field_of(base, part),
            Cow::Owned(decoded) => self.stash(decoded),
        }
    }

    /// Like [`Scratch::field`] for a JSON string.
    #[allow(clippy::ptr_arg)] // as above
    pub fn field_str(&mut self, base: &[u8], text: &Cow<'_, str>) -> Field {
        match text {
            Cow::Borrowed(part) => field_of(base, part.as_bytes()),
            Cow::Owned(decoded) => self.stash(decoded.as_bytes()),
        }
    }

    fn stash(&mut self, decoded: &[u8]) -> Field {
        let start = self.bytes.len() as u32;
        self.bytes.extend_from_slice(decoded);
        Field {
            start: start | SCRATCH_BIT,
            end: (start + decoded.len() as u32) | SCRATCH_BIT,
        }
    }

    /// Appends the decoded bytes to `buf` and points the stashed fields at them.
    pub fn commit<'f>(self, buf: &mut Vec<u8>, fields: impl IntoIterator<Item = &'f mut Field>) {
        if self.bytes.is_empty() {
            return;
        }
        let base = buf.len() as u32;
        buf.extend_from_slice(&self.bytes);
        for field in fields {
            if field.start & SCRATCH_BIT != 0 {
                field.start = base + (field.start & !SCRATCH_BIT);
                field.end = base + (field.end & !SCRATCH_BIT);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn borrowed_text_is_a_range_and_owned_text_is_appended() {
        let mut buf = b"GET /api/tags".to_vec();
        let mut scratch = Scratch::default();
        let tags = scratch.field(&buf, &Cow::Borrowed(&buf[9..13]));
        let decoded = scratch.field(&buf, &Cow::Owned(b"a b".to_vec()));
        assert_eq!((tags.start, tags.end), (9, 13));
        let (mut tags, mut decoded) = (tags, decoded);
        scratch.commit(&mut buf, [&mut tags, &mut decoded]);
        assert_eq!(tags.text(&buf), "tags");
        assert_eq!(decoded.text(&buf), "a b");
    }
}
