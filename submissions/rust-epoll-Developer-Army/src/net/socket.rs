//! Low-level socket options, resource limit elevation, and non-blocking I/O routines.

use std::net::SocketAddr;
use std::os::unix::io::RawFd;

pub fn elevate_nofile_limit() {
    unsafe {
        let mut rlim = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rlim) == 0 {
            rlim.rlim_cur = rlim.rlim_max.max(1_048_576);
            libc::setrlimit(libc::RLIMIT_NOFILE, &rlim);
        }
    }
}

pub fn configure_client_socket(fd: RawFd) {
    unsafe {
        // Non-blocking
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        // TCP_NODELAY
        let one: libc::c_int = 1;
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_NODELAY,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of_val(&one) as libc::socklen_t,
        );

        // TCP_QUICKACK
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_QUICKACK,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of_val(&one) as libc::socklen_t,
        );

        // Compact buffer sizes to support 400K concurrent sockets within memory budget
        let rcvbuf: libc::c_int = 4096;
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &rcvbuf as *const _ as *const libc::c_void,
            std::mem::size_of_val(&rcvbuf) as libc::socklen_t,
        );

        let sndbuf: libc::c_int = 8192;
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            &sndbuf as *const _ as *const libc::c_void,
            std::mem::size_of_val(&sndbuf) as libc::socklen_t,
        );
    }
}

pub fn create_listener(addr: SocketAddr) -> Result<RawFd, String> {
    unsafe {
        let domain = if addr.is_ipv4() { libc::AF_INET } else { libc::AF_INET6 };
        let fd = libc::socket(domain, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err("Failed to create socket".to_string());
        }

        let one: libc::c_int = 1;
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_REUSEADDR,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of_val(&one) as libc::socklen_t,
        );
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_REUSEPORT,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of_val(&one) as libc::socklen_t,
        );

        // TCP_DEFER_ACCEPT: only wake epoll when data arrives
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_DEFER_ACCEPT,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of_val(&one) as libc::socklen_t,
        );

        let (sockaddr_ptr, socklen) = match addr {
            SocketAddr::V4(ref v4) => {
                let mut sa: libc::sockaddr_in = std::mem::zeroed();
                sa.sin_family = libc::AF_INET as libc::sa_family_t;
                sa.sin_port = v4.port().to_be();
                sa.sin_addr.s_addr = u32::from_ne_bytes(v4.ip().octets());
                (
                    &sa as *const _ as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            }
            SocketAddr::V6(ref v6) => {
                let mut sa: libc::sockaddr_in6 = std::mem::zeroed();
                sa.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                sa.sin6_port = v6.port().to_be();
                sa.sin6_addr.s6_addr = v6.ip().octets();
                (
                    &sa as *const _ as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
                )
            }
        };

        if libc::bind(fd, sockaddr_ptr, socklen) < 0 {
            libc::close(fd);
            return Err("Failed to bind socket".to_string());
        }

        if libc::listen(fd, 32768) < 0 {
            libc::close(fd);
            return Err("Failed to listen on socket".to_string());
        }

        Ok(fd)
    }
}
