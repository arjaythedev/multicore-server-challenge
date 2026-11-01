//! One client connection's state. Kept small (under 100 bytes) because a benchmark run holds well over 100,000 of
//! them. An idle connection owns no buffer at all: request bytes are read into a per-thread scratch buffer and only
//! the unparsed rest of a partial request is copied here.

use std::os::fd::{AsRawFd, OwnedFd, RawFd};

/// What a connection is waiting for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    /// Waiting for (more of) a request.
    Reading,
    /// A request went to a lane; its reply is pending. Input that arrives meanwhile is buffered.
    Waiting,
    /// A response is only partly written; wait for the socket to drain before the next request.
    Writing,
}

pub struct Conn {
    pub socket: Option<OwnedFd>,
    /// Incremented every time the slot is reused.
    pub generation: u32,
    pub phase: Phase,
    /// Bytes read but not yet consumed by a parsed request (a partial request, or pipelined requests).
    pub input: Vec<u8>,
    /// The unwritten rest of a response (`Phase::Writing`).
    pub output: Vec<u8>,
    pub output_offset: usize,
    /// Close once `output` is written.
    pub close_after_write: bool,
    /// The epoll interest currently registered (to avoid redundant `epoll_ctl` calls).
    pub interest: u32,
}

impl Conn {
    pub const fn vacant() -> Conn {
        Conn {
            socket: None,
            generation: 0,
            phase: Phase::Reading,
            input: Vec::new(),
            output: Vec::new(),
            output_offset: 0,
            close_after_write: false,
            interest: 0,
        }
    }

    pub fn fd(&self) -> Option<RawFd> {
        self.socket.as_ref().map(AsRawFd::as_raw_fd)
    }

    /// Frees the socket and buffers; the slot can be reused with a new generation.
    pub fn reset(&mut self) {
        self.socket = None; // dropping the OwnedFd closes the descriptor and removes it from epoll
        self.generation = self.generation.wrapping_add(1);
        self.phase = Phase::Reading;
        self.input = Vec::new();
        self.output = Vec::new();
        self.output_offset = 0;
        self.close_after_write = false;
        self.interest = 0;
    }
}

/// Connection table: slots addressed by index, with a free list.
pub struct Slab {
    conns: Vec<Conn>,
    free: Vec<u32>,
}

impl Slab {
    pub fn new() -> Slab {
        Slab {
            conns: Vec::new(),
            free: Vec::new(),
        }
    }

    /// Stores a new connection and returns its slot.
    pub fn insert(&mut self, socket: OwnedFd) -> u32 {
        let slot = match self.free.pop() {
            Some(slot) => slot,
            None => {
                self.conns.push(Conn::vacant());
                (self.conns.len() - 1) as u32
            }
        };
        let conn = &mut self.conns[slot as usize];
        conn.socket = Some(socket);
        conn.phase = Phase::Reading;
        slot
    }

    pub fn get_mut(&mut self, slot: u32) -> Option<&mut Conn> {
        self.conns
            .get_mut(slot as usize)
            .filter(|c| c.socket.is_some())
    }

    /// Closes the connection and recycles the slot.
    pub fn remove(&mut self, slot: u32) {
        if let Some(conn) = self.conns.get_mut(slot as usize)
            && conn.socket.is_some()
        {
            conn.reset();
            self.free.push(slot);
        }
    }
}
