//! A small pipelined Postgres client on the extended protocol (postgres-protocol for message framing).
//!
//! Connections are opened and prepared with blocking I/O at startup, then switched to non-blocking and driven by the
//! owning event loop. A request submits a *group*: one or more Bind+Execute pairs. Postgres runs everything between
//! two Syncs as one implicit transaction, so a group is atomic, and several groups may share a Sync (see `Policy`):
//! one commit then covers several writes, and a failure inside a shared Sync is attributed to its group, whose
//! neighbours are sent again on their own.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::TcpStream as StdTcpStream;
use std::ops::Range;
use std::time::{Duration, Instant};

use bytes::{BufMut, Bytes, BytesMut};
use fallible_iterator::FallibleIterator;
use postgres_protocol::authentication::{md5_hash, sasl};
use postgres_protocol::message::backend::{DataRowBody, Message};
use postgres_protocol::message::frontend;
use postgres_protocol::types;
use postgres_protocol::IsNull;

use crate::sql::{self, NAMES, STATEMENTS, TEXT};

#[derive(Clone)]
pub struct PgConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub dbname: String,
    /// Session settings sent once per connection.
    pub settings: String,
}

impl PgConfig {
    /// `postgres://user:password@host:port/dbname` (query parameters are ignored).
    pub fn from_url(url: &str) -> Result<PgConfig, String> {
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))
            .ok_or("DATABASE_URL must start with postgres://")?;
        let rest = rest.split('?').next().unwrap_or("");
        let (auth, hostpart) = rest.rsplit_once('@').unwrap_or(("", rest));
        let (user, password) = auth.split_once(':').unwrap_or((auth, ""));
        let (hostport, dbname) = hostpart.split_once('/').unwrap_or((hostpart, ""));
        let (host, port) = match hostport.rsplit_once(':') {
            Some((h, p)) => (h, p.parse().map_err(|_| "bad port in DATABASE_URL")?),
            None => (hostport, 5432),
        };
        let dec = |s: &str| crate::util::decode_segment(s).ok_or("bad percent-encoding in DATABASE_URL");
        let user = dec(user)?;
        Ok(PgConfig {
            host: if host.is_empty() { "127.0.0.1".into() } else { host.into() },
            port,
            dbname: if dbname.is_empty() { user.clone() } else { dec(dbname)? },
            password: dec(password)?,
            user,
            settings: String::new(),
        })
    }
}

/// An owned bind parameter, sent in binary format.
pub enum P {
    Null,
    I64(i64),
    Text(String),
    TextArr(Vec<String>),
}

impl P {
    pub fn opt_text(s: Option<&str>) -> P {
        s.map_or(P::Null, |s| P::Text(s.to_string()))
    }
}

#[derive(Debug)]
pub struct PgError {
    pub code: String,
    pub message: String,
}

impl PgError {
    pub fn connection(msg: impl Into<String>) -> PgError {
        PgError { code: "08006".into(), message: msg.into() }
    }
}

/// One DataRow, with its column ranges decoded once.
pub struct Row {
    body: DataRowBody,
    cols: Vec<Option<Range<usize>>>,
}

impl Row {
    fn new(body: DataRowBody) -> io::Result<Row> {
        let cols = body.ranges().collect()?;
        Ok(Row { body, cols })
    }

    fn raw(&self, i: usize) -> Option<&[u8]> {
        self.cols[i].clone().map(|r| &self.body.buffer()[r])
    }

    pub fn is_null(&self, i: usize) -> bool {
        self.cols[i].is_none()
    }

    pub fn i64(&self, i: usize) -> i64 {
        types::int8_from_sql(self.raw(i).expect("NULL int8")).expect("int8")
    }

    pub fn bool(&self, i: usize) -> bool {
        types::bool_from_sql(self.raw(i).expect("NULL bool")).expect("bool")
    }

    pub fn str(&self, i: usize) -> &str {
        types::text_from_sql(self.raw(i).expect("NULL text")).expect("text")
    }

    pub fn opt_str(&self, i: usize) -> Option<&str> {
        self.raw(i).map(|b| types::text_from_sql(b).expect("text"))
    }

    /// timestamptz as µs since 2000-01-01 UTC.
    pub fn ts(&self, i: usize) -> i64 {
        types::timestamp_from_sql(self.raw(i).expect("NULL timestamp")).expect("timestamp")
    }

    /// A one-dimensional text[]; NULL elements are skipped.
    pub fn text_array(&self, i: usize, mut f: impl FnMut(&str)) {
        let arr = types::array_from_sql(self.raw(i).expect("NULL array")).expect("array");
        let mut values = arr.values();
        while let Some(v) = values.next().expect("array element") {
            if let Some(v) = v {
                f(types::text_from_sql(v).expect("text"));
            }
        }
    }
}

