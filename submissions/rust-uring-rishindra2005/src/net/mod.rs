//! Network reactor layer: high-performance io_uring with Direct Descriptors,
//! provided buffer rings, and epoll fallback.

pub mod uring;
pub mod pbuf;
pub mod conn;
pub mod http;
pub mod send;
pub mod epoll;

use std::collections::VecDeque;
use std::os::unix::io::RawFd;
use std::sync::Arc;

use crate::net::conn::ConnTable;
use crate::net::http::{parse_http_request, HttpMethod, ParseResult};
use crate::net::pbuf::ProvidedBufferRing;
use crate::net::conn::GEN_MASK;
use crate::net::send::{OutgoingQueue, SendOutcome};
use crate::net::uring::*;
use crate::rt::spsc::SpscQueue;
use crate::types::{ConnRef, Envelope, KdfJob, Reply};

pub const BGID_READ: u16 = 1;
pub const PBUF_ENTRIES: u32 = 32768;
pub const PBUF_SIZE: usize = 2048;

pub const TOKEN_ACCEPT: u64 = 0xACCED7;
pub const TOKEN_CLOSE: u64 = 0xC105ED;
pub const TOKEN_WAKEUP: u64 = 0x11A4E;
pub const TAG_RECV: u64 = 1;
pub const TAG_SEND: u64 = 2;

/// user_data = slot (bits 32..64) | low 24 bits of the slot generation (bits 8..32) | tag (bits 0..8).
/// The generation lets the reactor drop CQEs of a connection that was closed and whose slot was reused.
#[inline(always)]
pub fn make_user_data(tag: u64, slot_idx: u32, gen: u32) -> u64 {
    (tag & 0xFF) | (((gen & GEN_MASK) as u64) << 8) | ((slot_idx as u64) << 32)
}

/// Returns (tag, slot_idx, gen24).
#[inline(always)]
pub fn unpack_user_data(ud: u64) -> (u64, u32, u32) {
    (ud & 0xFF, (ud >> 32) as u32, ((ud >> 8) as u32) & GEN_MASK)
}

#[inline(always)]
fn send_ud(slot_idx: u32, gen: u32) -> u64 {
    make_user_data(TAG_SEND, slot_idx, gen)
}

pub fn create_reuseport_listener(port: u16) -> std::io::Result<RawFd> {
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }

        let yes: libc::c_int = 1;
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, &yes as *const _ as *const libc::c_void, 4);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEPORT, &yes as *const _ as *const libc::c_void, 4);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &yes as *const _ as *const libc::c_void, 4);

        let mut sa: libc::sockaddr_in = std::mem::zeroed();
        sa.sin_family = libc::AF_INET as u16;
        sa.sin_port = port.to_be();
        sa.sin_addr.s_addr = libc::INADDR_ANY.to_be();

        if libc::bind(fd, &sa as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32) < 0 {
            libc::close(fd);
            return Err(std::io::Error::last_os_error());
        }

        if libc::listen(fd, 65535) < 0 {
            libc::close(fd);
            return Err(std::io::Error::last_os_error());
        }

        Ok(fd)
    }
}

pub struct UringReactor {
    pub reactor_id: u8,
    pub ring: IoUringInstance,
    pub pbr: ProvidedBufferRing,
    pub listen_fd: RawFd,
    pub wake_fd: RawFd,
    pub wake_buf: Box<u64>,
    pub wake_inflight: bool,
    pub conn_table: ConnTable,
    pub outgoing: OutgoingQueue,
    pub overflow_pg: Vec<VecDeque<Envelope>>,
    pub overflow_kdf: VecDeque<KdfJob>,
    pub kdf_rr: usize,
    /// (slot, gen24) whose multishot recv ended with ENOBUFS; re-armed when buffers are back.
    pub starved_recvs: Vec<(u32, u32)>,
    pub pg_queues: Vec<Arc<SpscQueue<Envelope, 1024>>>,
    pub kdf_queues: Vec<Arc<SpscQueue<KdfJob, 512>>>,
}

