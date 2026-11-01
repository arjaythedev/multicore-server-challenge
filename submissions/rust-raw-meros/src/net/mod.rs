//! Network side: the io threads that own sockets, parse HTTP and hand finished responses back to clients.
//!
//! An io thread never blocks and never touches the database. A request that needs Postgres becomes a job for a
//! lane thread; the lane renders the response and posts a [`Reply`] to the owning thread's [`Mailbox`].

mod conn;
mod io_thread;
mod mailbox;

pub use io_thread::IoThread;
pub use mailbox::{Mailbox, Mailboxes};

/// Names one client connection across threads. The generation makes a reply to a connection that closed (and whose
/// slot was reused) harmless: it no longer matches and is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnId {
    /// Index of the io thread that owns the socket.
    pub io: u16,
    /// Slot in that thread's connection table.
    pub slot: u32,
    /// How often the slot has been reused.
    pub generation: u32,
}

/// A finished HTTP response on its way to the socket.
pub struct Reply {
    pub conn: ConnId,
    /// Response bytes start at `start`; the bytes before it are unused header space (see `http::ResponseBuf`).
    pub bytes: Vec<u8>,
    pub start: usize,
    /// Close the connection after the response is written.
    pub close: bool,
}

/// What the application did with the bytes an io thread read for one connection.
pub enum Step {
    /// Not a complete request yet. Nothing was consumed; the buffer comes back so the io thread can append to it.
    NeedMore(Vec<u8>),
    /// Answered at once: the response is in the io thread's `ResponseBuf` from `start`. `consumed` bytes of the buffer
    /// were the request; the rest (a pipelined request) stays in the buffer for the next round.
    Answered {
        buf: Vec<u8>,
        consumed: usize,
        start: usize,
        keep_alive: bool,
    },
    /// The request became a job and the buffer moved into it (zero-copy). `rest` holds any bytes that followed the
    /// request (almost always empty and allocation-free). A [`Reply`] arrives later.
    Queued { rest: Vec<u8> },
    /// The bytes are not HTTP we serve. The response (an error) is in the `ResponseBuf` from `start`; the connection
    /// closes after it.
    Failed { buf: Vec<u8>, start: usize },
}
