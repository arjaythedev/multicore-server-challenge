use std::io;
use std::net::{SocketAddr, ToSocketAddrs};
use std::os::fd::RawFd;

pub fn check(ret: i32) -> io::Result<i32> {
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret)
    }
}

fn set_opt(fd: RawFd, level: i32, name: i32, value: i32) -> io::Result<()> {
    let ret = unsafe {
        libc::setsockopt(
            fd,
            level,
            name,
            &value as *const i32 as *const libc::c_void,
            std::mem::size_of::<i32>() as libc::socklen_t,
        )
    };
    check(ret).map(|_| ())
}

pub fn listen(host: &str, port: u16) -> io::Result<RawFd> {
    let addr = (host, port)
        .to_socket_addrs()?
        .find(SocketAddr::is_ipv4)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no ipv4 address"))?;
    let SocketAddr::V4(v4) = addr else {
        unreachable!();
    };
    unsafe {
        let fd = check(libc::socket(
            libc::AF_INET,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        ))?;
        set_opt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, 1)?;
        set_opt(fd, libc::SOL_SOCKET, libc::SO_REUSEPORT, 1)?;
        let sin = libc::sockaddr_in {
            sin_family: libc::AF_INET as libc::sa_family_t,
            sin_port: port.to_be(),
            sin_addr: libc::in_addr {
                s_addr: u32::from(*v4.ip()).to_be(),
            },
            sin_zero: [0; 8],
        };
        check(libc::bind(
            fd,
            &sin as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        ))?;
        check(libc::listen(fd, 65535))?;
        Ok(fd)
    }
}

pub fn accept(listener: RawFd) -> io::Result<RawFd> {
    let fd = unsafe {
        libc::accept4(
            listener,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
        )
    };
    let fd = check(fd)?;
    let _ = set_opt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 1);
    Ok(fd)
}

pub fn epoll_create() -> io::Result<RawFd> {
    check(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })
}

pub fn epoll_add(epfd: RawFd, fd: RawFd, token: u64, events: u32) -> io::Result<()> {
    let mut ev = libc::epoll_event { events, u64: token };
    check(unsafe { libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, fd, &mut ev) }).map(|_| ())
}

pub fn epoll_del(epfd: RawFd, fd: RawFd) {
    let mut ev = libc::epoll_event { events: 0, u64: 0 };
    unsafe {
        libc::epoll_ctl(epfd, libc::EPOLL_CTL_DEL, fd, &mut ev);
    }
}

pub fn epoll_wait_for(
    epfd: RawFd,
    events: &mut [libc::epoll_event],
    timeout: Option<std::time::Duration>,
) -> usize {
    let ts = timeout.map(|d| libc::timespec {
        tv_sec: d.as_secs() as libc::time_t,
        tv_nsec: d.subsec_nanos() as libc::c_long,
    });
    let tsp = ts
        .as_ref()
        .map_or(std::ptr::null(), |t| t as *const libc::timespec);
    let n = unsafe {
        libc::epoll_pwait2(
            epfd,
            events.as_mut_ptr(),
            events.len() as i32,
            tsp,
            std::ptr::null(),
        )
    };
    if n < 0 { 0 } else { n as usize }
}

pub fn eventfd() -> io::Result<RawFd> {
    check(unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) })
}

pub fn eventfd_signal(fd: RawFd) {
    let one: u64 = 1;
    unsafe {
        libc::write(fd, &one as *const u64 as *const libc::c_void, 8);
    }
}

pub fn eventfd_drain(fd: RawFd) {
    let mut v: u64 = 0;
    unsafe {
        libc::read(fd, &mut v as *mut u64 as *mut libc::c_void, 8);
    }
}

pub fn read(fd: RawFd, buf: &mut [u8]) -> io::Result<usize> {
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

pub fn send(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    let n = unsafe {
        libc::send(
            fd,
            buf.as_ptr() as *const libc::c_void,
            buf.len(),
            libc::MSG_NOSIGNAL,
        )
    };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

pub fn send2(fd: RawFd, a: &[u8], b: &[u8]) -> io::Result<usize> {
    let iov = [
        libc::iovec {
            iov_base: a.as_ptr() as *mut libc::c_void,
            iov_len: a.len(),
        },
        libc::iovec {
            iov_base: b.as_ptr() as *mut libc::c_void,
            iov_len: b.len(),
        },
    ];
    let msg = libc::msghdr {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: iov.as_ptr() as *mut libc::iovec,
        msg_iovlen: 2,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
    };
    let n = unsafe { libc::sendmsg(fd, &msg, libc::MSG_NOSIGNAL) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

pub fn close(fd: RawFd) {
    unsafe {
        libc::close(fd);
    }
}