impl UringReactor {
    pub fn new(
        reactor_id: u8,
        listen_fd: RawFd,
        direct_table_sz: u32,
        wake_fd: RawFd,
    ) -> Result<Self, i32> {
        let ring = IoUringInstance::new(4096, 16384)?;

        // Register sparse file table for Direct Descriptors (bypasses process LimitNOFILE!)
        if direct_table_sz > 0 {
            let _ = ring.register_sparse_files(direct_table_sz);
        }

        // Register provided buffer ring for zero-buffer-overhead keep-alive sockets
        let pbr = ProvidedBufferRing::new(ring.fd, BGID_READ, PBUF_ENTRIES, PBUF_SIZE)?;

        let mut reactor = Self {
            reactor_id,
            ring,
            pbr,
            listen_fd,
            wake_fd,
            wake_buf: Box::new(0u64),
            wake_inflight: false,
            conn_table: ConnTable::new(reactor_id, direct_table_sz as usize),
            outgoing: OutgoingQueue::new(),
            overflow_pg: Vec::new(),
            overflow_kdf: VecDeque::new(),
            kdf_rr: 0,
            starved_recvs: Vec::with_capacity(1024),
            pg_queues: Vec::new(),
            kdf_queues: Vec::new(),
        };

        reactor.arm_multishot_accept();
        if wake_fd >= 0 {
            reactor.arm_wakeup();
        }
        Ok(reactor)
    }

    #[inline(always)]
    pub fn has_overflow(&self) -> bool {
        !self.overflow_kdf.is_empty()
            || self.overflow_pg.iter().any(|q| !q.is_empty())
            || !self.starved_recvs.is_empty()
            || !self.outgoing.stalled.is_empty()
    }

    pub fn arm_wakeup(&mut self) -> bool {
        if self.wake_inflight || self.wake_fd < 0 {
            return false;
        }
        if let Some(sqe) = self.ring.get_sqe_flush() {
            sqe.opcode = IORING_OP_READ;
            sqe.fd = self.wake_fd;
            sqe.addr = self.wake_buf.as_mut() as *mut u64 as u64;
            sqe.len = 8;
            sqe.user_data = TOKEN_WAKEUP;
            self.wake_inflight = true;
            true
        } else {
            false
        }
    }

    pub fn rearm_starved(&mut self) {
        if self.starved_recvs.is_empty() {
            return;
        }
        let mut starved = std::mem::take(&mut self.starved_recvs);
        for (slot_idx, gen24) in starved.drain(..) {
            if self.conn_table.is_live(slot_idx, gen24) {
                if !self.arm_multishot_recv(slot_idx) {
                    self.starved_recvs.push((slot_idx, gen24));
                }
            }
        }
    }

