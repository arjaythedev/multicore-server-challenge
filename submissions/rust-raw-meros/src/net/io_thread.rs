//! The io thread: one epoll loop that owns a listener and the connections accepted on it.
//!
//! Flow of a request: readable event -> read into a pooled buffer -> `App::handle` parses and routes -> either an
//! immediate response (written from the shared `ResponseBuf`) or a job (the buffer moves into it). Flow of a job's
//! answer: the lane posts a `Reply` to this thread's mailbox, the eventfd wakes the loop, the response is written.
//!
//! Edge-triggered epoll: each readable event reads until the socket is drained. A connection holds no buffer while
//! it is idle.

use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;

use super::conn::{Phase, Slab};
use super::{ConnId, Mailboxes, Reply, Step};
use crate::app::App;
use crate::http::ResponseBuf;
use crate::pool::POOL;
use crate::sys::{self, EPOLLET, EPOLLIN, EPOLLOUT, EPOLLRDHUP, Epoll, Event, Io};

/// epoll tokens: connection slots are small integers, the two special descriptors take the top values.
const LISTENER_TOKEN: u64 = u64::MAX;
const WAKE_TOKEN: u64 = u64::MAX - 1;
const EVENTS_PER_WAIT: usize = 1024;
const READ_INTEREST: u32 = EPOLLIN | EPOLLRDHUP | EPOLLET;
const WRITE_INTEREST: u32 = READ_INTEREST | EPOLLOUT;
/// A read that fills less than this fraction of the buffer's spare room has drained the socket.
const MIN_SPARE_TO_READ: usize = 1024;

pub struct IoThread {
    index: u16,
    epoll: Epoll,
    listener: OwnedFd,
    mailboxes: Mailboxes,
    app: Arc<App>,
    slab: Slab,
    /// Reused for every response that is written straight from this thread.
    response: ResponseBuf,
    events: Vec<Event>,
    replies: Vec<Reply>,
}

impl IoThread {
    pub fn new(
        index: u16,
        listener: OwnedFd,
        mailboxes: Mailboxes,
        app: Arc<App>,
    ) -> io::Result<IoThread> {
        let epoll = Epoll::new(EVENTS_PER_WAIT)?;
        epoll.add(listener.as_raw_fd(), EPOLLIN | EPOLLET, LISTENER_TOKEN)?;
        epoll.add(
            mailboxes.get(index as usize).wake_fd(),
            EPOLLIN | EPOLLET,
            WAKE_TOKEN,
        )?;
        Ok(IoThread {
            index,
            epoll,
            listener,
            mailboxes,
            app,
            slab: Slab::new(),
            response: ResponseBuf::new(),
            events: Vec::with_capacity(EVENTS_PER_WAIT),
            replies: Vec::new(),
        })
    }

    /// Runs until an unrecoverable epoll error.
    pub fn run(mut self) -> io::Result<()> {
        loop {
            self.epoll.wait(-1, &mut self.events)?;
            for i in 0..self.events.len() {
                let Event { token, bits } = self.events[i];
                match token {
                    LISTENER_TOKEN => self.accept_all(),
                    WAKE_TOKEN => self.deliver_replies(),
                    slot => self.on_connection_event(slot as u32, bits),
                }
            }
        }
    }

    fn accept_all(&mut self) {
        loop {
            match sys::accept(self.listener.as_raw_fd()) {
                Ok(Some(socket)) => {
                    let fd = socket.as_raw_fd();
                    let slot = self.slab.insert(socket);
                    if self.epoll.add(fd, READ_INTEREST, slot as u64).is_err() {
                        self.slab.remove(slot);
                        continue;
                    }
                    if let Some(conn) = self.slab.get_mut(slot) {
                        conn.interest = READ_INTEREST;
                    }
                }
                Ok(None) => return,
                Err(err) => {
                    // Out of descriptors or memory: stop accepting for now; the next edge retries.
                    eprintln!("accept: {err}");
                    return;
                }
            }
        }
    }

    fn on_connection_event(&mut self, slot: u32, bits: u32) {
        if bits & (EPOLLIN | EPOLLRDHUP | sys::EPOLLERR | sys::EPOLLHUP) != 0 {
            self.read_ready(slot);
        }
        if bits & EPOLLOUT != 0 {
            self.write_ready(slot);
        }
    }

