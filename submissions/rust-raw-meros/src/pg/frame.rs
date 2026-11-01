//! Buffered reader that cuts the byte stream into backend messages without copying them.
//!
//! One `read()` usually delivers many messages; [`FrameReader::try_next`] hands them out one by one as
//! `(tag, range)` pairs into the internal buffer, and the buffer is only touched again by the next [`fill`]. The
//! buffer starts at 64 KiB and grows when one message is bigger (a 2 MB DataRow), then shrinks back once idle.
//!
//! [`fill`]: FrameReader::fill

use std::io::{self, Read};
use std::ops::Range;

use super::error::PgError;

/// Initial (and steady-state) buffer size.
const INITIAL_CAPACITY: usize = 64 * 1024;
/// A buffer this big or bigger is shrunk back to the initial size whenever it is empty.
const SHRINK_ABOVE: usize = 8 * 1024 * 1024;
/// Free space below which already-buffered bytes are moved to the front, so one `read()` stays worthwhile.
const MIN_READ_SPACE: usize = 16 * 1024;
/// Tag byte plus the 4-byte length field.
const HEADER_LEN: usize = 5;
/// Largest message accepted. Postgres caps a message at 1 GiB; anything bigger is a corrupt stream.
const MAX_MESSAGE_LEN: usize = 1 << 30;

pub(super) struct FrameReader {
    /// Always fully initialised (`len == capacity in use`); `start..end` holds unread bytes.
    buf: Vec<u8>,
    start: usize,
    end: usize,
}

impl FrameReader {
    pub fn new() -> Self {
        FrameReader {
            buf: vec![0; INITIAL_CAPACITY],
            start: 0,
            end: 0,
        }
    }

    /// Total size (header included) of the first buffered message, if its header is complete.
    fn peek_frame_len(&self) -> Result<Option<usize>, PgError> {
        let Some(header) = self.buf[self.start..self.end].first_chunk::<HEADER_LEN>() else {
            return Ok(None);
        };
        let len = i32::from_be_bytes([header[1], header[2], header[3], header[4]]);
        // The length field counts itself, so the smallest legal value is 4.
        match usize::try_from(len) {
            Ok(n) if (4..=MAX_MESSAGE_LEN).contains(&n) => Ok(Some(1 + n)),
            _ => Err(PgError::protocol(format!("invalid message length {len}"))),
        }
    }

    /// Consumes the next complete message from the buffer, if there is one.
    ///
    /// The range stays valid (via [`payload`](Self::payload)) until the next call to [`fill`](Self::fill).
    pub fn try_next(&mut self) -> Result<Option<(u8, Range<usize>)>, PgError> {
        let Some(total) = self.peek_frame_len()? else {
            return Ok(None);
        };
        if self.end - self.start < total {
            return Ok(None);
        }
        let tag = self.buf[self.start];
        let payload = self.start + HEADER_LEN..self.start + total;
        self.start += total;
        Ok(Some((tag, payload)))
    }

    pub fn payload(&self, range: Range<usize>) -> &[u8] {
        &self.buf[range]
    }

    /// Blocks until one complete message is available and returns it.
    pub fn next_message<R: Read>(&mut self, src: &mut R) -> Result<(u8, &[u8]), PgError> {
        loop {
            if let Some((tag, range)) = self.try_next()? {
                return Ok((tag, &self.buf[range]));
            }
            self.fill(src)?;
        }
    }

