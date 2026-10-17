//! HTTP/1.1 framing with buffers held only while work is in flight. Idle sockets retain
//! neither request nor response buffers. Parsing uses httparse; JSON remains in api.rs.
use crate::api;
use http::Method;
use std::{cell::RefCell, io, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 16 * 1024 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(30);
thread_local! { static BUFFERS: RefCell<Vec<Vec<u8>>> = const { RefCell::new(Vec::new()) }; }
pub(crate) fn take() -> Vec<u8> {
    BUFFERS.with(|p| {
        p.borrow_mut()
            .pop()
            .unwrap_or_else(|| Vec::with_capacity(4096))
    })
}
fn release(mut b: Vec<u8>) {
    b.clear();
    if b.capacity() > 0 && b.capacity() <= 64 * 1024 {
        BUFFERS.with(|p| {
            let mut p = p.borrow_mut();
            if p.len() < 64 {
                p.push(b);
            }
        });
    }
}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid HTTP framing")
}
async fn more(s: &mut TcpStream, b: &mut Vec<u8>, max: usize) -> io::Result<()> {
    if b.len() >= max {
        return Err(invalid());
    }
    b.reserve(1024);
    if s.read_buf(b).await? == 0 {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(())
}
async fn through(s: &mut TcpStream, b: &mut Vec<u8>, end: usize) -> io::Result<()> {
    while b.len() < end {
        more(s, b, end).await?;
    }
    Ok(())
}
async fn line(s: &mut TcpStream, b: &mut Vec<u8>, at: usize) -> io::Result<usize> {
    loop {
        if let Some(n) = memchr::memmem::find(&b[at..], b"\r\n") {
            return if n <= MAX_HEAD {
                Ok(at + n)
            } else {
                Err(invalid())
            };
        }
        if b.len() - at > MAX_HEAD {
            return Err(invalid());
        }
        more(s, b, MAX_BODY + MAX_HEAD).await?;
    }
}
fn has_token(value: &[u8], token: &[u8]) -> bool {
    value
        .split(|b| *b == b',')
        .any(|x| x.trim_ascii().eq_ignore_ascii_case(token))
}

pub async fn serve(mut stream: TcpStream) {
    let mut input = Vec::new();
    loop {
        // No allocation until the next request becomes readable.
        if input.is_empty() {
            release(std::mem::take(&mut input));
            if stream.readable().await.is_err() {
                return;
            }
            input = take();
            match stream.try_read_buf(&mut input) {
                Ok(0) => {
                    release(input);
                    return;
                }
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                Err(_) => {
                    release(input);
                    return;
                }
            }
        }
        #[cfg(feature = "boxed-requests")]
        let keep = Box::pin(handle_one(&mut stream, &mut input)).await;
        #[cfg(not(feature = "boxed-requests"))]
        let keep = handle_one(&mut stream, &mut input).await;
        if !matches!(keep, Ok(true)) {
            release(input);
            return;
        }
    }
}

async fn read_request(
    s: &mut TcpStream,
    input: &mut Vec<u8>,
) -> io::Result<(Head, Vec<u8>, usize)> {
    let mut scan = 0;
    loop {
        if memchr::memmem::find(&input[scan..], b"\r\n\r\n").is_some() {
            break;
        }
        if input.len() > MAX_HEAD {
            return Err(invalid());
        }
        scan = input.len().saturating_sub(3);
        more(s, input, MAX_HEAD).await?;
    }
    let parsed = parse_head(input)?;
    let head = parsed.end;
    if parsed.expect {
        s.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").await?;
    }
    let mut decoded = Vec::new();
    let end;
    if parsed.chunked {
        let mut at = head;
        loop {
            let stop = line(s, input, at).await?;
            let size = input[at..stop]
                .split(|b| *b == b';')
                .next()
                .ok_or_else(invalid)?;
            if size.is_empty() || size.len() > 16 || !size.iter().all(|b| b.is_ascii_hexdigit()) {
                return Err(invalid());
            }
            let n = usize::from_str_radix(std::str::from_utf8(size).map_err(|_| invalid())?, 16)
                .map_err(|_| invalid())?;
            at = stop + 2;
            if n == 0 {
                let trailer_start = at;
                loop {
                    let stop = line(s, input, at).await?;
                    if stop == at {
                        at += 2;
                        break;
                    }
                    if stop - trailer_start > MAX_HEAD || !input[at..stop].contains(&b':') {
                        return Err(invalid());
                    }
                    at = stop + 2;
                }
                end = at;
                break;
            }
            if n > MAX_BODY - decoded.len() {
                return Err(invalid());
            }
            let next = at
                .checked_add(n)
                .and_then(|x| x.checked_add(2))
                .ok_or_else(invalid)?;
            through(s, input, next).await?;
            if &input[next - 2..next] != b"\r\n" {
                return Err(invalid());
            }
            decoded.extend_from_slice(&input[at..next - 2]);
            at = next;
            // Release consumed wire framing independently of decoded body size.
            // Keep the request head (target/auth offsets) and any pipelined bytes.
            if at - head >= MAX_HEAD {
                input.drain(head..at);
                at = head;
            }
        }
    } else {
        end = head + parsed.length.unwrap_or(0);
        through(s, input, end).await?;
    }
    Ok((parsed, decoded, end))
}

async fn handle_one(s: &mut TcpStream, input: &mut Vec<u8>) -> io::Result<bool> {
    // Idle keep-alive is unlimited; completion is bounded once a request starts.
    // The timer ends before database/CPU work and cannot cancel a mutation.
    let (head, decoded, end) = tokio::time::timeout(READ_TIMEOUT, read_request(s, input))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "request read deadline"))??;
    let Head {
        method,
        target: target_range,
        auth,
        chunked,
        close,
        end: head,
        ..
    } = head;
    let target = std::str::from_utf8(&input[target_range]).map_err(|_| invalid())?;
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (target, None),
    };
    let auth = api::Auth(auth.map(|r| &input[r]));
    let body = if chunked {
        &decoded[..]
    } else {
        &input[head..end]
    };
    let resp = api::route(&method, path, query, auth, body)
        .await
        .unwrap_or_else(api::error_response);
    // Serialize headers and body once, then reuse the output allocation for the write.
    let mut output = take();
    output.extend_from_slice(b"HTTP/1.1 ");
    output.extend_from_slice(itoa::Buffer::new().format(resp.status).as_bytes());
    output.extend_from_slice(b" OK\r\nContent-Type: application/json\r\n");
    if resp.status != 204 {
        output.extend_from_slice(b"Content-Length: ");
        output.extend_from_slice(itoa::Buffer::new().format(resp.body.len()).as_bytes());
        output.extend_from_slice(b"\r\n");
    }
    output.extend_from_slice(if close {
        b"Connection: close\r\n\r\n"
    } else {
        b"\r\n"
    });
    let payload = if method == Method::HEAD || resp.status == 204 {
        &[][..]
    } else {
        &resp.body
    };
    let written = write_response(s, &output, payload).await;
    release(output);
    release(resp.body);
    written?;
    input.drain(..end);
    Ok(!close)
}

