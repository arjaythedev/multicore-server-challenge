use std::collections::VecDeque;
use std::io;
use std::os::fd::RawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::api::{Api, ClientRef, Effects, Job, PgReq, ReadReq, Reply, Val};
use crate::crypt::CryptPool;
use crate::http::{self, Parsed};
use crate::pg::{P, PgConfig, PgConn, PgResult, bind_exec};
use crate::sql;
use crate::sys;

const LISTENER: u64 = 1 << 40;
const WAKE: u64 = 1 << 41;
const PG: u64 = 1 << 42;

const CLIENT_EVENTS: u32 =
    (libc::EPOLLIN | libc::EPOLLOUT | libc::EPOLLRDHUP | libc::EPOLLET) as u32;

pub struct LoopConfig {
    pub id: usize,
    pub host: String,
    pub port: u16,
    pub pg: Arc<PgConfig>,
    pub statements: Arc<Vec<(String, Vec<u32>)>>,
    pub read_conns: usize,
    pub write_conns: usize,
    pub depth: usize,
    pub write_batch: usize,
    pub read_batch: usize,
    pub read_delay: Duration,
    pub write_delay: Duration,
    pub stats: bool,
}

struct Client {
    fd: RawFd,
    generation: u32,
    inbuf: Vec<u8>,
    out: Vec<u8>,
    out_pos: usize,
    busy: bool,
    close_after: bool,
    eof: bool,
}

pub enum Group {
    One(Job),
    Many(Vec<PgReq>),
    Batch(Vec<Job>),
}

struct Pool {
    conns: Vec<PgConn<Group>>,
    writes: Vec<bool>,
    read_queues: Vec<VecDeque<(u64, Instant, PgReq)>>,
    read_delay: Duration,
    queued_reads: usize,
    seq: u64,
    queue_write: VecDeque<PgReq>,
    write_since: Option<Instant>,
    write_delay: Duration,
    depth: usize,
    read_batch: usize,
    write_batch: usize,
    batch_buf: Vec<u8>,
    last_reconnect: Instant,
    read_groups: u64,
    read_reqs: u64,
}

impl Pool {
    fn pick_read(&self) -> Option<usize> {
        let mut best: Option<usize> = None;
        for (i, c) in self.conns.iter().enumerate() {
            if self.writes[i] || c.broken || c.inflight.len() >= self.depth {
                continue;
            }
            if best.is_none_or(|b| c.inflight.len() < self.conns[b].inflight.len()) {
                best = Some(i);
            }
        }
        best
    }

    fn submit(&mut self, req: PgReq) {
        if req.write {
            if req.batchable && self.write_since.is_none() {
                self.write_since = Some(Instant::now());
            }
            self.queue_write.push_back(req);
            return;
        }
        let q = req.read.as_ref().map_or(sql::SINGLE_COUNT, |r| r.stmt);
        self.seq += 1;
        self.read_queues[q].push_back((self.seq, Instant::now(), req));
        self.queued_reads += 1;
    }

    fn next_due(&self) -> Option<Instant> {
        let write = self.write_since.map(|t| t + self.write_delay);
        if self.read_delay.is_zero() || self.queued_reads == 0 {
            return write;
        }
        self.read_queues
            .iter()
            .filter_map(|q| q.front().map(|(_, at, _)| *at + self.read_delay))
            .chain(write)
            .min()
    }

