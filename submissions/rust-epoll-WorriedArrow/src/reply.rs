//! Routing finished responses back to the IO thread that owns the client socket.

use std::sync::Mutex;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug)]
pub struct ReplyTo {
    pub thread: u16,
    pub slot: u32,
    pub generation: u32,
}

pub struct Response {
    pub to: ReplyTo,
    pub status: u16,
    pub body: Vec<u8>,
}

pub struct Outbox {
    pub queue: Mutex<Vec<Response>>,
    pub efd: i32,
}

static OUTBOXES: OnceLock<Vec<Outbox>> = OnceLock::new();

pub fn init(threads: usize) {
    let v = (0..threads)
        .map(|_| {
            let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
            assert!(efd >= 0, "eventfd");
            Outbox { queue: Mutex::new(Vec::with_capacity(1024)), efd }
        })
        .collect();
    OUTBOXES.set(v).ok().expect("reply::init twice");
}

pub fn outbox(thread: usize) -> &'static Outbox {
    &OUTBOXES.get().expect("reply::init")[thread]
}

fn wake(efd: i32) {
    let one: u64 = 1;
    unsafe {
        libc::write(efd, &one as *const u64 as *const libc::c_void, 8);
    }
}

pub fn send(to: ReplyTo, status: u16, body: Vec<u8>) {
    let ob = outbox(to.thread as usize);
    let was_empty = {
        let mut q = ob.queue.lock().unwrap();
        let e = q.is_empty();
        q.push(Response { to, status, body });
        e
    };
    if was_empty {
        wake(ob.efd);
    }
}

/// Sends many responses, waking each IO thread at most once.
pub fn send_all(rs: Vec<Response>) {
    let n = OUTBOXES.get().map(|v| v.len()).unwrap_or(0);
    let mut per: Vec<Vec<Response>> = (0..n).map(|_| Vec::new()).collect();
    for r in rs {
        per[r.to.thread as usize].push(r);
    }
    for (t, mut rs) in per.into_iter().enumerate() {
        if rs.is_empty() {
            continue;
        }
        let ob = outbox(t);
        let was_empty = {
            let mut q = ob.queue.lock().unwrap();
            let e = q.is_empty();
            q.append(&mut rs);
            e
        };
        if was_empty {
            wake(ob.efd);
        }
    }
}

pub fn error_body(msg: &str) -> Vec<u8> {
    let mut b = Vec::with_capacity(40 + msg.len());
    b.extend_from_slice(b"{\"errors\":{\"body\":[");
    crate::json::str(&mut b, msg.as_bytes());
    b.extend_from_slice(b"]}}");
    b
}

pub fn error(to: ReplyTo, status: u16, msg: &str) -> Response {
    Response { to, status, body: error_body(msg) }
}