    pub fn flush_overflow(
        &mut self,
        pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
        kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>],
    ) {
        if self.pg_queues.is_empty() {
            self.pg_queues = pg_queues.to_vec();
            self.kdf_queues = kdf_queues.to_vec();
        }
        if self.overflow_pg.len() < pg_queues.len() {
            self.overflow_pg.resize_with(pg_queues.len(), VecDeque::new);
        }
        for (q_idx, queue) in pg_queues.iter().enumerate() {
            let ov = &mut self.overflow_pg[q_idx];
            while let Some(env) = ov.pop_front() {
                if let Err(env) = queue.push(env) {
                    ov.push_front(env);
                    break;
                }
            }
        }
        if !kdf_queues.is_empty() {
            let num_kdf = kdf_queues.len();
            while let Some(kdf_job) = self.overflow_kdf.pop_front() {
                let mut job_slot = Some(kdf_job);
                for i in 0..num_kdf {
                    let idx = (self.kdf_rr + i) % num_kdf;
                    match kdf_queues[idx].push(job_slot.take().unwrap()) {
                        Ok(()) => {
                            self.kdf_rr = (idx + 1) % num_kdf;
                            break;
                        }
                        Err(returned_job) => {
                            job_slot = Some(returned_job);
                        }
                    }
                }
                if let Some(job) = job_slot {
                    self.overflow_kdf.push_front(job);
                    break;
                }
            }
        }
    }

    pub fn arm_multishot_accept(&mut self) {
        if let Some(sqe) = self.ring.get_sqe() {
            sqe.opcode = IORING_OP_ACCEPT;
            sqe.fd = self.listen_fd;
            sqe.file_index = IORING_FILE_INDEX_ALLOC; // Allocate direct fixed descriptor!
            sqe.ioprio = IORING_ACCEPT_MULTISHOT;
            sqe.op_flags = 0; // Direct descriptors must NOT pass SOCK_CLOEXEC (causes -EINVAL in kernel io_accept_prep)
            sqe.user_data = TOKEN_ACCEPT;
        }
    }

    pub fn arm_multishot_recv(&mut self, slot_idx: u32) -> bool {
        let (fixed_index, is_fixed, gen) = match self.conn_table.get_slot(slot_idx) {
            Some(s) => (s.fixed_index, s.is_fixed, s.gen),
            None => return true,
        };
        if let Some(sqe) = self.ring.get_sqe_flush() {
            sqe.opcode = IORING_OP_RECV;
            if is_fixed {
                sqe.fd = fixed_index as i32;
                sqe.flags = IOSQE_FIXED_FILE | IOSQE_BUFFER_SELECT;
            } else {
                sqe.fd = fixed_index as i32;
                sqe.flags = IOSQE_BUFFER_SELECT;
            }
            sqe.ioprio = IORING_RECV_MULTISHOT;
            sqe.buf_index = BGID_READ;
            sqe.user_data = make_user_data(TAG_RECV, slot_idx, gen);
            true
        } else {
            false
        }
    }

    pub fn handle_accept_cqe(&mut self, cqe: &io_uring_cqe) {
        if cqe.res < 0 {
            eprintln!(
                "[net-reactor-{}] accept cqe error res={} flags=0x{:x}",
                self.reactor_id, cqe.res, cqe.flags
            );
            if (cqe.flags & IORING_CQE_F_MORE) == 0 {
                // In case of error (e.g. EMFILE/ENFILE), back off briefly so we don't peg CPU in a 100% spin loop
                std::thread::sleep(std::time::Duration::from_millis(5));
                self.arm_multishot_accept();
            }
            return;
        }

        let fixed_index = cqe.res as u32;
        let is_fixed = true;

        // Allocate slot and generate generation-guarded ConnRef
        let (slot_idx, _) = self.conn_table.allocate(-1, fixed_index, is_fixed);

        // Arm multishot recv into provided buffer ring
        if !self.arm_multishot_recv(slot_idx) {
            let gen = self.conn_table.get_slot(slot_idx).map(|s| s.gen & GEN_MASK).unwrap_or(0);
            self.starved_recvs.push((slot_idx, gen));
        }

        if (cqe.flags & IORING_CQE_F_MORE) == 0 {
            self.arm_multishot_accept();
        }
    }

    pub fn handle_recv_cqe(
        &mut self,
        slot_idx: u32,
        gen24: u32,
        cqe: &io_uring_cqe,
        pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
        kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>],
    ) {
        if self.pg_queues.is_empty() {
            self.pg_queues = pg_queues.to_vec();
            self.kdf_queues = kdf_queues.to_vec();
        }
        if !self.conn_table.is_live(slot_idx, gen24) {
            // CQE of a connection that is closed/closing (its slot may already hold a new connection):
            // give the buffer back and touch nothing else.
            if cqe.res > 0 && (cqe.flags & IORING_CQE_F_BUFFER) != 0 {
                self.pbr.return_buf((cqe.flags >> 16) as u16);
            }
            return;
        }
        if cqe.res <= 0 {
            if cqe.res == -libc::ENOBUFS {
                // Buffer ring temporarily exhausted: do NOT close the connection!
                // Add to starved list to re-arm multishot recv once buffers are returned.
                self.starved_recvs.push((slot_idx, gen24));
                return;
            }
            self.close_slot(slot_idx);
            return;
        }

        let bytes_read = cqe.res as usize;
        let bid = (cqe.flags >> 16) as u16;
        let chunk = self.pbr.get_buffer(bid, bytes_read);

        let slot = match self.conn_table.get_slot_mut(slot_idx) {
            Some(s) if s.in_use => s,
            _ => {
                self.pbr.return_buf(bid);
                return;
            }
        };

        // Streaming request handling: append received chunk and immediately return ring buffer
        slot.partial_read.extend_from_slice(chunk);
        self.pbr.return_buf(bid);

        // If no request is currently in flight on this connection, parse and dispatch ONE request
        if !slot.in_flight {
            self.try_dispatch_next(slot_idx);
        }

        // Re-arm multishot recv if it completed
        if (cqe.flags & IORING_CQE_F_MORE) == 0 && self.conn_table.is_live(slot_idx, gen24) {
            if !self.arm_multishot_recv(slot_idx) {
                self.starved_recvs.push((slot_idx, gen24));
            }
        }
    }

    /// Parses and dispatches the next complete HTTP request from `slot.partial_read`.
    /// Sets `in_flight = true` upon dispatch. If a request is already in flight or
    /// partial_read is incomplete/empty, does nothing.
    pub fn try_dispatch_next(&mut self, slot_idx: u32) {
        let slot = match self.conn_table.slots.get_mut(slot_idx as usize) {
            Some(s) if s.in_use && !s.closing => s,
            _ => return,
        };

        if slot.in_flight || slot.partial_read.is_empty() {
            return;
        }

        let conn_ref = ConnRef {
            reactor: self.reactor_id,
            slot: slot_idx,
            gen: slot.gen,
        };

        match parse_http_request(&slot.partial_read) {
            ParseResult::Complete(req) => {
                let consumed = req.bytes_consumed;
                slot.in_flight = true;
                Self::dispatch_admitted_request(
                    &mut self.outgoing,
                    &mut self.overflow_pg,
                    &mut self.overflow_kdf,
                    &mut self.kdf_rr,
                    req,
                    conn_ref,
                    &self.pg_queues,
                    &self.kdf_queues,
                );
                let slot = &mut self.conn_table.slots[slot_idx as usize];
                slot.partial_read.drain(..consumed);
            }
            ParseResult::Incomplete => {
                // Incomplete request; wait for more data from kernel
            }
            ParseResult::Error => {
                slot.partial_read.clear();
                self.close_slot(slot_idx);
            }
        }
    }

    pub fn handle_send_cqe(&mut self, slot_idx: u32, gen24: u32, res: i32) {
        let outcome = self.outgoing.handle_send_completion(
            &mut self.ring,
            slot_idx,
            gen24,
            res,
            &mut self.conn_table,
            send_ud,
        );
        if outcome == SendOutcome::Close {
            self.close_slot(slot_idx);
        } else if self.conn_table.is_live(slot_idx, gen24) {
            let slot = &self.conn_table.slots[slot_idx as usize];
            if !slot.in_flight && !slot.partial_read.is_empty() {
                self.try_dispatch_next(slot_idx);
            }
        }
    }

    fn dispatch_admitted_request(
        outgoing: &mut OutgoingQueue,
        overflow_pg: &mut Vec<VecDeque<Envelope>>,
        overflow_kdf: &mut VecDeque<KdfJob>,
        kdf_rr: &mut usize,
        req: crate::net::http::HttpRequest<'_>,
        conn_ref: ConnRef,
        pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
        kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>],
    ) {
        let method_str = match req.method {
            HttpMethod::Get => "GET",
            HttpMethod::Post => "POST",
            HttpMethod::Put => "PUT",
            HttpMethod::Delete => "DELETE",
            _ => "OTHER",
        };

        let viewer = req.auth_token.and_then(crate::sec::jwt_verify);
        let admit_res = crate::api::parse_and_admit(
            method_str,
            req.path,
            req.body,
            viewer,
            req.auth_token,
            conn_ref,
            req.keepalive,
        );

        match admit_res {
            crate::api::admit::Admit::Reply(bytes) => {
                outgoing.enqueue(Reply {
                    conn: conn_ref,
                    bytes,
                    close: !req.keepalive,
                });
            }
            crate::api::admit::Admit::Pg(envelope) => {
                if !pg_queues.is_empty() {
                    let q_idx = (conn_ref.slot as usize) % pg_queues.len();
                    if overflow_pg.len() < pg_queues.len() {
                        overflow_pg.resize_with(pg_queues.len(), VecDeque::new);
                    }
                    let ov = &mut overflow_pg[q_idx];
                    if ov.is_empty() {
                        if let Err(env) = pg_queues[q_idx].push(envelope) {
                            ov.push_back(env);
                        }
                    } else {
                        ov.push_back(envelope);
                    }
                }
            }
            crate::api::admit::Admit::Kdf(kdf_job) => {
                if !kdf_queues.is_empty() {
                    let num_kdf = kdf_queues.len();
                    if overflow_kdf.is_empty() {
                        let mut job_slot = Some(kdf_job);
                        for i in 0..num_kdf {
                            let idx = (*kdf_rr + i) % num_kdf;
                            match kdf_queues[idx].push(job_slot.take().unwrap()) {
                                Ok(()) => {
                                    *kdf_rr = (idx + 1) % num_kdf;
                                    break;
                                }
                                Err(returned_job) => {
                                    job_slot = Some(returned_job);
                                }
                            }
                        }
                        if let Some(job) = job_slot {
                            overflow_kdf.push_back(job);
                        }
                    } else {
                        overflow_kdf.push_back(kdf_job);
                    }
                }
            }
        }
    }

    pub fn drain_replies(
        &mut self,
        reply_queues: &[Arc<SpscQueue<Reply, 1024>>],
        kdf_replies: &[Arc<SpscQueue<Reply, 512>>],
    ) {
        for q in reply_queues {
            while let Some(reply) = q.pop() {
                self.outgoing.enqueue(reply);
            }
        }
        for q in kdf_replies {
            while let Some(reply) = q.pop() {
                self.outgoing.enqueue(reply);
            }
        }
    }

    pub fn flush_outgoing_sends(&mut self) -> usize {
        let queued = self.outgoing.prepare_sends(&mut self.ring, &mut self.conn_table, send_ud);
        if queued > 0 {
            self.ring.flush_sq();
        }
        queued
    }

    /// Idempotent. Cancels the multishot recv (closing a direct descriptor does not cancel requests that
    /// hold it, so the socket would otherwise stay open), and defers the close while a send is in flight
    /// so the kernel never reads a freed buffer; the send CQE then finishes the close.
    pub fn close_slot(&mut self, slot_idx: u32) {
        let (gen, inflight) = match self.conn_table.get_slot_mut(slot_idx) {
            Some(s) if s.in_use => {
                if s.closing {
                    return; // already waiting for its send CQE
                }
                (s.gen, s.send_inflight)
            }
            _ => return,
        };
        if let Some(sqe) = self.ring.get_sqe_flush() {
            sqe.opcode = IORING_OP_ASYNC_CANCEL;
            sqe.fd = -1;
            sqe.addr = make_user_data(TAG_RECV, slot_idx, gen);
            sqe.user_data = TOKEN_CLOSE;
        }
        if inflight {
            if let Some(s) = self.conn_table.get_slot_mut(slot_idx) {
                s.closing = true;
            }
            return;
        }
        let (fd, fixed_index, is_fixed) = self.conn_table.release(slot_idx);
        if is_fixed {
            // Close fixed slot with IORING_OP_CLOSE
            if let Some(sqe) = self.ring.get_sqe_flush() {
                sqe.opcode = IORING_OP_CLOSE;
                sqe.fd = 0;
                sqe.file_index = fixed_index + 1; // 1-based fixed file slot
                sqe.user_data = TOKEN_CLOSE;
            }
        } else if fd >= 0 {
            unsafe { libc::close(fd) };
        }
    }
}

