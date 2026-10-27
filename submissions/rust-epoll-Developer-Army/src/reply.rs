//! Routing finished responses back to client sockets with direct write fast-path.

use std::os::fd::RawFd;
use std::sync::Mutex;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug)]
pub struct ReplyTo {
    pub thread: u16,
    pub slot: u32,
    pub generation: u32,
    pub fd: RawFd,
    pub close_after: bool,
}

pub struct Response {
    pub to: ReplyTo,
    pub status: u16,
    pub body: Vec<u8>,
    pub already_written: usize,
}

impl Response {
    #[inline]
    pub fn new(to: ReplyTo, status: u16, body: Vec<u8>) -> Self {
        Response { to, status, body, already_written: 0 }
    }
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
            Outbox { queue: Mutex::new(Vec::with_capacity(4096)), efd }
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

pub fn status_text(s: u16) -> &'static str {
    match s {
        100 => "100 Continue",
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        413 => "413 Payload Too Large",
        422 => "422 Unprocessable Entity",
        431 => "431 Request Header Fields Too Large",
        _ => "500 Internal Server Error",
    }
}

pub fn format_head(head: &mut [u8; 256], status: u16, body_len: usize, close_after: bool) -> usize {
    let mut pos = 0;
    let st = status_text(status);
    let mut write = |s: &[u8]| {
        head[pos..pos + s.len()].copy_from_slice(s);
        pos += s.len();
    };
    write(b"HTTP/1.1 ");
    write(st.as_bytes());
    write(b"\r\nServer: c\r\n");
    if status == 204 {
        write(b"Content-Length: 0\r\n");
    } else {
        write(b"Content-Type: application/json\r\nContent-Length: ");
        let mut itoa_buf = itoa::Buffer::new();
        write(itoa_buf.format(body_len).as_bytes());
        write(b"\r\n");
    }
    if close_after {
        write(b"Connection: close\r\n\r\n");
    } else {
        write(b"\r\n");
    }
    pos
}

/// Attempts to write the response directly to the socket.
/// If full write succeeds, notifies IO thread or clears connection.
/// If partial or EAGAIN, enqueues to the IO thread.
pub fn direct_send(to: ReplyTo, status: u16, body: Vec<u8>) {
    if to.fd < 0 {
        return;
    }
    let mut head = [0u8; 256];
    let head_len = format_head(&mut head, status, body.len(), to.close_after);
    let total_len = head_len + body.len();

    let iov = [
        libc::iovec { iov_base: head.as_ptr() as *mut libc::c_void, iov_len: head_len },
        libc::iovec { iov_base: body.as_ptr() as *mut libc::c_void, iov_len: body.len() },
    ];
    let n = unsafe { libc::writev(to.fd, iov.as_ptr(), 2) };
    if n >= 0 && n as usize == total_len && !to.close_after {
        // Direct write fast-path completed in full!
        enqueue(to, status, body, total_len);
    } else if n >= 0 {
        enqueue(to, status, body, n as usize);
    } else {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EAGAIN) {
            enqueue(to, status, body, 0);
        } else {
            // EPIPE or ECONNRESET: client disconnected
            enqueue(to, status, body, total_len);
        }
    }
}

fn enqueue(to: ReplyTo, status: u16, body: Vec<u8>, already_written: usize) {
    let ob = outbox(to.thread as usize);
    let was_empty = {
        let mut q = ob.queue.lock().unwrap();
        let e = q.is_empty();
        q.push(Response { to, status, body, already_written });
        e
    };
    if was_empty {
        wake(ob.efd);
    }
}

pub fn send(to: ReplyTo, status: u16, body: Vec<u8>) {
    direct_send(to, status, body);
}

pub fn send_all(rs: Vec<Response>) {
    let n = OUTBOXES.get().map(|v| v.len()).unwrap_or(0);
    let mut per: Vec<Vec<Response>> = (0..n).map(|_| Vec::new()).collect();
    for r in rs {
        per[r.to.thread as usize].push(r);
    }
    for (t, mut batch) in per.into_iter().enumerate() {
        if batch.is_empty() {
            continue;
        }
        let ob = outbox(t);
        let was_empty = {
            let mut q = ob.queue.lock().unwrap();
            let e = q.is_empty();
            q.append(&mut batch);
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
    Response { to, status, body: error_body(msg), already_written: 0 }
}