#[derive(Default)]
pub struct StmtResult {
    pub rows: Vec<Row>,
    /// Row count from the CommandComplete tag (INSERT/UPDATE/DELETE/SELECT n).
    pub affected: u64,
}

pub type GroupResult = Result<Vec<StmtResult>, PgError>;

/// How a connection puts request groups under Syncs. Several groups under one Sync run as one implicit transaction
/// (never an explicit BEGIN: an error inside one would leave the session aborted for every batch queued behind it).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Policy {
    /// Groups submitted during one loop iteration share a Sync, up to `cap`. A member's results are released as soon
    /// as its last statement completes: a read-only member has nothing to commit.
    Read { cap: usize },
    /// At most one Sync in flight. Groups arriving meanwhile wait in `held` and then go out together, so one commit
    /// (one WAL flush) covers all of them. Results are released at ReadyForQuery, i.e. after the commit.
    Write { cap: usize },
}

/// Routing estimate for the per-Sync work around a group (Bind/Sync handling, transaction start and end).
const GROUP_OVERHEAD_US: u32 = 20;

/// Statements whose errors are expected outcomes, or that take locks in an order a shared transaction can't keep
/// sorted (tag inserts): a group containing one never shares a Sync.
fn solo_statement(stmt: usize) -> bool {
    matches!(stmt, sql::USER_INSERT | sql::USER_UPDATE | sql::TAGS_INSERT)
}

fn retryable(e: &PgError) -> bool {
    matches!(e.code.as_str(), "40P01" | "40001")
}

/// One request group, from submission to its single completion.
struct Member {
    tag: u64,
    nstmts: usize,
    cost: u32,
    /// Bind+Execute messages without the Sync, kept so the group can be sent again on its own.
    msgs: Bytes,
    solo: bool,
    /// Already resent after a deadlock or serialization failure; another one is final.
    retried: bool,
    done: bool,
    /// Results of a write-batch member, held until the batch's ReadyForQuery.
    out: Option<Vec<StmtResult>>,
}

/// Everything up to one Sync.
struct Pending {
    members: Vec<Member>,
    /// Release results at ReadyForQuery (after the commit) instead of per member.
    write: bool,
    /// The member whose statements are arriving now.
    next: usize,
    results: Vec<StmtResult>,
    cur: Option<StmtResult>,
    /// First error and the member it belongs to; Postgres skips everything after it until the Sync.
    err: Option<(usize, PgError)>,
}

impl Pending {
    fn new(write: bool) -> Pending {
        Pending { members: Vec::new(), write, next: 0, results: Vec::new(), cur: None, err: None }
    }
}

/// Counters for the stats line.
#[derive(Default, Clone, Copy)]
pub struct PipeStats {
    /// Syncs sent with more than one member, and the members in them.
    pub batches: u64,
    pub batched: u64,
    /// Failed multi-member Syncs and single-member deadlock resends.
    pub retries: u64,
}

/// The protocol state of one connection, independent of the socket.
pub struct Pipe {
    policy: Policy,
    wbuf: BytesMut,
    rbuf: BytesMut,
    sent: VecDeque<Pending>,
    /// Read policy: this iteration's batch; its messages are already in `wbuf`, its Sync is not.
    open: Option<Pending>,
    /// Write policy: groups waiting for the in-flight Sync.
    held: VecDeque<Member>,
    work_us: u64,
    queued: usize,
    pub stats: PipeStats,
}

impl Pipe {
    pub fn new(policy: Policy) -> Pipe {
        Pipe {
            policy,
            wbuf: BytesMut::with_capacity(16 * 1024),
            rbuf: BytesMut::with_capacity(64 * 1024),
            sent: VecDeque::new(),
            open: None,
            held: VecDeque::new(),
            work_us: 0,
            queued: 0,
            stats: PipeStats::default(),
        }
    }

    /// Groups not yet answered (in flight, in the open batch or held).
    pub fn queued(&self) -> usize {
        self.queued
    }

    pub fn held(&self) -> usize {
        self.held.len()
    }

    /// Estimated Postgres time of every unanswered group, in microseconds.
    pub fn work_us(&self) -> u64 {
        self.work_us
    }