    fn refill(&mut self) {
        let now = Instant::now();
        while self.queued_reads > 0 {
            let Some(i) = self.pick_read() else {
                break;
            };
            let mut oldest = usize::MAX;
            let mut oldest_seq = u64::MAX;
            for (k, q) in self.read_queues.iter().enumerate() {
                if let Some((seq, at, _)) = q.front()
                    && *seq < oldest_seq
                    && (sql::batched(k).is_none()
                        || q.len() >= self.read_batch
                        || now.duration_since(*at) >= self.read_delay)
                {
                    oldest_seq = *seq;
                    oldest = k;
                }
            }
            if oldest == usize::MAX {
                break;
            }
            let q = &mut self.read_queues[oldest];
            let batched = sql::batched(oldest).filter(|_| q.len() > 1 && self.read_batch > 1);
            self.batch_buf.clear();
            match batched {
                Some(stmt) => {
                    let n = q.len().min(self.read_batch);
                    let mut reqs: Vec<PgReq> = q.drain(..n).map(|(_, _, r)| r).collect();
                    self.queued_reads -= n;
                    encode_batch(&mut self.batch_buf, stmt, &mut reqs);
                    self.read_groups += 1;
                    self.read_reqs += n as u64;
                    let jobs = reqs.into_iter().map(|r| r.job).collect();
                    self.conns[i].send(&self.batch_buf, Group::Batch(jobs));
                }
                None => {
                    let (_, _, req) = q.pop_front().unwrap();
                    self.queued_reads -= 1;
                    self.read_groups += 1;
                    self.read_reqs += 1;
                    match &req.read {
                        Some(r) => encode_one(&mut self.batch_buf, r),
                        None => self.batch_buf.extend_from_slice(&req.msgs),
                    }
                    self.conns[i].send(&self.batch_buf, Group::One(req.job));
                }
            }
        }
        let writes_due = self.queue_write.front().is_some_and(|r| !r.batchable)
            || self.queue_write.len() >= self.write_batch
            || self
                .write_since
                .is_none_or(|t| now.duration_since(t) >= self.write_delay);
        for i in 0..self.conns.len() {
            if self.queue_write.is_empty() || !writes_due {
                break;
            }
            let c = &self.conns[i];
            if !self.writes[i] || c.broken || !c.inflight.is_empty() {
                continue;
            }
            let first = self.queue_write.pop_front().unwrap();
            if !first.batchable || self.queue_write.front().is_none_or(|r| !r.batchable) {
                self.conns[i].send(&first.msgs, Group::One(first.job));
                continue;
            }
            let mut members = vec![first];
            while members.len() < self.write_batch
                && self.queue_write.front().is_some_and(|r| r.batchable)
            {
                members.push(self.queue_write.pop_front().unwrap());
            }
            self.batch_buf.clear();
            for m in &members {
                self.batch_buf.extend_from_slice(&m.msgs);
            }
            self.conns[i].send(&self.batch_buf, Group::Many(members));
        }
        if self.queue_write.is_empty() {
            self.write_since = None;
        } else if writes_due && self.queue_write.front().is_some_and(|r| r.batchable) {
            self.write_since = Some(now);
        }
    }
}

fn encode_one(buf: &mut Vec<u8>, r: &ReadReq) {
    let params: Vec<P> = r
        .vals
        .iter()
        .map(|v| match v {
            Val::I64(n) => P::I64(*n),
            Val::Text(t) => P::Text(t),
        })
        .collect();
    bind_exec(buf, r.stmt, &params);
}

fn encode_batch(buf: &mut Vec<u8>, stmt: usize, reqs: &mut [PgReq]) {
    let width = reqs[0].read.as_ref().map_or(0, |r| r.vals.len());
    let mut ints: Vec<Vec<i64>> = Vec::new();
    let mut texts: Vec<Vec<Vec<u8>>> = Vec::new();
    let mut is_int = Vec::with_capacity(width);
    for j in 0..width {
        let int = matches!(reqs[0].read.as_ref().unwrap().vals[j], Val::I64(_));
        is_int.push(int);
        if int {
            ints.push(
                reqs.iter()
                    .map(|r| match r.read.as_ref().unwrap().vals[j] {
                        Val::I64(n) => n,
                        Val::Text(_) => 0,
                    })
                    .collect(),
            );
        } else {
            texts.push(
                reqs.iter_mut()
                    .map(|r| match &mut r.read.as_mut().unwrap().vals[j] {
                        Val::Text(t) => std::mem::take(t),
                        Val::I64(_) => Vec::new(),
                    })
                    .collect(),
            );
        }
    }
    let (mut ni, mut nt) = (0, 0);
    let mut params = Vec::with_capacity(width);
    for int in is_int {
        if int {
            params.push(P::I64Array(&ints[ni]));
            ni += 1;
        } else {
            params.push(P::TextArray(&texts[nt]));
            nt += 1;
        }
    }
    bind_exec(buf, stmt, &params);
}

pub struct EventLoop {
    id: usize,
    epfd: RawFd,
    listener: RawFd,
    wake_fd: RawFd,
    clients: Vec<Client>,
    free: Vec<u32>,
    pool: Pool,
    cfg: LoopConfig,
    api: Arc<Api>,
    crypt: Arc<CryptPool>,
    fx: Effects,
    body: Vec<u8>,
    head: Vec<u8>,
    scratch: Vec<u8>,
    pg_done: Vec<(Group, PgResult)>,
    responses: u64,
}