    // ----- reading ---------------------------------------------------------------------------------------------

    fn read_ready(&mut self, slot: u32) {
        loop {
            let Some(conn) = self.slab.get_mut(slot) else {
                return;
            };
            let Some(fd) = conn.fd() else { return };
            let mut buf = std::mem::take(&mut conn.input);
            if buf.capacity() == 0 {
                buf = POOL.get();
            } else if buf.capacity() - buf.len() < MIN_SPARE_TO_READ {
                buf.reserve(crate::pool::DEFAULT_CAPACITY);
            }
            let room = buf.capacity() - buf.len();
            match sys::read_into_vec(fd, &mut buf) {
                Ok(Io::Done(n)) => {
                    let phase = self.slab.get_mut(slot).map(|c| c.phase);
                    if phase == Some(Phase::Reading) {
                        self.process(slot, buf);
                    } else if let Some(conn) = self.slab.get_mut(slot) {
                        conn.input = buf; // a request is in flight: keep the bytes for later
                    }
                    if n < room {
                        return; // short read: drained
                    }
                }
                Ok(Io::WouldBlock) => {
                    self.keep_or_recycle(slot, buf);
                    return;
                }
                Ok(Io::Eof) | Err(_) => {
                    POOL.put(buf);
                    self.close(slot);
                    return;
                }
            }
        }
    }

    /// Parses and answers requests from `buf` until it holds no complete request.
    fn process(&mut self, slot: u32, mut buf: Vec<u8>) {
        loop {
            let Some(generation) = self.slab.get_mut(slot).map(|c| c.generation) else {
                POOL.put(buf);
                return;
            };
            let id = ConnId {
                io: self.index,
                slot,
                generation,
            };
            match self.app.handle(buf, id, &mut self.response) {
                Step::NeedMore(buf) => {
                    self.keep_or_recycle(slot, buf);
                    return;
                }
                Step::Answered {
                    buf: mut rest,
                    consumed,
                    start,
                    keep_alive,
                } => {
                    let more = consumed < rest.len();
                    let still_open = self.send_response(slot, start, !keep_alive);
                    if !still_open || !more || self.phase_of(slot) != Some(Phase::Reading) {
                        // Either the connection is gone, or the pipelined bytes wait for the response to drain.
                        if still_open && more {
                            rest.drain(..consumed);
                            self.keep_or_recycle(slot, rest);
                        } else {
                            POOL.put(rest);
                        }
                        return;
                    }
                    rest.drain(..consumed);
                    buf = rest;
                }
                Step::Queued { rest } => {
                    if let Some(conn) = self.slab.get_mut(slot) {
                        conn.phase = Phase::Waiting;
                        conn.input = rest;
                    }
                    return;
                }
                Step::Failed { buf, start } => {
                    POOL.put(buf);
                    self.send_response(slot, start, true);
                    return;
                }
            }
        }
    }

    fn phase_of(&mut self, slot: u32) -> Option<Phase> {
        self.slab.get_mut(slot).map(|c| c.phase)
    }

    /// Stores unconsumed bytes on the connection, or recycles the buffer when there are none.
    fn keep_or_recycle(&mut self, slot: u32, buf: Vec<u8>) {
        match self.slab.get_mut(slot) {
            Some(conn) if !buf.is_empty() => conn.input = buf,
            _ => POOL.put(buf),
        }
    }

    // ----- writing ---------------------------------------------------------------------------------------------

    /// Writes the shared response buffer from `start`. Returns false when the connection was closed.
    fn send_response(&mut self, slot: u32, start: usize, close: bool) -> bool {
        let bytes = self.response.bytes_from(start);
        let Some(conn) = self.slab.get_mut(slot) else {
            return false;
        };
        match Self::write_all_or_park(&self.epoll, conn, slot, bytes, close) {
            WriteOutcome::Finished => true,
            WriteOutcome::Parked => true,
            WriteOutcome::Closed => {
                self.slab.remove(slot);
                false
            }
        }
    }

