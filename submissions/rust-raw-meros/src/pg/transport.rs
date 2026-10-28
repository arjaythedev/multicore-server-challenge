//! The socket plus its two buffers: what is written (`out`) and how replies are cut into messages.
//!
//! The one non-obvious piece is [`Transport::exchange`]. A pipeline can be bigger than the socket buffers; if we
//! blocked in `write()` while the server blocked writing results we are not reading, both sides would wait
//! forever. Small requests take the plain path (one blocking `write_all`, then read). Requests above
//! [`INTERLEAVE_ABOVE`] are written non-blockingly while replies are drained between the writes.

use std::io::{self, Write};
use std::net::TcpStream;
use std::thread;
use std::time::Duration;

use super::error::PgError;
use super::frame::FrameReader;

/// Requests up to this size are written with one blocking call: the kernel buffers them without help.
const INTERLEAVE_ABOVE: usize = 16 * 1024;
/// An `out` buffer that grew beyond this is released after use instead of being kept for the connection's life.
const OUT_SHRINK_ABOVE: usize = 4 * 1024 * 1024;
const OUT_INITIAL_CAPACITY: usize = 16 * 1024;
/// Idle rounds (nothing written, nothing read) spent yielding before sleeping.
const IDLE_YIELDS: u32 = 16;
const IDLE_SLEEP: Duration = Duration::from_micros(50);

/// What a message handler tells [`Transport::exchange`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Flow {
    Continue,
    /// The final message (ReadyForQuery) was seen.
    Done,
}

pub(super) struct Transport {
    stream: TcpStream,
    reader: FrameReader,
    /// Outgoing messages, appended by the encoders and sent by [`exchange`](Self::exchange) / [`write_out`](Self::write_out).
    pub out: Vec<u8>,
}

impl Transport {
    pub fn new(stream: TcpStream) -> Self {
        Transport {
            stream,
            reader: FrameReader::new(),
            out: Vec::with_capacity(OUT_INITIAL_CAPACITY),
        }
    }

    /// Sends everything in `out` with blocking writes (handshake only; requests there are tiny).
    pub fn write_out(&mut self) -> Result<(), PgError> {
        let result = self.stream.write_all(&self.out);
        self.release_out();
        Ok(result?)
    }

    /// Blocks for the next backend message.
    pub fn read_message(&mut self) -> Result<(u8, &[u8]), PgError> {
        self.reader.next_message(&mut self.stream)
    }

    /// Sends `out`, then feeds every backend message to `on_message` until it returns [`Flow::Done`].
    pub fn exchange<F>(&mut self, mut on_message: F) -> Result<(), PgError>
    where
        F: FnMut(u8, &[u8]) -> Result<Flow, PgError>,
    {
        let result = if self.out.len() > INTERLEAVE_ABOVE {
            self.write_interleaved(&mut on_message)
                .and_then(|()| self.read_until_done(&mut on_message))
        } else {
            self.stream
                .write_all(&self.out)
                .map_err(PgError::from)
                .and_then(|()| self.read_until_done(&mut on_message))
        };
        self.release_out();
        result
    }

    fn read_until_done<F>(&mut self, on_message: &mut F) -> Result<(), PgError>
    where
        F: FnMut(u8, &[u8]) -> Result<Flow, PgError>,
    {
        loop {
            while let Some((tag, range)) = self.reader.try_next()? {
                if on_message(tag, self.reader.payload(range))? == Flow::Done {
                    return Ok(());
                }
            }
            self.reader.fill(&mut self.stream)?;
        }
    }

    /// Writes all of `out` without blocking, draining replies whenever the socket will not take more.
    fn write_interleaved<F>(&mut self, on_message: &mut F) -> Result<(), PgError>
    where
        F: FnMut(u8, &[u8]) -> Result<Flow, PgError>,
    {
        self.stream.set_nonblocking(true)?;
        let result = self.interleave_loop(on_message);
        // Restore blocking mode even on failure; the connection is poisoned then anyway.
        let restored = self.stream.set_nonblocking(false);
        result?;
        Ok(restored?)
    }

    fn interleave_loop<F>(&mut self, on_message: &mut F) -> Result<(), PgError>
    where
        F: FnMut(u8, &[u8]) -> Result<Flow, PgError>,
    {
        let mut sent = 0;
        let mut idle_rounds = 0u32;
        while sent < self.out.len() {
            let mut progressed = false;
            match self.stream.write(&self.out[sent..]) {
                Ok(0) => return Err(io::Error::from(io::ErrorKind::WriteZero).into()),
                Ok(n) => {
                    sent += n;
                    progressed = true;
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(e) => return Err(e.into()),
            }
            loop {
                while let Some((tag, range)) = self.reader.try_next()? {
                    if on_message(tag, self.reader.payload(range))? == Flow::Done {
                        return Err(PgError::protocol(
                            "reply completed before the request was fully sent",
                        ));
                    }
                }
                match self.reader.fill(&mut self.stream) {
                    Ok(_) => progressed = true,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e.into()),
                }
            }
            if progressed {
                idle_rounds = 0;
            } else {
                idle_rounds += 1;
                if idle_rounds <= IDLE_YIELDS {
                    thread::yield_now();
                } else {
                    thread::sleep(IDLE_SLEEP);
                }
            }
        }
        Ok(())
    }

    fn release_out(&mut self) {
        self.out.clear();
        if self.out.capacity() > OUT_SHRINK_ABOVE {
            self.out = Vec::with_capacity(OUT_INITIAL_CAPACITY);
        }
    }
}