impl EventLoop {
    pub fn new(
        cfg: LoopConfig,
        wake_fd: RawFd,
        api: Arc<Api>,
        crypt: Arc<CryptPool>,
    ) -> io::Result<EventLoop> {
        let epfd = sys::epoll_create()?;
        let listener = sys::listen(&cfg.host, cfg.port)?;
        sys::epoll_add(
            epfd,
            listener,
            LISTENER,
            (libc::EPOLLIN | libc::EPOLLET) as u32,
        )?;
        sys::epoll_add(epfd, wake_fd, WAKE, (libc::EPOLLIN | libc::EPOLLET) as u32)?;
        let mut conns = Vec::new();
        let mut writes = Vec::new();
        for i in 0..cfg.read_conns + cfg.write_conns {
            let conn = PgConn::connect(&cfg.pg, &cfg.statements)?;
            sys::epoll_add(epfd, conn.fd, PG | i as u64, CLIENT_EVENTS)?;
            conns.push(conn);
            writes.push(i >= cfg.read_conns);
        }
        Ok(EventLoop {
            id: cfg.id,
            epfd,
            listener,
            wake_fd,
            clients: Vec::new(),
            free: Vec::new(),
            pool: Pool {
                conns,
                writes,
                read_queues: (0..=sql::SINGLE_COUNT).map(|_| VecDeque::new()).collect(),
                queued_reads: 0,
                seq: 0,
                queue_write: VecDeque::new(),
                write_since: None,
                write_delay: cfg.write_delay,
                depth: cfg.depth,
                read_batch: cfg.read_batch,
                read_delay: cfg.read_delay,
                write_batch: cfg.write_batch,
                batch_buf: Vec::new(),
                last_reconnect: Instant::now(),
                read_groups: 0,
                read_reqs: 0,
            },
            cfg,
            api,
            crypt,
            fx: Effects::default(),
            body: Vec::with_capacity(64 * 1024),
            head: Vec::with_capacity(256),
            scratch: vec![0u8; 64 * 1024],
            pg_done: Vec::new(),
            responses: 0,
        })
    }

    pub fn run(&mut self) {
        let mut events = vec![libc::epoll_event { events: 0, u64: 0 }; 1024];
        let mut last_print = Instant::now();
        let mut max_iter = Duration::ZERO;
        loop {
            let any_broken = self.pool.conns.iter().any(|c| c.broken);
            let mut timeout = (any_broken || self.cfg.stats).then_some(Duration::from_secs(1));
            if let Some(due) = self.pool.next_due() {
                let wait = due.saturating_duration_since(Instant::now());
                timeout = Some(timeout.map_or(wait, |t| t.min(wait)));
            }
            let n = sys::epoll_wait_for(self.epfd, &mut events, timeout);
            let woke = Instant::now();
            for ev in &events[..n] {
                let token = ev.u64;
                let flags = ev.events;
                if token == LISTENER {
                    self.accept();
                } else if token == WAKE {
                    self.on_wake();
                } else if token & PG != 0 {
                    let i = (token & !PG) as usize;
                    let conn = &mut self.pool.conns[i];
                    if flags & (libc::EPOLLOUT as u32) != 0 && conn.wants_flush() {
                        conn.flush();
                    }
                    if flags & ((libc::EPOLLIN | libc::EPOLLERR | libc::EPOLLHUP) as u32) != 0 {
                        conn.on_readable(&mut self.pg_done);
                    }
                } else {
                    self.on_client(token as usize, flags);
                }
            }
            self.complete_pg();
            self.after_events();
            if self.cfg.stats {
                max_iter = max_iter.max(woke.elapsed());
                if last_print.elapsed() >= Duration::from_secs(1) {
                    self.print_stats(max_iter);
                    last_print = Instant::now();
                    max_iter = Duration::ZERO;
                }
            }
        }
    }

    fn print_stats(&mut self, max_iter: Duration) {
        let p = &mut self.pool;
        let inflight: usize = p.conns.iter().map(|c| c.inflight.len()).sum();
        let unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        eprintln!(
            "stats {unix} loop={} resp={} max_iter_us={} qread={} qwrite={} inflight={} \
             groups={} per_group={:.2} clients={}",
            self.id,
            self.responses,
            max_iter.as_micros(),
            p.queued_reads,
            p.queue_write.len(),
            inflight,
            p.read_groups,
            p.read_reqs as f64 / p.read_groups.max(1) as f64,
            self.clients.len() - self.free.len(),
        );
        self.responses = 0;
        p.read_groups = 0;
        p.read_reqs = 0;
    }

    fn after_events(&mut self) {
        self.dispatch();
        if self.pool.conns.iter().any(|c| c.broken) {
            self.reconnect();
        }
        self.pool.refill();
        for c in &mut self.pool.conns {
            if c.wants_flush() && !c.broken {
                c.flush();
            }
        }
        for i in 0..self.pool.conns.len() {
            if self.pool.conns[i].broken && !self.pool.conns[i].inflight.is_empty() {
                let mut done = Vec::new();
                self.pool.conns[i].on_readable(&mut done);
                self.pg_done.extend(done);
            }
        }
        if !self.pg_done.is_empty() {
            self.complete_pg();
            self.dispatch();
        }
    }

