//! Finished responses travel back to the IO thread that owns the client socket.
//!
//! A `Reply` is the right to answer one request. It must be used exactly once: if it is dropped unanswered (a bug,
//! a lost database connection mid-group, a panic unwinding past it) it answers 500 itself, so no client is left
//! waiting for its timeout.

use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, Debug)]
pub struct Addr {
    pub thread: u16,
    pub slot: u32,
    pub generation: u32,
}

pub struct Response {
    pub to: Addr,
    pub status: u16,
    pub body: Vec<u8>,
}

struct Outbox {
    queue: Mutex<Vec<Response>>,
    efd: i32,
}

static OUTBOXES: OnceLock<Vec<Outbox>> = OnceLock::new();

pub fn init(threads: usize) -> Vec<i32> {
    let v: Vec<Outbox> = (0..threads)
        .map(|_| {
            let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
            assert!(efd >= 0, "eventfd");
            Outbox { queue: Mutex::new(Vec::with_capacity(1024)), efd }
        })
        .collect();
    let fds = v.iter().map(|o| o.efd).collect();
    if OUTBOXES.set(v).is_err() {
        panic!("reply::init twice");
    }
    fds
}

/// Takes every queued response for IO thread `t`.
pub fn drain(t: usize, out: &mut Vec<Response>) {
    let ob = &OUTBOXES.get().expect("reply::init")[t];
    let mut efd_buf = 0u64;
    unsafe { libc::read(ob.efd, &mut efd_buf as *mut u64 as *mut libc::c_void, 8) };
    std::mem::swap(&mut *ob.queue.lock().unwrap(), out);
}

fn push_many(t: usize, rs: &mut Vec<Response>) {
    let ob = &OUTBOXES.get().expect("reply::init")[t];
    let was_empty = {
        let mut q = ob.queue.lock().unwrap();
        let e = q.is_empty();
        q.append(rs);
        e
    };
    if was_empty {
        let one: u64 = 1;
        unsafe { libc::write(ob.efd, &one as *const u64 as *const libc::c_void, 8) };
    }
}

/// The obligation to answer one request.
pub struct Reply {
    to: Option<Addr>,
}

impl Reply {
    pub fn new(to: Addr) -> Reply {
        Reply { to: Some(to) }
    }
    pub fn take(mut self, status: u16, body: Vec<u8>) -> Response {
        Response { to: self.to.take().expect("reply used twice"), status, body }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        if let Some(to) = self.to.take() {
            push_many(to.thread as usize, &mut vec![Response { to, status: 500, body: error_body("internal error") }]);
        }
    }
}

/// Collects responses and hands them over per IO thread, one wakeup each.
#[derive(Default)]
pub struct Batch {
    per: Vec<Vec<Response>>,
}

impl Batch {
    pub fn add(&mut self, r: Response) {
        let t = r.to.thread as usize;
        if self.per.len() <= t {
            self.per.resize_with(t + 1, Vec::new);
        }
        self.per[t].push(r);
    }
    pub fn send(&mut self, reply: Reply, status: u16, body: Vec<u8>) {
        self.add(reply.take(status, body));
    }
    pub fn error(&mut self, reply: Reply, status: u16, msg: &str) {
        self.add(reply.take(status, error_body(msg)));
    }
    pub fn flush(&mut self) {
        for (t, rs) in self.per.iter_mut().enumerate() {
            if !rs.is_empty() {
                push_many(t, rs);
            }
        }
    }
}

impl Drop for Batch {
    fn drop(&mut self) {
        self.flush();
    }
}

pub fn error_body(msg: &str) -> Vec<u8> {
    let mut b = Vec::with_capacity(32 + msg.len());
    b.extend_from_slice(b"{\"errors\":{\"body\":[");
    crate::json::string(&mut b, msg.as_bytes());
    b.extend_from_slice(b"]}}");
    b
}