struct Head {
    method: Method,
    target: std::ops::Range<usize>,
    auth: Option<std::ops::Range<usize>>,
    length: Option<usize>,
    chunked: bool,
    expect: bool,
    close: bool,
    end: usize,
}
// Keep parser scratch space off the idle connection future.
fn parse_head(input: &[u8]) -> io::Result<Head> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut req = httparse::Request::new(&mut headers);
    let head = match req.parse(input).map_err(|_| invalid())? {
        httparse::Status::Complete(n) if n <= MAX_HEAD => n,
        _ => return Err(invalid()),
    };
    let method =
        Method::from_bytes(req.method.ok_or_else(invalid)?.as_bytes()).map_err(|_| invalid())?;
    // Offsets allow the backing buffer to grow while a request body arrives.
    let target = req.path.ok_or_else(invalid)?;
    let target_range = (target.as_ptr() as usize - input.as_ptr() as usize)
        ..(target.as_ptr() as usize - input.as_ptr() as usize + target.len());
    let mut auth = None;
    let mut length = None;
    let mut chunked = false;
    let mut expect = false;
    let mut close = req.version != Some(1);
    for h in req.headers.iter() {
        if h.name.eq_ignore_ascii_case("content-length") {
            if length.is_some() {
                return Err(invalid());
            }
            let v = std::str::from_utf8(h.value).map_err(|_| invalid())?;
            let n = crate::parse_uint(v).ok_or_else(invalid)? as usize;
            if n > MAX_BODY {
                return Err(invalid());
            }
            length = Some(n);
        } else if h.name.eq_ignore_ascii_case("transfer-encoding") {
            if chunked || !h.value.eq_ignore_ascii_case(b"chunked") {
                return Err(invalid());
            }
            chunked = true;
        } else if h.name.eq_ignore_ascii_case("authorization") {
            if auth.is_some() {
                return Err(invalid());
            }
            let start = h.value.as_ptr() as usize - input.as_ptr() as usize;
            auth = Some(start..start + h.value.len());
        } else if h.name.eq_ignore_ascii_case("connection") {
            if has_token(h.value, b"close") {
                close = true;
            } else if req.version == Some(0) && has_token(h.value, b"keep-alive") {
                close = false;
            }
        } else if h.name.eq_ignore_ascii_case("expect") {
            if !h.value.eq_ignore_ascii_case(b"100-continue") {
                return Err(invalid());
            }
            expect = true;
        }
    }
    if length.is_some() && chunked {
        return Err(invalid());
    }
    Ok(Head {
        method,
        target: target_range,
        auth,
        length,
        chunked,
        expect,
        close,
        end: head,
    })
}