    /// Makes room (compacting or growing as needed) and performs one `read()`. Returns the bytes read; EOF is an
    /// `UnexpectedEof` error. On a non-blocking source `WouldBlock` is returned untouched.
    pub fn fill<R: Read>(&mut self, src: &mut R) -> io::Result<usize> {
        self.make_room()?;
        loop {
            match src.read(&mut self.buf[self.end..]) {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(n) => {
                    self.end += n;
                    return Ok(n);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }

    fn make_room(&mut self) -> io::Result<()> {
        if self.start == self.end {
            self.start = 0;
            self.end = 0;
            if self.buf.len() >= SHRINK_ABOVE {
                self.buf = vec![0; INITIAL_CAPACITY];
            }
        }
        // Size the buffer needs to hold the message being received (its header may not be complete yet).
        let needed = match self.peek_frame_len() {
            Ok(Some(total)) => total,
            Ok(None) => HEADER_LEN,
            Err(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid message length",
                ));
            }
        };
        let cramped = self.start > 0 && self.buf.len() - self.end < MIN_READ_SPACE;
        if self.start + needed > self.buf.len() || cramped {
            self.buf.copy_within(self.start..self.end, 0);
            self.end -= self.start;
            self.start = 0;
        }
        if needed > self.buf.len() {
            self.buf.resize(needed, 0);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(tag: u8, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![tag];
        v.extend_from_slice(&((payload.len() + 4) as i32).to_be_bytes());
        v.extend_from_slice(payload);
        v
    }

    /// A reader that returns its data in fixed-size pieces, like a socket delivering partial segments.
    struct Chunked<'a>(&'a [u8], usize);

    impl Read for Chunked<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = self.0.len().min(self.1).min(buf.len());
            buf[..n].copy_from_slice(&self.0[..n]);
            self.0 = &self.0[n..];
            Ok(n)
        }
    }

    #[test]
    fn many_messages_from_one_read() {
        let mut data = msg(b'1', b"");
        data.extend(msg(b'D', b"abc"));
        let mut src = Chunked(&data, usize::MAX);
        let mut r = FrameReader::new();
        let (t, p) = r.next_message(&mut src).unwrap();
        assert_eq!((t, p), (b'1', &b""[..]));
        // The second message is already buffered: no read needed (the source is drained).
        let (t, p) = r.next_message(&mut src).unwrap();
        assert_eq!((t, p), (b'D', &b"abc"[..]));
    }

    #[test]
    fn byte_by_byte_delivery() {
        let data = msg(b'D', b"hello world");
        let mut src = Chunked(&data, 1);
        let mut r = FrameReader::new();
        let (t, p) = r.next_message(&mut src).unwrap();
        assert_eq!((t, p), (b'D', &b"hello world"[..]));
    }

    #[test]
    fn message_larger_than_the_buffer() {
        let big = vec![7u8; INITIAL_CAPACITY * 3 + 11];
        let mut data = msg(b'D', &big);
        data.extend(msg(b'C', b"x"));
        let mut src = Chunked(&data, 10_000);
        let mut r = FrameReader::new();
        let (t, p) = r.next_message(&mut src).unwrap();
        assert_eq!((t, p.len()), (b'D', big.len()));
        assert!(p.iter().all(|&b| b == 7));
        let (t, p) = r.next_message(&mut src).unwrap();
        assert_eq!((t, p), (b'C', &b"x"[..]));
    }

    #[test]
    fn partial_tail_is_kept_when_compacting() {
        // Fill the buffer so the second message straddles the end and has to be moved to the front.
        let first = vec![1u8; INITIAL_CAPACITY - 20];
        let mut data = msg(b'D', &first);
        data.extend(msg(b'D', &[2u8; 100]));
        let mut src = Chunked(&data, usize::MAX);
        let mut r = FrameReader::new();
        assert_eq!(r.next_message(&mut src).unwrap().1.len(), first.len());
        let (_, p) = r.next_message(&mut src).unwrap();
        assert_eq!(p, &[2u8; 100][..]);
    }

    #[test]
    fn eof_and_bad_length() {
        let mut r = FrameReader::new();
        let err = r.next_message(&mut Chunked(b"D\0\0", 8)).unwrap_err();
        assert!(matches!(err, PgError::Io(e) if e.kind() == io::ErrorKind::UnexpectedEof));
        let mut r = FrameReader::new();
        let err = r.next_message(&mut Chunked(b"D\0\0\0\x02", 8)).unwrap_err();
        assert!(matches!(err, PgError::Protocol(_)));
    }

    #[test]
    fn huge_buffer_shrinks_when_idle() {
        let big = vec![0u8; SHRINK_ABOVE + 1];
        let mut data = msg(b'D', &big);
        data.extend(msg(b'C', b""));
        let mut src = Chunked(&data, usize::MAX);
        let mut r = FrameReader::new();
        r.next_message(&mut src).unwrap();
        assert!(r.buf.len() > SHRINK_ABOVE);
        r.next_message(&mut src).unwrap();
        let _ = r.fill(&mut src); // empty source: EOF, but make_room already ran
        assert_eq!(r.buf.len(), INITIAL_CAPACITY);
    }
}