    fn reconnect(&mut self) {
        if self.pool.last_reconnect.elapsed() < Duration::from_secs(1) {
            return;
        }
        self.pool.last_reconnect = Instant::now();
        for i in 0..self.pool.conns.len() {
            if !self.pool.conns[i].broken || !self.pool.conns[i].inflight.is_empty() {
                continue;
            }
            match PgConn::connect(&self.cfg.pg, &self.cfg.statements) {
                Ok(conn) => {
                    sys::epoll_del(self.epfd, self.pool.conns[i].fd);
                    if sys::epoll_add(self.epfd, conn.fd, PG | i as u64, CLIENT_EVENTS).is_ok() {
                        self.pool.conns[i] = conn;
                    }
                }
                Err(e) => eprintln!("loop {}: reconnect failed: {e}", self.id),
            }
        }
    }

    fn dispatch(&mut self) {
        for req in self.fx.pg.drain(..) {
            self.pool.submit(req);
        }
        for req in self.fx.crypt.drain(..) {
            self.crypt.submit(self.id, req);
        }
    }

    fn complete_pg(&mut self) {
        let mut done = std::mem::take(&mut self.pg_done);
        for (group, res) in done.drain(..) {
            match group {
                Group::One(job) => self.complete_one(job, &res),
                Group::Batch(jobs) if res.err.is_some() => {
                    for job in jobs {
                        let part = res.error_only();
                        self.complete_one(job, &part);
                    }
                }
                Group::Batch(jobs) => {
                    let parts = res.split_by_ordinal(jobs.len());
                    for (job, part) in jobs.into_iter().zip(parts) {
                        self.complete_one(job, &part);
                    }
                }
                Group::Many(members) if res.err.is_some() && !res.is("08006") => {
                    for mut m in members.into_iter().rev() {
                        m.batchable = false;
                        self.pool.queue_write.push_front(m);
                    }
                }
                Group::Many(members) => {
                    let mut start = 0;
                    for m in members {
                        let part = if res.err.is_some() {
                            PgResult::failed("postgres connection lost")
                        } else {
                            res.slice(start, m.stmts)
                        };
                        start += m.stmts;
                        self.complete_one(m.job, &part);
                    }
                }
            }
        }
        self.pg_done = done;
    }

    fn complete_one(&mut self, job: Job, res: &PgResult) {
        let client = job.client;
        if !self.alive(client) {
            return;
        }
        self.body.clear();
        let reply = self.api.on_pg(job, res, &mut self.body, &mut self.fx);
        self.finish(client, reply);
    }

    fn on_wake(&mut self) {
        sys::eventfd_drain(self.wake_fd);
        let done = std::mem::take(&mut *self.crypt.mailbox(self.id).done.lock().unwrap());
        for (job, result) in done {
            let client = job.client;
            if !self.alive(client) {
                continue;
            }
            self.body.clear();
            let reply = self.api.on_crypt(job, result, &mut self.body, &mut self.fx);
            self.finish(client, reply);
        }
    }

    fn alive(&self, c: ClientRef) -> bool {
        let cl = &self.clients[c.slot as usize];
        cl.fd >= 0 && cl.generation == c.generation
    }

    fn accept(&mut self) {
        loop {
            let fd = match sys::accept(self.listener) {
                Ok(fd) => fd,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(e) => {
                    eprintln!("accept: {e}");
                    return;
                }
            };
            let slot = match self.free.pop() {
                Some(s) => s as usize,
                None => {
                    self.clients.push(Client {
                        fd: -1,
                        generation: 0,
                        inbuf: Vec::new(),
                        out: Vec::new(),
                        out_pos: 0,
                        busy: false,
                        close_after: false,
                        eof: false,
                    });
                    self.clients.len() - 1
                }
            };
            let c = &mut self.clients[slot];
            c.fd = fd;
            c.busy = false;
            c.close_after = false;
            c.eof = false;
            if sys::epoll_add(self.epfd, fd, slot as u64, CLIENT_EVENTS).is_err() {
                self.close(slot);
            }
        }
    }

    fn close(&mut self, slot: usize) {
        let c = &mut self.clients[slot];
        if c.fd < 0 {
            return;
        }
        sys::epoll_del(self.epfd, c.fd);
        sys::close(c.fd);
        c.fd = -1;
        c.generation = c.generation.wrapping_add(1);
        c.inbuf = Vec::new();
        c.out = Vec::new();
        c.out_pos = 0;
        self.free.push(slot as u32);
    }