    /// Queues a group. `write` = it modifies data (its results wait for the commit).
    pub fn submit(&mut self, group: &[(usize, Vec<P>)], tag: u64, write: bool) {
        let mut msgs = BytesMut::new();
        let mut cost = GROUP_OVERHEAD_US;
        let mut solo = false;
        for (stmt, params) in group {
            debug_assert_eq!(STATEMENTS[*stmt].params.len(), params.len(), "param count for s{stmt}");
            frontend::bind("", NAMES[*stmt], [1i16], params.iter(), encode_param, [1i16], &mut msgs)
                .unwrap_or_else(|_| panic!("bind encoding for s{stmt}"));
            frontend::execute("", 0, &mut msgs).expect("execute encoding");
            cost += sql::COST_US[*stmt];
            solo |= solo_statement(*stmt);
        }
        let m = Member {
            tag,
            nstmts: group.len(),
            cost,
            msgs: msgs.freeze(),
            solo,
            retried: false,
            done: false,
            out: None,
        };
        self.work_us += cost as u64;
        self.queued += 1;
        match self.policy {
            Policy::Read { cap } => {
                if write || m.solo || cap <= 1 {
                    self.send_alone(m, write);
                    return;
                }
                let open = self.open.get_or_insert_with(|| Pending::new(false));
                self.wbuf.extend_from_slice(&m.msgs);
                open.members.push(m);
                if open.members.len() >= cap {
                    self.close_open();
                }
            }
            // A read routed here (no read connection is up) doesn't wait for the batch.
            Policy::Write { .. } if !write => self.send_alone(m, false),
            Policy::Write { .. } => self.held.push_back(m),
        }
    }

    /// Closes the open batch and forms a write batch if nothing is in flight. Called before every socket write.
    pub fn prepare_send(&mut self) {
        self.close_open();
        self.release_held();
    }

    pub fn has_output(&self) -> bool {
        !self.wbuf.is_empty()
    }

    fn close_open(&mut self) {
        // The open batch is still being filled until its members' messages are all in wbuf; closing just adds the Sync.
        let Some(p) = self.open.take() else { return };
        frontend::sync(&mut self.wbuf);
        if p.members.len() > 1 {
            self.stats.batches += 1;
            self.stats.batched += p.members.len() as u64;
        }
        self.sent.push_back(p);
    }

    fn send_alone(&mut self, mut m: Member, write: bool) {
        // Keep wire order equal to `sent` order: an open batch's messages are already in wbuf.
        self.close_open();
        m.solo = true;
        self.wbuf.extend_from_slice(&m.msgs);
        frontend::sync(&mut self.wbuf);
        let mut p = Pending::new(write);
        p.members.push(m);
        self.sent.push_back(p);
    }

    /// Write policy: with nothing in flight, sends the held groups (a solo one alone) as the next Sync.
    fn release_held(&mut self) -> bool {
        let Policy::Write { cap } = self.policy else { return false };
        if !self.sent.is_empty() || self.held.is_empty() {
            return false;
        }
        if self.held.front().is_some_and(|m| m.solo) {
            let m = self.held.pop_front().expect("front exists");
            self.send_alone(m, true);
            return true;
        }
        let mut p = Pending::new(true);
        while p.members.len() < cap && self.held.front().is_some_and(|m| !m.solo) {
            let m = self.held.pop_front().expect("front exists");
            self.wbuf.extend_from_slice(&m.msgs);
            p.members.push(m);
        }
        frontend::sync(&mut self.wbuf);
        if p.members.len() > 1 {
            self.stats.batches += 1;
            self.stats.batched += p.members.len() as u64;
        }
        self.sent.push_back(p);
        true
    }

    fn deliver(&mut self, m: &mut Member, res: GroupResult, done: &mut Vec<(u64, GroupResult)>) {
        debug_assert!(!m.done, "a group is answered once");
        m.done = true;
        self.work_us -= m.cost as u64;
        self.queued -= 1;
        done.push((m.tag, res));
    }