#[cfg(test)]
mod user_data_tests {
    use super::*;

    #[test]
    fn user_data_round_trips_and_never_collides_with_tokens() {
        for &(tag, slot, gen) in &[(TAG_RECV, 0u32, 0u32), (TAG_SEND, 189_999, 1), (TAG_RECV, u32::MAX, 0xFF_FFFF), (TAG_SEND, 7, 0x1_000_005)] {
            let ud = make_user_data(tag, slot, gen);
            assert_eq!(unpack_user_data(ud), (tag, slot, gen & GEN_MASK));
            assert_ne!(ud, TOKEN_ACCEPT);
            assert_ne!(ud, TOKEN_CLOSE);
            assert_ne!(ud, TOKEN_WAKEUP);
        }
        assert_ne!(TOKEN_WAKEUP, TOKEN_ACCEPT);
        assert_ne!(TOKEN_WAKEUP, TOKEN_CLOSE);
        // A reused slot (gen bumped) must not match the old connection's CQEs.
        assert_ne!(make_user_data(TAG_RECV, 5, 1), make_user_data(TAG_RECV, 5, 2));
    }

    #[test]
    fn test_pipelined_requests_in_flight_dispatch() {
        let dummy_efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        let pg_q: Arc<SpscQueue<Envelope, 1024>> = Arc::new(SpscQueue::new(dummy_efd));
        let pg_queues = vec![pg_q.clone()];
        let kdf_queues = Vec::new();

        let mut conn_table = ConnTable::new(0, 16);
        let (slot_idx, _) = conn_table.allocate(100, 0, false);
        let mut outgoing = OutgoingQueue::new();
        let mut overflow_pg = Vec::new();
        let mut overflow_kdf = VecDeque::new();
        let mut kdf_rr = 0;

        // 1. Prepare 3 complete GET requests back-to-back
        let req1 = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let req2 = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let req3 = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let mut input = Vec::new();
        input.extend_from_slice(req1);
        input.extend_from_slice(req2);
        input.extend_from_slice(req3);

        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.partial_read.extend_from_slice(&input);

        let dispatch_next = |conn_table: &mut ConnTable,
                                 outgoing: &mut OutgoingQueue,
                                 overflow_pg: &mut Vec<VecDeque<Envelope>>,
                                 overflow_kdf: &mut VecDeque<KdfJob>,
                                 kdf_rr: &mut usize,
                                 slot_idx: u32,
                                 pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
                                 kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>]| {
            let slot = match conn_table.slots.get_mut(slot_idx as usize) {
                Some(s) if s.in_use && !s.closing => s,
                _ => return,
            };

            if slot.in_flight || slot.partial_read.is_empty() {
                return;
            }

            let conn_ref = ConnRef {
                reactor: 0,
                slot: slot_idx,
                gen: slot.gen,
            };

            match parse_http_request(&slot.partial_read) {
                ParseResult::Complete(req) => {
                    let consumed = req.bytes_consumed;
                    slot.in_flight = true;
                    UringReactor::dispatch_admitted_request(
                        outgoing,
                        overflow_pg,
                        overflow_kdf,
                        kdf_rr,
                        req,
                        conn_ref,
                        pg_queues,
                        kdf_queues,
                    );
                    let slot = &mut conn_table.slots[slot_idx as usize];
                    slot.partial_read.drain(..consumed);
                }
                ParseResult::Incomplete => {}
                ParseResult::Error => {
                    slot.partial_read.clear();
                }
            }
        };

