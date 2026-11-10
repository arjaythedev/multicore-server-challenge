//! Epoll-based event loop reactor with direct non-blocking write fast-path.

use std::collections::VecDeque;
use std::os::unix::io::RawFd;
use super::socket::configure_client_socket;

pub struct Connection {
    pub fd: RawFd,
    pub read_buf: Vec<u8>,
    pub write_buf: Vec<u8>,
    pub keep_alive: bool,
}

impl Connection {
    pub fn new(fd: RawFd) -> Self {
        Connection {
            fd,
            read_buf: Vec::with_capacity(1024),
            write_buf: Vec::new(),
            keep_alive: true,
        }
    }
}

pub struct PendingWrite {
    pub fd: RawFd,
    pub data: Vec<u8>,
    pub keep_alive: bool,
}

pub struct Reactor {
    pub epoll_fd: RawFd,
    pub listen_fd: RawFd,
    pub connections: Vec<Option<Connection>>,
    pub outgoing_queue: VecDeque<PendingWrite>,
}

impl Reactor {
    pub fn new(listen_fd: RawFd) -> Result<Self, String> {
        let epoll_fd = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
        if epoll_fd < 0 {
            return Err("epoll_create1 failed".to_string());
        }

        let mut ev = libc::epoll_event {
            events: (libc::EPOLLIN | libc::EPOLLEXCLUSIVE) as u32,
            u64: listen_fd as u64,
        };
        unsafe {
            if libc::epoll_ctl(epoll_fd, libc::EPOLL_CTL_ADD, listen_fd, &mut ev) < 0 {
                libc::close(epoll_fd);
                return Err("Failed to add listener to epoll".to_string());
            }
        }

        Ok(Reactor {
            epoll_fd,
            listen_fd,
            connections: Vec::new(),
            outgoing_queue: VecDeque::new(),
        })
    }

    pub fn accept_connection(&mut self) -> Option<RawFd> {
        unsafe {
            let client_fd = libc::accept4(
                self.listen_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            );
            if client_fd < 0 {
                return None;
            }

            configure_client_socket(client_fd);

            let ufd = client_fd as usize;
            if ufd >= self.connections.len() {
                self.connections.resize_with(ufd + 1024, || None);
            }

            let mut ev = libc::epoll_event {
                events: (libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLERR | libc::EPOLLHUP) as u32,
                u64: client_fd as u64,
            };

            if libc::epoll_ctl(self.epoll_fd, libc::EPOLL_CTL_ADD, client_fd, &mut ev) == 0 {
                self.connections[ufd] = Some(Connection::new(client_fd));
                Some(client_fd)
            } else {
                libc::close(client_fd);
                None
            }
        }
    }

    pub fn close_connection(&mut self, fd: RawFd) {
        let ufd = fd as usize;
        unsafe {
            let mut ev: libc::epoll_event = std::mem::zeroed();
            libc::epoll_ctl(self.epoll_fd, libc::EPOLL_CTL_DEL, fd, &mut ev);
            libc::close(fd);
        }
        if ufd < self.connections.len() {
            self.connections[ufd] = None;
        }
    }

    /// Fast path direct socket write: writes directly to fd if possible.
    /// If partial or EAGAIN, enqueues to write buffer and registers EPOLLOUT.
    pub fn send_response(&mut self, fd: RawFd, data: &[u8], keep_alive: bool) {
        let ufd = fd as usize;
        if ufd >= self.connections.len() || self.connections[ufd].is_none() {
            return;
        }

        let conn = self.connections[ufd].as_mut().unwrap();
        conn.keep_alive = keep_alive;

        if conn.write_buf.is_empty() {
            // Direct write attempt
            let n = unsafe {
                libc::send(
                    fd,
                    data.as_ptr() as *const libc::c_void,
                    data.len(),
                    libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
                )
            };

            if n >= 0 {
                let sent = n as usize;
                if sent == data.len() {
                    if !keep_alive {
                        self.close_connection(fd);
                    }
                    return;
                } else {
                    conn.write_buf.extend_from_slice(&data[sent..]);
                }
            } else {
                let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if err == libc::EAGAIN || err == libc::EWOULDBLOCK {
                    conn.write_buf.extend_from_slice(data);
                } else {
                    self.close_connection(fd);
                    return;
                }
            }
        } else {
            conn.write_buf.extend_from_slice(data);
        }

        // Register EPOLLOUT
        let mut ev = libc::epoll_event {
            events: (libc::EPOLLIN | libc::EPOLLOUT | libc::EPOLLRDHUP | libc::EPOLLERR | libc::EPOLLHUP) as u32,
            u64: fd as u64,
        };
        unsafe {
            libc::epoll_ctl(self.epoll_fd, libc::EPOLL_CTL_MOD, fd, &mut ev);
        }
    }

    pub fn handle_writable(&mut self, fd: RawFd) {
        let ufd = fd as usize;
        if ufd >= self.connections.len() || self.connections[ufd].is_none() {
            return;
        }

        let conn = self.connections[ufd].as_mut().unwrap();
        if conn.write_buf.is_empty() {
            return;
        }

        let n = unsafe {
            libc::send(
                fd,
                conn.write_buf.as_ptr() as *const libc::c_void,
                conn.write_buf.len(),
                libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
            )
        };

        if n > 0 {
            let sent = n as usize;
            if sent == conn.write_buf.len() {
                conn.write_buf.clear();
                if !conn.keep_alive {
                    self.close_connection(fd);
                    return;
                }
                // Switch back to read-only interest
                let mut ev = libc::epoll_event {
                    events: (libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLERR | libc::EPOLLHUP) as u32,
                    u64: fd as u64,
                };
                unsafe {
                    libc::epoll_ctl(self.epoll_fd, libc::EPOLL_CTL_MOD, fd, &mut ev);
                }
            } else {
                conn.write_buf.drain(..sent);
            }
        } else if n < 0 {
            let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if err != libc::EAGAIN && err != libc::EWOULDBLOCK {
                self.close_connection(fd);
            }
        }
    }
}
