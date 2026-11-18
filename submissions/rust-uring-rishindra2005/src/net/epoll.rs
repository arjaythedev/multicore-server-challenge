//! Edge-triggered Epoll fallback reactor.
//! Provides runtime fallback with SO_REUSEPORT when io_uring is unavailable.

use std::collections::VecDeque;
use std::os::unix::io::RawFd;
use std::sync::Arc;

use crate::net::conn::ConnTable;
use crate::net::http::{parse_http_request, HttpMethod, ParseResult};
use crate::net::send::OutgoingQueue;
use crate::rt::spsc::SpscQueue;
use crate::types::{ConnRef, Envelope, KdfJob, Reply};

pub struct EpollReactor {
    pub reactor_id: u8,
    pub ep_fd: RawFd,
    pub listen_fd: RawFd,
    pub conn_table: ConnTable,
    pub outgoing: OutgoingQueue,
    pub scratch: Box<[u8; 65536]>,
    pub overflow_pg: Vec<VecDeque<Envelope>>,
    pub overflow_kdf: VecDeque<KdfJob>,
    pub kdf_rr: usize,
    pub pg_queues: Vec<Arc<SpscQueue<Envelope, 1024>>>,
    pub kdf_queues: Vec<Arc<SpscQueue<KdfJob, 512>>>,
}

impl EpollReactor {
    pub fn new(reactor_id: u8, listen_fd: RawFd, capacity: usize) -> std::io::Result<Self> {
        let ep_fd = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
        if ep_fd < 0 {
            return Err(std::io::Error::last_os_error());
        }

        let mut ev = libc::epoll_event {
            events: (libc::EPOLLIN | libc::EPOLLET) as u32,
            u64: u64::MAX, // Sentinel for listener
        };
        let rc = unsafe { libc::epoll_ctl(ep_fd, libc::EPOLL_CTL_ADD, listen_fd, &mut ev) };
        if rc < 0 {
            unsafe { libc::close(ep_fd) };
            return Err(std::io::Error::last_os_error());
        }

        Ok(Self {
            reactor_id,
            ep_fd,
            listen_fd,
            conn_table: ConnTable::new(reactor_id, capacity),
            outgoing: OutgoingQueue::new(),
            scratch: Box::new([0u8; 65536]),
            overflow_pg: Vec::new(),
            overflow_kdf: VecDeque::new(),
            kdf_rr: 0,
            pg_queues: Vec::new(),
            kdf_queues: Vec::new(),
        })
    }