        // First call: exactly ONE request dispatched now
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );

        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(slot.in_flight, "Slot must be in flight after first dispatch");
        assert_eq!(pg_q.len(), 1, "Exactly one request dispatched to PG");
        assert_eq!(slot.partial_read.len(), req2.len() + req3.len(), "Remaining 2 requests kept in partial_read");

        // Calling dispatch_next again while in_flight should NOT dispatch anything
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );
        assert_eq!(pg_q.len(), 1, "Still only 1 request dispatched while in_flight is true");

        // Simulate send-completion for request 1:
        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.in_flight = false;

        // After simulated send-completion: the next one is dispatched
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );
        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(slot.in_flight, "Slot must be in flight after second dispatch");
        assert_eq!(pg_q.len(), 2, "Second request dispatched to PG");
        assert_eq!(slot.partial_read.len(), req3.len(), "Remaining 1 request kept in partial_read");

        // Simulate send-completion for request 2:
        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.in_flight = false;

        // After simulated send-completion: the 3rd one is dispatched
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );
        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(slot.in_flight, "Slot must be in flight after third dispatch");
        assert_eq!(pg_q.len(), 3, "Third request dispatched to PG");
        assert!(slot.partial_read.is_empty(), "All requests consumed from partial_read");

        // Simulate send-completion for request 3:
        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.in_flight = false;

        // Now dispatch_next finds partial_read empty, does nothing
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );
        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(!slot.in_flight, "Slot remains not in flight");
        assert_eq!(pg_q.len(), 3);

        unsafe { libc::close(dummy_efd); }
    }

    #[test]
    fn test_pipelined_partial_request_preserved() {
        let dummy_efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        let pg_q: Arc<SpscQueue<Envelope, 1024>> = Arc::new(SpscQueue::new(dummy_efd));
        let pg_queues = vec![pg_q.clone()];
        let kdf_queues = Vec::new();

        let mut conn_table = ConnTable::new(0, 16);
        let (slot_idx, _) = conn_table.allocate(101, 0, false);
        let mut outgoing = OutgoingQueue::new();
        let mut overflow_pg = Vec::new();
        let mut overflow_kdf = VecDeque::new();
        let mut kdf_rr = 0;

        // 1.5 requests: 1 complete GET request + half of a second request
        let req1 = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let req_half = b"GET /api/tags HTTP/1.1\r\nHost: loca";
        let mut input = Vec::new();
        input.extend_from_slice(req1);
        input.extend_from_slice(req_half);

        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.partial_read.extend_from_slice(&input);

        let dispatch_next = |conn_table: &mut ConnTable,
                                 outgoing: &mut OutgoingQueue,
                                 overflow_pg: &mut Vec<VecDeque<Envelope>>,
                                 overflow_kdf: &mut VecDeque<KdfJob>,
                                 kdf_rr: &mut usize,
                                 slot_idx: u32,
                                 pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
                                 kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>]| {
            let slot = match conn_table.slots.get_mut(slot_idx as usize) {
                Some(s) if s.in_use && !s.closing => s,
                _ => return,
            };

            if slot.in_flight || slot.partial_read.is_empty() {
                return;
            }

            let conn_ref = ConnRef {
                reactor: 0,
                slot: slot_idx,
                gen: slot.gen,
            };

            match parse_http_request(&slot.partial_read) {
                ParseResult::Complete(req) => {
                    let consumed = req.bytes_consumed;
                    slot.in_flight = true;
                    UringReactor::dispatch_admitted_request(
                        outgoing,
                        overflow_pg,
                        overflow_kdf,
                        kdf_rr,
                        req,
                        conn_ref,
                        pg_queues,
                        kdf_queues,
                    );
                    let slot = &mut conn_table.slots[slot_idx as usize];
                    slot.partial_read.drain(..consumed);
                }
                ParseResult::Incomplete => {}
                ParseResult::Error => {
                    slot.partial_read.clear();
                }
            }
        };

        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );

        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(slot.in_flight, "Slot must be in flight after complete request dispatched");
        assert_eq!(pg_q.len(), 1, "Exactly one request dispatched to PG");
        assert_eq!(slot.partial_read.as_slice(), req_half, "Half request must be preserved in partial_read");

        // Simulate send-completion for request 1:
        let slot = conn_table.get_slot_mut(slot_idx).unwrap();
        slot.in_flight = false;

        // Dispatch next on the half request: ParseResult::Incomplete, nothing dispatched, half kept
        dispatch_next(
            &mut conn_table,
            &mut outgoing,
            &mut overflow_pg,
            &mut overflow_kdf,
            &mut kdf_rr,
            slot_idx,
            &pg_queues,
            &kdf_queues,
        );
        let slot = conn_table.get_slot(slot_idx).unwrap();
        assert!(!slot.in_flight, "Slot must not be in flight for incomplete request");
        assert_eq!(pg_q.len(), 1, "Still 1 request in PG");
        assert_eq!(slot.partial_read.as_slice(), req_half, "Half request still preserved in partial_read");

        unsafe { libc::close(dummy_efd); }
    }
}