    /// Parses buffered messages, appending every answered group to `done`. Returns true when it queued output (a
    /// resend or a released write batch) that the caller must flush.
    fn parse(&mut self, done: &mut Vec<(u64, GroupResult)>) -> io::Result<bool> {
        let mut output = false;
        while let Some(msg) = Message::parse(&mut self.rbuf)? {
            match msg {
                Message::BindComplete => {
                    let p = self.sent.front_mut().ok_or_else(|| protocol("BindComplete without a pending group"))?;
                    p.cur = Some(StmtResult::default());
                }
                Message::DataRow(body) => {
                    let p = self.sent.front_mut().ok_or_else(|| protocol("DataRow without a pending group"))?;
                    p.cur.get_or_insert_with(StmtResult::default).rows.push(Row::new(body)?);
                }
                Message::CommandComplete(body) => {
                    let p = self.sent.front_mut().ok_or_else(|| protocol("CommandComplete without a pending group"))?;
                    let mut r = p.cur.take().unwrap_or_default();
                    r.affected = body.tag().ok().and_then(|t| t.rsplit(' ').next()?.parse().ok()).unwrap_or(0);
                    p.results.push(r);
                    let k = p.next;
                    let m = p.members.get(k).ok_or_else(|| protocol("more results than statements"))?;
                    if p.results.len() == m.nstmts {
                        let res = std::mem::take(&mut p.results);
                        p.next += 1;
                        let m = &mut p.members[k];
                        if p.write {
                            m.out = Some(res);
                        } else {
                            m.done = true;
                            let (tag, cost) = (m.tag, m.cost);
                            self.work_us -= cost as u64;
                            self.queued -= 1;
                            done.push((tag, Ok(res)));
                        }
                    }
                }
                Message::EmptyQueryResponse => return Err(protocol("unexpected EmptyQueryResponse")),
                Message::ErrorResponse(body) => {
                    let mut code = String::new();
                    let mut message = String::new();
                    let mut fatal = false;
                    let mut fields = body.fields();
                    while let Some(f) = fields.next()? {
                        match f.type_() {
                            b'C' => code = String::from_utf8_lossy(f.value_bytes()).into_owned(),
                            b'M' => message = String::from_utf8_lossy(f.value_bytes()).into_owned(),
                            b'V' => fatal = matches!(f.value_bytes(), b"FATAL" | b"PANIC"),
                            _ => {}
                        }
                    }
                    if fatal {
                        return Err(io::Error::other(format!("postgres {code}: {message}")));
                    }
                    let p = self.sent.front_mut().ok_or_else(|| protocol("ErrorResponse without a pending group"))?;
                    p.cur = None;
                    if p.err.is_none() {
                        p.err = Some((p.next, PgError { code, message }));
                    }
                }
                Message::ReadyForQuery(_) => {
                    let p = self.sent.pop_front().ok_or_else(|| protocol("ReadyForQuery without a pending group"))?;
                    output |= self.finish(p, done);
                    output |= self.release_held();
                }
                // NoticeResponse, ParameterStatus, NotificationResponse and other asynchronous messages.
                _ => {}
            }
        }
        Ok(output)
    }

    /// A Sync's ReadyForQuery: answers its members, or resends the ones an error rolled back or never ran.
    fn finish(&mut self, p: Pending, done: &mut Vec<(u64, GroupResult)>) -> bool {
        let Pending { members, write, err, .. } = p;
        let multi = members.len() > 1;
        let mut output = false;
        match err {
            None => {
                for mut m in members.into_iter().filter(|m| !m.done) {
                    let res = match m.out.take() {
                        Some(r) => Ok(r),
                        None => Err(PgError::connection("incomplete result")),
                    };
                    self.deliver(&mut m, res, done);
                }
            }
            Some((k, e)) => {
                // An error after the last statement (at commit) belongs to the last member: otherwise every member
                // would look rolled back and be resent forever.
                let k = k.min(members.len() - 1);
                if multi || retryable(&e) {
                    self.stats.retries += 1;
                }
                for (i, mut m) in members.into_iter().enumerate() {
                    if m.done {
                        continue; // a read member answered before the error
                    }
                    if i == k && !(retryable(&e) && !m.retried) {
                        let e = PgError { code: e.code.clone(), message: e.message.clone() };
                        self.deliver(&mut m, Err(e), done);
                        continue;
                    }
                    // Rolled back (before the error), never run (after it), or a first deadlock/serialization failure.
                    if i == k {
                        m.retried = true;
                    }
                    m.out = None;
                    self.send_alone(m, write);
                    output = true;
                }
            }
        }
        output
    }

    /// Fails every unanswered group (connection lost).
    pub fn fail_all(&mut self, done: &mut Vec<(u64, GroupResult)>, why: &str) {
        let mut members: Vec<Member> = Vec::new();
        for p in self.sent.drain(..).chain(self.open.take()) {
            members.extend(p.members);
        }
        members.extend(self.held.drain(..));
        for mut m in members.into_iter().filter(|m| !m.done) {
            self.deliver(&mut m, Err(PgError::connection(why)), done);
        }
        debug_assert_eq!((self.queued, self.work_us), (0, 0));
        self.queued = 0;
        self.work_us = 0;
        self.wbuf.clear();
        self.rbuf.clear();
    }
}

pub struct PgConn {
    pub stream: mio::net::TcpStream,
    pipe: Pipe,
}

impl std::ops::Deref for PgConn {
    type Target = Pipe;
    fn deref(&self) -> &Pipe {
        &self.pipe
    }
}

impl std::ops::DerefMut for PgConn {
    fn deref_mut(&mut self) -> &mut Pipe {
        &mut self.pipe
    }
}