    fn on_client(&mut self, slot: usize, flags: u32) {
        if slot >= self.clients.len() || self.clients[slot].fd < 0 {
            return;
        }
        if flags & (libc::EPOLLOUT as u32) != 0
            && self.clients[slot].out_pos < self.clients[slot].out.len()
        {
            self.flush_client(slot);
            if self.clients[slot].fd < 0 {
                return;
            }
        }
        if flags & ((libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLHUP | libc::EPOLLERR) as u32)
            != 0
        {
            let hup = flags & ((libc::EPOLLRDHUP | libc::EPOLLHUP | libc::EPOLLERR) as u32) != 0;
            self.read_client(slot, hup);
        }
    }

    fn read_client(&mut self, slot: usize, hup: bool) {
        let fd = self.clients[slot].fd;
        loop {
            match sys::read(fd, &mut self.scratch) {
                Ok(0) => {
                    self.clients[slot].eof = true;
                    break;
                }
                Ok(n) => {
                    let c = &mut self.clients[slot];
                    if c.inbuf.len() + n > http::MAX_HEAD + http::MAX_BODY {
                        self.close(slot);
                        return;
                    }
                    c.inbuf.extend_from_slice(&self.scratch[..n]);
                    if n < self.scratch.len() {
                        c.eof |= hup;
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => {
                    self.clients[slot].eof = true;
                    break;
                }
            }
        }
        self.process(slot);
    }

    fn process(&mut self, slot: usize) {
        let mut buf = std::mem::take(&mut self.clients[slot].inbuf);
        let mut used = 0;
        while !self.clients[slot].busy && self.clients[slot].fd >= 0 {
            match http::parse(&buf[used..]) {
                Parsed::Done(req, n) => {
                    used += n;
                    let client = ClientRef {
                        slot: slot as u32,
                        generation: self.clients[slot].generation,
                    };
                    self.clients[slot].close_after = req.close;
                    self.body.clear();
                    let reply = self.api.handle(&req, client, &mut self.body, &mut self.fx);
                    match reply {
                        Reply::Now(status) => self.respond(slot, status),
                        Reply::Later => self.clients[slot].busy = true,
                    }
                }
                Parsed::Partial => break,
                Parsed::Bad => {
                    self.body.clear();
                    crate::json::error(&mut self.body, "bad request");
                    self.clients[slot].close_after = true;
                    self.respond(slot, 400);
                    break;
                }
            }
        }
        let c = &mut self.clients[slot];
        if c.fd < 0 {
            return;
        }
        if used < buf.len() {
            buf.drain(..used);
            c.inbuf = buf;
        }
        if c.eof && !c.busy {
            self.close(slot);
        }
    }

    fn finish(&mut self, client: ClientRef, reply: Reply) {
        let slot = client.slot as usize;
        match reply {
            Reply::Later => {}
            Reply::Now(status) => {
                self.clients[slot].busy = false;
                self.respond(slot, status);
                if self.clients[slot].fd >= 0 {
                    self.process(slot);
                }
            }
        }
    }

    fn respond(&mut self, slot: usize, status: u16) {
        self.responses += 1;
        let c = &mut self.clients[slot];
        let body: &[u8] = if status == 204 { b"" } else { &self.body };
        self.head.clear();
        http::head(&mut self.head, status, body.len(), c.close_after);
        if c.out_pos < c.out.len() {
            c.out.extend_from_slice(&self.head);
            c.out.extend_from_slice(body);
            return;
        }
        let total = self.head.len() + body.len();
        let sent = loop {
            match sys::send2(c.fd, &self.head, body) {
                Ok(n) => break n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break 0,
                Err(_) => {
                    self.close(slot);
                    return;
                }
            }
        };
        if sent < total {
            c.out.clear();
            c.out_pos = 0;
            if sent < self.head.len() {
                c.out.extend_from_slice(&self.head[sent..]);
                c.out.extend_from_slice(body);
            } else {
                c.out.extend_from_slice(&body[sent - self.head.len()..]);
            }
        } else if c.close_after {
            self.close(slot);
        }
    }

    fn flush_client(&mut self, slot: usize) {
        let c = &mut self.clients[slot];
        while c.out_pos < c.out.len() {
            match sys::send(c.fd, &c.out[c.out_pos..]) {
                Ok(n) => c.out_pos += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(_) => {
                    self.close(slot);
                    return;
                }
            }
        }
        c.out = Vec::new();
        c.out_pos = 0;
        if c.close_after {
            self.close(slot);
        }
    }
}
