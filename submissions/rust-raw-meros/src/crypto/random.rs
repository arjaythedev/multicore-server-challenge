//! Random bytes from `/dev/urandom`.
//!
//! The file is opened once per process and shared: `Read` is implemented for `&File`, and each `read` is a single
//! syscall on the shared descriptor, so no lock is needed. Failure to open or read is returned as an `io::Error`;
//! nothing here panics. Linux only, which is all the challenge box runs.

use std::fs::File;
use std::io::{self, Read};
use std::sync::OnceLock;

const URANDOM_PATH: &str = "/dev/urandom";

/// The open handle, or the reason it could not be opened (kept as kind + text because `io::Error` is not `Clone`).
static URANDOM: OnceLock<Result<File, (io::ErrorKind, String)>> = OnceLock::new();

/// Fills `buf` with cryptographically secure random bytes.
pub fn fill(buf: &mut [u8]) -> io::Result<()> {
    let handle =
        URANDOM.get_or_init(|| File::open(URANDOM_PATH).map_err(|e| (e.kind(), e.to_string())));
    match handle {
        Ok(file) => {
            let mut reader: &File = file;
            reader.read_exact(buf)
        }
        Err((kind, message)) => Err(io::Error::new(*kind, message.clone())),
    }
}

#[cfg(test)]
mod tests {
    use super::fill;

    #[test]
    fn fills_and_differs() {
        let mut a = [0u8; 32];
        let mut b = [0u8; 32];
        fill(&mut a).unwrap();
        fill(&mut b).unwrap();
        assert_ne!(a, [0u8; 32]);
        assert_ne!(a, b);
    }

    #[test]
    fn empty_buffer_is_fine() {
        fill(&mut []).unwrap();
    }

    #[test]
    fn works_from_many_threads() {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                std::thread::spawn(|| {
                    let mut buf = [0u8; 64];
                    fill(&mut buf).is_ok() && buf != [0u8; 64]
                })
            })
            .collect();
        for handle in handles {
            assert!(handle.join().unwrap());
        }
    }
}