impl PgConn {
    pub fn from_std(s: StdTcpStream, policy: Policy) -> PgConn {
        PgConn { stream: mio::net::TcpStream::from_std(s), pipe: Pipe::new(policy) }
    }

    /// Writes buffered output until done or the socket would block.
    pub fn flush(&mut self) -> io::Result<()> {
        self.pipe.prepare_send();
        while !self.pipe.wbuf.is_empty() {
            match self.stream.write(&self.pipe.wbuf) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    let _ = self.pipe.wbuf.split_to(n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    /// Reads until the socket would block and appends every answered group to `done`. Returns true when parsing
    /// queued output to flush. An error means the connection is unusable.
    pub fn read_ready(&mut self, done: &mut Vec<(u64, GroupResult)>) -> io::Result<bool> {
        let mut output = false;
        loop {
            let rbuf = &mut self.pipe.rbuf;
            if rbuf.capacity() - rbuf.len() < 16 * 1024 {
                rbuf.reserve(64 * 1024);
            }
            let spare = rbuf.spare_capacity_mut();
            // SAFETY: read() only writes initialized bytes into the slice and we only advance by what it returned.
            let buf = unsafe { std::slice::from_raw_parts_mut(spare.as_mut_ptr() as *mut u8, spare.len()) };
            match self.stream.read(buf) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "postgres closed the connection")),
                Ok(n) => unsafe { rbuf.set_len(rbuf.len() + n) },
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
            output |= self.pipe.parse(done)?;
        }
        Ok(output | self.pipe.parse(done)?)
    }
}

fn protocol(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

fn encode_param(p: &P, buf: &mut BytesMut) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
    match p {
        P::Null => return Ok(IsNull::Yes),
        P::I64(v) => types::int8_to_sql(*v, buf),
        P::Text(s) => types::text_to_sql(s, buf),
        P::TextArr(items) => {
            // One-dimensional text[] in binary array format: ndim, has-nulls flag, element oid, (len, lower bound).
            buf.put_i32(1);
            buf.put_i32(0);
            buf.put_u32(TEXT);
            buf.put_i32(items.len() as i32);
            buf.put_i32(1);
            for s in items {
                buf.put_i32(s.len() as i32);
                buf.put_slice(s.as_bytes());
            }
        }
    }
    Ok(IsNull::No)
}

/// Opens, authenticates and prepares one connection with blocking I/O, retrying until `deadline`.
pub fn connect(cfg: &PgConfig, deadline: Instant) -> Result<StdTcpStream, String> {
    let mut wait = Duration::from_millis(200);
    loop {
        match connect_once(cfg) {
            Ok(s) => return Ok(s),
            Err(e) if Instant::now() + wait < deadline => {
                eprintln!("[pg] connect failed ({e}); retrying in {wait:?}");
                std::thread::sleep(wait);
                wait = (wait * 2).min(Duration::from_secs(2));
            }
            Err(e) => return Err(e),
        }
    }
}

fn connect_once(cfg: &PgConfig) -> Result<StdTcpStream, String> {
    let mut s = StdTcpStream::connect((cfg.host.as_str(), cfg.port)).map_err(|e| e.to_string())?;
    s.set_nodelay(true).map_err(|e| e.to_string())?;
    let mut c = Blocking { s: &mut s, rbuf: BytesMut::with_capacity(8192), wbuf: BytesMut::new() };

    frontend::startup_message(
        [("user", cfg.user.as_str()), ("database", cfg.dbname.as_str()), ("client_encoding", "UTF8"), ("application_name", "conduit-mio")],
        &mut c.wbuf,
    )
    .map_err(|e| e.to_string())?;
    c.send()?;

    let mut scram: Option<sasl::ScramSha256> = None;
    loop {
        match c.recv()? {
            Message::AuthenticationOk => break,
            Message::AuthenticationCleartextPassword => {
                frontend::password_message(cfg.password.as_bytes(), &mut c.wbuf).map_err(|e| e.to_string())?;
                c.send()?;
            }
            Message::AuthenticationMd5Password(body) => {
                let hash = md5_hash(cfg.user.as_bytes(), cfg.password.as_bytes(), body.salt());
                frontend::password_message(hash.as_bytes(), &mut c.wbuf).map_err(|e| e.to_string())?;
                c.send()?;
            }
            Message::AuthenticationSasl(body) => {
                let mut mechs = body.mechanisms();
                let mut ok = false;
                while let Some(m) = mechs.next().map_err(|e| e.to_string())? {
                    ok |= m == sasl::SCRAM_SHA_256;
                }
                if !ok {
                    return Err("server offers no SCRAM-SHA-256".into());
                }
                let sc = sasl::ScramSha256::new(cfg.password.as_bytes(), sasl::ChannelBinding::unsupported());
                frontend::sasl_initial_response(sasl::SCRAM_SHA_256, sc.message(), &mut c.wbuf).map_err(|e| e.to_string())?;
                c.send()?;
                scram = Some(sc);
            }
            Message::AuthenticationSaslContinue(body) => {
                let sc = scram.as_mut().ok_or("unexpected SASL continue")?;
                sc.update(body.data()).map_err(|e| e.to_string())?;
                frontend::sasl_response(sc.message(), &mut c.wbuf).map_err(|e| e.to_string())?;
                c.send()?;
            }
            Message::AuthenticationSaslFinal(body) => {
                scram.as_mut().ok_or("unexpected SASL final")?.finish(body.data()).map_err(|e| e.to_string())?;
            }
            Message::ErrorResponse(body) => return Err(error_text(&body)),
            _ => return Err("unsupported authentication method".into()),
        }
    }
    c.until_ready()?;

    if !cfg.settings.is_empty() {
        frontend::query(&cfg.settings, &mut c.wbuf).map_err(|e| e.to_string())?;
        c.send()?;
        c.until_ready()?;
    }
    for (i, st) in STATEMENTS.iter().enumerate() {
        frontend::parse(NAMES[i], st.sql, st.params.iter().copied(), &mut c.wbuf).map_err(|e| e.to_string())?;
    }
    frontend::sync(&mut c.wbuf);
    c.send()?;
    c.until_ready().map_err(|e| format!("preparing statements: {e}"))?;

    s.set_nonblocking(true).map_err(|e| e.to_string())?;
    Ok(s)
}

fn error_text(body: &postgres_protocol::message::backend::ErrorResponseBody) -> String {
    let mut out = String::new();
    let mut fields = body.fields();
    while let Ok(Some(f)) = fields.next() {
        if matches!(f.type_(), b'C' | b'M') {
            out.push_str(&String::from_utf8_lossy(f.value_bytes()));
            out.push(' ');
        }
    }
    out
}

struct Blocking<'a> {
    s: &'a mut StdTcpStream,
    rbuf: BytesMut,
    wbuf: BytesMut,
}