async fn write_response(s: &TcpStream, mut head: &[u8], mut body: &[u8]) -> io::Result<()> {
    while !head.is_empty() || !body.is_empty() {
        s.writable().await?;
        match s.try_write_vectored(&[io::IoSlice::new(head), io::IoSlice::new(body)]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) if n < head.len() => head = &head[n..],
            Ok(n) => {
                body = &body[n - head.len()..];
                head = &[];
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    #[tokio::test]
    #[ignore]
    async fn future_sizes() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut stream = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let mut input = Vec::new();
        eprintln!(
            "active request future: {} bytes",
            std::mem::size_of_val(&handle_one(&mut stream, &mut input))
        );
        eprintln!(
            "idle connection future: {} bytes",
            std::mem::size_of_val(&serve(stream))
        );
    }
    #[tokio::test]
    async fn chunk_framing_compacts_and_preserves_pipeline() {
        let payload = vec![b'x'; 3 * 1024 * 1024];
        let mut wire = b"POST /api/example HTTP/1.1\r\nTransfer-Encoding: chunked\r\nAuthorization: Token example\r\n\r\n".to_vec();
        for b in &payload {
            wire.extend_from_slice(&[b'1', b'\r', b'\n', *b, b'\r', b'\n']);
        }
        let pipeline = b"GET /api/tags HTTP/1.1\r\n\r\n";
        wire.extend_from_slice(b"0\r\nX-Trailer: present\r\n\r\n");
        wire.extend_from_slice(pipeline);
        for segment in [4096, 7777] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut client = TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            let (mut server, _) = listener.accept().await.unwrap();
            let bytes = wire.clone();
            let sender = tokio::spawn(async move {
                for part in bytes.chunks(segment) {
                    client.write_all(part).await.unwrap();
                    tokio::task::yield_now().await;
                }
            });
            let mut input = Vec::new();
            let (head, body, end) = read_request(&mut server, &mut input).await.unwrap();
            assert_eq!(body, payload);
            assert_eq!(&input[head.target], b"/api/example");
            assert_eq!(&input[head.auth.unwrap()], b"Token example");
            assert!(input.len() < 128 * 1024);
            input.drain(..end);
            through(&mut server, &mut input, pipeline.len())
                .await
                .unwrap();
            assert_eq!(input, pipeline);
            sender.await.unwrap();
        }
    }
    #[test]
    fn reject_ambiguous_framing() {
        for head in [
            "POST /api/users HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nContent-Length: +2\r\n\r\n",
        ] {
            assert!(parse_head(head.as_bytes()).is_err());
        }
    }
    #[test]
    fn preserve_empty_authorization() {
        let b = b"GET /api/articles HTTP/1.1\r\nAuthorization:\r\n\r\n";
        let h = parse_head(b).unwrap();
        assert_eq!(h.auth.map(|r| &b[r]), Some(&b""[..]));
    }
}