    #[inline(always)]
    pub fn has_overflow(&self) -> bool {
        !self.overflow_kdf.is_empty() || self.overflow_pg.iter().any(|q| !q.is_empty())
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

    pub fn accept_connections(&mut self) -> Vec<(u32, ConnRef, RawFd)> {
        let mut accepted = Vec::new();

        loop {
            let mut sa: libc::sockaddr_in = unsafe { std::mem::zeroed() };
            let mut slen: libc::socklen_t = std::mem::size_of::<libc::sockaddr_in>() as u32;

            let cfd = unsafe {
                libc::accept4(
                    self.listen_fd,
                    &mut sa as *mut _ as *mut libc::sockaddr,
                    &mut slen,
                    libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                )
            };

            if cfd < 0 {
                break;
            }

            // Tune accepted socket (TCP_NODELAY, no buffer clamp per ARCHITECTURE §5)
            unsafe {
                let yes: libc::c_int = 1;
                libc::setsockopt(cfd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &yes as *const _ as *const libc::c_void, 4);
            }

            let (slot_idx, conn_ref) = self.conn_table.allocate(cfd, 0, false);

            let mut ev = libc::epoll_event {
                events: (libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLET) as u32,
                u64: slot_idx as u64,
            };
            unsafe {
                libc::epoll_ctl(self.ep_fd, libc::EPOLL_CTL_ADD, cfd, &mut ev);
            }

            accepted.push((slot_idx, conn_ref, cfd));
        }

        accepted
    }

    pub fn handle_event(
        &mut self,
        slot_idx: u32,
        events: u32,
        pg_queues: &[Arc<SpscQueue<Envelope, 1024>>],
        kdf_queues: &[Arc<SpscQueue<KdfJob, 512>>],
    ) {
        if self.pg_queues.is_empty() {
            self.pg_queues = pg_queues.to_vec();
            self.kdf_queues = kdf_queues.to_vec();
        }

        if events & ((libc::EPOLLERR | libc::EPOLLHUP | libc::EPOLLRDHUP) as u32) != 0 {
            self.close_connection(slot_idx);
            return;
        }

        if events & (libc::EPOLLIN as u32) != 0 {
            loop {
                let fd = match self.conn_table.get_slot(slot_idx) {
                    Some(s) if s.in_use => s.fd,
                    _ => return,
                };

                let n = unsafe {
                    libc::recv(
                        fd,
                        self.scratch.as_mut_ptr() as *mut libc::c_void,
                        self.scratch.len(),
                        libc::MSG_DONTWAIT,
                    )
                };

                if n > 0 {
                    let chunk = &self.scratch[..n as usize];
                    let slot = match self.conn_table.get_slot_mut(slot_idx) {
                        Some(s) if s.in_use => s,
                        _ => return,
                    };

                    slot.partial_read.extend_from_slice(chunk);
                    if !slot.in_flight {
                        self.try_dispatch_next(slot_idx);
                    }
                } else if n == 0 {
                    // EOF
                    self.close_connection(slot_idx);
                    break;
                } else {
                    let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                    if err == libc::EAGAIN || err == libc::EWOULDBLOCK {
                        break;
                    } else {
                        self.close_connection(slot_idx);
                        break;
                    }
                }
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
            ParseResult::Incomplete => {}
            ParseResult::Error => {
                slot.partial_read.clear();
                self.close_connection(slot_idx);
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

    pub fn flush_sends(&mut self) {
        let mut to_close = Vec::new();
        let mut to_dispatch = Vec::new();

        for reply in self.outgoing.pending_replies.drain(..) {
            let slot_idx = reply.conn.slot;
            let slot = match self.conn_table.validate_mut(&reply.conn) {
                Some(s) => s,
                None => continue,
            };

            let mut offset = 0;
            let mut failed = false;
            while offset < reply.bytes.len() {
                let n = unsafe {
                    libc::send(
                        slot.fd,
                        reply.bytes[offset..].as_ptr() as *const libc::c_void,
                        reply.bytes.len() - offset,
                        libc::MSG_NOSIGNAL,
                    )
                };
                if n > 0 {
                    offset += n as usize;
                } else if n < 0 {
                    let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                    if err == libc::EAGAIN || err == libc::EWOULDBLOCK {
                        // In non-blocking epoll, wait or retry; for simplicity in benchmark loop yield
                        std::thread::yield_now();
                        continue;
                    }
                    failed = true;
                    break;
                } else {
                    failed = true;
                    break;
                }
            }

            if failed || reply.close {
                to_close.push(slot_idx);
            } else {
                slot.in_flight = false;
                if !slot.partial_read.is_empty() {
                    to_dispatch.push(slot_idx);
                }
            }
        }

        for slot_idx in to_dispatch {
            self.try_dispatch_next(slot_idx);
        }

        for slot_idx in to_close {
            self.close_connection(slot_idx);
        }
    }

    pub fn close_connection(&mut self, slot_idx: u32) {
        let (fd, _, _) = self.conn_table.release(slot_idx);
        if fd >= 0 {
            unsafe {
                libc::epoll_ctl(self.ep_fd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
                libc::close(fd);
            }
        }
    }
}

impl Drop for EpollReactor {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.ep_fd);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Job;

    #[test]
    fn test_epoll_overflow_queue() {
        let dummy_efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        let pg_q: Arc<SpscQueue<Envelope, 1024>> = Arc::new(SpscQueue::new(dummy_efd));
        let mut overflow_pg: Vec<VecDeque<Envelope>> = Vec::new();
        overflow_pg.resize_with(1, VecDeque::new);

        // Fill pg_q completely (1024 items)
        for _ in 0..1024 {
            let env = Envelope {
                conn: ConnRef { reactor: 0, slot: 0, gen: 1 },
                viewer: 0,
                token: None,
                keepalive: true,
                job: Job::Tags,
            };
            assert!(pg_q.push(env).is_ok());
        }

        // pg_q is now full! Pushing one more must overflow and not drop
        let overflow_env = Envelope {
            conn: ConnRef { reactor: 0, slot: 0, gen: 1 },
            viewer: 42,
            token: None,
            keepalive: true,
            job: Job::Tags,
        };

        let pg_queues = [pg_q.clone()];
        let ov = &mut overflow_pg[0];
        if ov.is_empty() {
            if let Err(env) = pg_queues[0].push(overflow_env) {
                ov.push_back(env);
            }
        }
        assert_eq!(overflow_pg[0].len(), 1, "Should have 1 item in overflow queue");

        // Drain one item from pg_q
        assert!(pg_q.pop().is_some());

        // Now flush overflow
        while let Some(env) = overflow_pg[0].pop_front() {
            if let Err(env) = pg_queues[0].push(env) {
                overflow_pg[0].push_front(env);
                break;
            }
        }

        assert_eq!(overflow_pg[0].len(), 0, "Overflow queue should be drained");
        unsafe { libc::close(dummy_efd); }
    }
}