    /// Writes as much as the socket takes; parks the rest on the connection with `EPOLLOUT` interest.
    fn write_all_or_park(
        epoll: &Epoll,
        conn: &mut super::conn::Conn,
        slot: u32,
        bytes: &[u8],
        close: bool,
    ) -> WriteOutcome {
        let Some(fd) = conn.fd() else {
            return WriteOutcome::Closed;
        };
        let mut written = 0;
        while written < bytes.len() {
            match sys::write_nonblocking(fd, &bytes[written..]) {
                Ok(Io::Done(n)) => written += n,
                Ok(Io::WouldBlock) => break,
                Ok(Io::Eof) | Err(_) => return WriteOutcome::Closed,
            }
        }
        if written == bytes.len() {
            return if close {
                WriteOutcome::Closed
            } else {
                WriteOutcome::Finished
            };
        }
        // The socket is full: keep the rest (a copy, but only for big responses to slow readers).
        conn.output.clear();
        conn.output.extend_from_slice(&bytes[written..]);
        conn.output_offset = 0;
        conn.close_after_write = close;
        conn.phase = Phase::Writing;
        if conn.interest != WRITE_INTEREST && epoll.modify(fd, WRITE_INTEREST, slot as u64).is_ok()
        {
            conn.interest = WRITE_INTEREST;
        }
        WriteOutcome::Parked
    }

    fn write_ready(&mut self, slot: u32) {
        let Some(conn) = self.slab.get_mut(slot) else {
            return;
        };
        if conn.phase != Phase::Writing {
            return;
        }
        let Some(fd) = conn.fd() else { return };
        while conn.output_offset < conn.output.len() {
            match sys::write_nonblocking(fd, &conn.output[conn.output_offset..]) {
                Ok(Io::Done(n)) => conn.output_offset += n,
                Ok(Io::WouldBlock) => return,
                Ok(Io::Eof) | Err(_) => {
                    self.slab.remove(slot);
                    return;
                }
            }
        }
        conn.output = Vec::new();
        conn.output_offset = 0;
        if conn.close_after_write {
            self.slab.remove(slot);
            return;
        }
        conn.phase = Phase::Reading;
        if self.epoll.modify(fd, READ_INTEREST, slot as u64).is_ok() {
            conn.interest = READ_INTEREST;
        }
        self.resume_buffered_input(slot);
    }

    // ----- replies from lanes ------------------------------------------------------------------------------------

    fn deliver_replies(&mut self) {
        let mut replies = std::mem::take(&mut self.replies);
        self.mailboxes
            .get(self.index as usize)
            .take_all(&mut replies);
        let mut spent = Vec::with_capacity(replies.len());
        for reply in replies.drain(..) {
            self.deliver(reply, &mut spent);
        }
        POOL.put_all(&mut spent);
        self.replies = replies;
    }

    fn deliver(&mut self, reply: Reply, spent: &mut Vec<Vec<u8>>) {
        let slot = reply.conn.slot;
        let alive = self
            .slab
            .get_mut(slot)
            .is_some_and(|c| c.generation == reply.conn.generation && c.phase == Phase::Waiting);
        if alive && let Some(conn) = self.slab.get_mut(slot) {
            let bytes = &reply.bytes[reply.start..];
            match Self::write_all_or_park(&self.epoll, conn, slot, bytes, reply.close) {
                WriteOutcome::Finished => {
                    conn.phase = Phase::Reading;
                    self.resume_buffered_input(slot);
                }
                WriteOutcome::Parked => {}
                WriteOutcome::Closed => self.slab.remove(slot),
            }
        }
        spent.push(reply.bytes);
    }

    /// After a response left, handle request bytes that arrived while the connection was busy.
    fn resume_buffered_input(&mut self, slot: u32) {
        let Some(conn) = self.slab.get_mut(slot) else {
            return;
        };
        if conn.phase != Phase::Reading || conn.input.is_empty() {
            return;
        }
        let buf = std::mem::take(&mut conn.input);
        self.process(slot, buf);
    }

    fn close(&mut self, slot: u32) {
        if let Some(conn) = self.slab.get_mut(slot) {
            POOL.put(std::mem::take(&mut conn.input));
        }
        self.slab.remove(slot);
    }
}

enum WriteOutcome {
    /// Everything was written; the connection stays open.
    Finished,
    /// The socket is full; the rest waits for `EPOLLOUT`.
    Parked,
    /// Written (with close requested) or failed: close the connection.
    Closed,
}
