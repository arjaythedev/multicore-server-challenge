//! A TCP forwarder in front of Postgres whose connections the test can cut, to simulate a dropped connection.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

pub struct CuttableProxy {
    pub port: u16,
    open: Arc<Mutex<Vec<TcpStream>>>,
}

impl CuttableProxy {
    /// Forwards 127.0.0.1:<port> to `upstream`.
    pub fn start(upstream: &'static str) -> CuttableProxy {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let open: Arc<Mutex<Vec<TcpStream>>> = Arc::default();
        let registry = Arc::clone(&open);
        std::thread::spawn(move || {
            for client in listener.incoming().flatten() {
                let Ok(server) = TcpStream::connect(upstream) else {
                    continue;
                };
                let _ = (client.set_nodelay(true), server.set_nodelay(true));
                if let (Ok(c2), Ok(s2)) = (client.try_clone(), server.try_clone()) {
                    registry
                        .lock()
                        .unwrap()
                        .extend([client.try_clone().unwrap(), server.try_clone().unwrap()]);
                    std::thread::spawn(move || pump(client, server));
                    std::thread::spawn(move || pump(s2, c2));
                }
            }
        });
        CuttableProxy { port, open }
    }

    /// Closes every connection that exists now. New connections still work.
    pub fn cut(&self) {
        for stream in self.open.lock().unwrap().drain(..) {
            let _ = stream.shutdown(Shutdown::Both);
        }
    }
}

fn pump(mut from: TcpStream, mut to: TcpStream) {
    let mut buf = [0u8; 16 * 1024];
    while let Ok(n) = from.read(&mut buf) {
        if n == 0 || to.write_all(&buf[..n]).is_err() {
            break;
        }
    }
    let _ = to.shutdown(Shutdown::Both);
}