impl Blocking<'_> {
    fn send(&mut self) -> Result<(), String> {
        self.s.write_all(&self.wbuf).map_err(|e| e.to_string())?;
        self.wbuf.clear();
        Ok(())
    }

    fn recv(&mut self) -> Result<Message, String> {
        loop {
            if let Some(m) = Message::parse(&mut self.rbuf).map_err(|e| e.to_string())? {
                return Ok(m);
            }
            let mut tmp = [0u8; 8192];
            let n = self.s.read(&mut tmp).map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("postgres closed the connection".into());
            }
            self.rbuf.extend_from_slice(&tmp[..n]);
        }
    }

    /// Consumes messages up to ReadyForQuery; the first ErrorResponse on the way is returned as the error.
    fn until_ready(&mut self) -> Result<(), String> {
        let mut err = None;
        loop {
            match self.recv()? {
                Message::ReadyForQuery(_) => return err.map_or(Ok(()), Err),
                Message::ErrorResponse(body) => {
                    err.get_or_insert_with(|| error_text(&body));
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url() {
        let c = PgConfig::from_url("postgres://conduit:p%40ss@127.0.0.1:5433/conduit_x").unwrap();
        assert_eq!((c.user.as_str(), c.password.as_str(), c.host.as_str(), c.port, c.dbname.as_str()),
                   ("conduit", "p@ss", "127.0.0.1", 5433, "conduit_x"));
        let c = PgConfig::from_url("postgres://u@localhost/db?sslmode=disable").unwrap();
        assert_eq!((c.host.as_str(), c.port, c.dbname.as_str()), ("localhost", 5432, "db"));
    }

    // ---- batching state machine, driven by synthetic backend messages

    fn msg(t: u8, body: &[u8]) -> Vec<u8> {
        let mut v = vec![t];
        v.extend(((body.len() + 4) as i32).to_be_bytes());
        v.extend(body);
        v
    }
    /// One statement's reply: BindComplete, one DataRow, CommandComplete.
    fn ok_stmt() -> Vec<u8> {
        let mut v = msg(b'2', &[]);
        v.extend(msg(b'D', &[0, 1, 0, 0, 0, 1, b'x']));
        v.extend(msg(b'C', b"SELECT 1\0"));
        v
    }
    fn error(code: &str) -> Vec<u8> {
        msg(b'E', format!("SERROR\0VERROR\0C{code}\0Mboom\0\0").as_bytes())
    }
    fn ready() -> Vec<u8> {
        msg(b'Z', b"I")
    }
    fn feed(p: &mut Pipe, bytes: &[u8], done: &mut Vec<(u64, GroupResult)>) -> bool {
        p.rbuf.extend_from_slice(bytes);
        p.parse(done).expect("valid stream")
    }
    /// Syncs in the pending output, then clears it as if sent.
    fn take_syncs(p: &mut Pipe) -> usize {
        let mut syncs = 0;
        let mut b = &p.wbuf[..];
        while b.len() >= 5 {
            let len = i32::from_be_bytes([b[1], b[2], b[3], b[4]]) as usize;
            syncs += (b[0] == b'S') as usize;
            b = &b[1 + len..];
        }
        p.wbuf.clear();
        syncs
    }
    fn read(p: &mut Pipe, tag: u64) {
        p.submit(&[(sql::TAGS, vec![])], tag, false);
    }
    fn write(p: &mut Pipe, tag: u64) {
        p.submit(&[(sql::FOLLOW, vec![P::I64(1), P::Text("u".into())])], tag, true);
    }
    fn tags(done: &[(u64, GroupResult)]) -> Vec<(u64, bool)> {
        done.iter().map(|(t, r)| (*t, r.is_ok())).collect()
    }

    #[test]
    fn read_batch_releases_members_as_they_complete() {
        let mut p = Pipe::new(Policy::Read { cap: 8 });
        let mut done = Vec::new();
        for t in 1..=3 {
            read(&mut p, t);
        }
        p.prepare_send();
        assert_eq!(take_syncs(&mut p), 1);
        assert_eq!(p.stats.batches, 1);
        feed(&mut p, &ok_stmt(), &mut done);
        assert_eq!(tags(&done), [(1, true)], "first member answered before the Sync completes");
        feed(&mut p, &[ok_stmt(), ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(1, true), (2, true), (3, true)]);
        assert_eq!((p.queued(), p.work_us()), (0, 0));
    }

    #[test]
    fn read_batch_cap_closes_the_batch() {
        let mut p = Pipe::new(Policy::Read { cap: 2 });
        for t in 1..=5 {
            read(&mut p, t);
        }
        p.prepare_send();
        assert_eq!(take_syncs(&mut p), 3);
    }

    #[test]
    fn read_batch_error_answers_the_failing_member_and_resends_the_rest() {
        let mut p = Pipe::new(Policy::Read { cap: 8 });
        let mut done = Vec::new();
        for t in 1..=3 {
            read(&mut p, t);
        }
        p.prepare_send();
        take_syncs(&mut p);
        let out = feed(&mut p, &[ok_stmt(), msg(b'2', &[]), error("22021"), ready()].concat(), &mut done);
        assert!(out, "a resend was queued");
        assert_eq!(tags(&done), [(1, true), (2, false)]);
        assert_eq!(take_syncs(&mut p), 1, "member 3 resent alone");
        feed(&mut p, &[ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(1, true), (2, false), (3, true)]);
        assert_eq!((p.queued(), p.work_us(), p.stats.retries), (0, 0, 1));
    }

    #[test]
    fn write_batch_waits_for_commit_and_holds_new_writes() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        let mut done = Vec::new();
        for t in 1..=3 {
            write(&mut p, t);
        }
        assert_eq!(p.held(), 3);
        p.prepare_send();
        assert_eq!(take_syncs(&mut p), 1);
        write(&mut p, 4);
        write(&mut p, 5);
        p.prepare_send();
        assert_eq!(take_syncs(&mut p), 0, "nothing goes out while a batch is in flight");
        feed(&mut p, &[ok_stmt(), ok_stmt(), ok_stmt()].concat(), &mut done);
        assert!(done.is_empty(), "write results wait for the commit");
        let out = feed(&mut p, &ready(), &mut done);
        assert_eq!(tags(&done), [(1, true), (2, true), (3, true)]);
        assert!(out && p.held() == 0, "held writes released at ReadyForQuery");
        assert_eq!(take_syncs(&mut p), 1);
        feed(&mut p, &[ok_stmt(), ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(done.len(), 5);
        assert_eq!((p.queued(), p.work_us()), (0, 0));
    }

    #[test]
    fn write_batch_error_resends_rolled_back_members_before_held_ones() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        let mut done = Vec::new();
        for t in 1..=3 {
            write(&mut p, t);
        }
        p.prepare_send();
        take_syncs(&mut p);
        write(&mut p, 9);
        let out = feed(&mut p, &[ok_stmt(), msg(b'2', &[]), error("23503"), ready()].concat(), &mut done);
        assert!(out);
        assert_eq!(tags(&done), [(2, false)], "only the failing member is answered");
        assert_eq!(take_syncs(&mut p), 2, "members 1 and 3 resent alone");
        assert_eq!(p.held(), 1, "held write waits for the resends");
        feed(&mut p, &[ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(p.held(), 1);
        let out = feed(&mut p, &[ok_stmt(), ready()].concat(), &mut done);
        assert!(out && p.held() == 0);
        feed(&mut p, &[ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(2, false), (1, true), (3, true), (9, true)]);
        assert_eq!((p.queued(), p.work_us()), (0, 0));
    }

    #[test]
    fn deadlock_is_retried_once() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        let mut done = Vec::new();
        write(&mut p, 1);
        p.prepare_send();
        take_syncs(&mut p);
        assert!(feed(&mut p, &[msg(b'2', &[]), error("40P01"), ready()].concat(), &mut done));
        assert!(done.is_empty());
        assert_eq!(take_syncs(&mut p), 1);
        feed(&mut p, &[msg(b'2', &[]), error("40P01"), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(1, false)]);
        assert_eq!(done[0].1.as_ref().err().map(|e| e.code.as_str()), Some("40P01"));
    }

    #[test]
    fn error_at_commit_does_not_resend_forever() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        let mut done = Vec::new();
        write(&mut p, 1);
        write(&mut p, 2);
        p.prepare_send();
        take_syncs(&mut p);
        feed(&mut p, &[ok_stmt(), ok_stmt(), error("23514"), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(2, false)], "blamed on the last member");
        assert_eq!(take_syncs(&mut p), 1, "the rolled-back first member resent once");
        feed(&mut p, &[ok_stmt(), error("23514"), ready()].concat(), &mut done);
        assert_eq!(tags(&done), [(2, false), (1, false)]);
        assert_eq!(take_syncs(&mut p), 0);
    }

    #[test]
    fn solo_groups_never_share_a_sync() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        let mut done = Vec::new();
        write(&mut p, 1);
        p.submit(&[(sql::USER_INSERT, vec![P::Text("a".into()), P::Text("b".into()), P::Text("c".into())])], 2, true);
        write(&mut p, 3);
        p.prepare_send();
        assert_eq!(take_syncs(&mut p), 1);
        assert_eq!(p.sent.back().map(|s| s.members.len()), Some(1), "batch stops before the solo group");
        feed(&mut p, &[ok_stmt(), ready()].concat(), &mut done);
        assert_eq!(p.sent.back().map(|s| s.members[0].tag), Some(2));
        let mut r = Pipe::new(Policy::Read { cap: 8 });
        r.submit(&[(sql::USER_UPDATE, vec![P::I64(1), P::Null, P::Null, P::Null, P::Null, P::Null])], 7, false);
        read(&mut r, 8);
        r.prepare_send();
        assert_eq!(take_syncs(&mut r), 2);
    }

    #[test]
    fn read_on_write_connection_goes_out_alone() {
        let mut p = Pipe::new(Policy::Write { cap: 32 });
        write(&mut p, 1);
        p.prepare_send();
        take_syncs(&mut p);
        read(&mut p, 2);
        assert_eq!(p.held(), 0);
        assert_eq!(take_syncs(&mut p), 1);
    }

    #[test]
    fn connection_loss_answers_every_group_once() {
        let mut p = Pipe::new(Policy::Write { cap: 2 });
        let mut done = Vec::new();
        for t in 1..=5 {
            write(&mut p, t);
        }
        p.prepare_send(); // 1,2 in flight; 3,4,5 held
        feed(&mut p, &[ok_stmt()].concat(), &mut done);
        p.fail_all(&mut done, "lost");
        let mut seen: Vec<u64> = done.iter().map(|d| d.0).collect();
        seen.sort();
        assert_eq!(seen, [1, 2, 3, 4, 5]);
        assert!(done.iter().all(|d| d.1.is_err()));
        assert_eq!((p.queued(), p.work_us(), p.held()), (0, 0, 0));

        let mut r = Pipe::new(Policy::Read { cap: 8 });
        let mut done = Vec::new();
        for t in 1..=3 {
            read(&mut r, t);
        }
        r.prepare_send();
        feed(&mut r, &ok_stmt(), &mut done); // member 1 answered
        read(&mut r, 4); // open batch
        r.fail_all(&mut done, "lost");
        assert_eq!(tags(&done), [(1, true), (2, false), (3, false), (4, false)]);
        assert_eq!((r.queued(), r.work_us()), (0, 0));
    }

    #[test]
    fn statements_have_matching_params() {
        for (i, st) in STATEMENTS.iter().enumerate() {
            let max = (1..=9).rev().find(|n| st.sql.contains(&format!("${n}"))).unwrap_or(0);
            assert_eq!(max, st.params.len(), "s{i}: {}", st.sql);
        }
    }
}
