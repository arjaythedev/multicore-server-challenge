# server.s: a worker thread: its epoll loop, the listening socket, client connections (read, parse, respond,
# park partial writes for EPOLLOUT) and the bcrypt completion eventfd.
#
# Client sockets are edge-triggered (in + out + rdhup, registered once). A connection holds an input buffer
# only while request bytes are pending and an output buffer only while a response is partly sent. Requests on
# one connection run one at a time, in order (pipelined requests wait in the input buffer).
.include "defs.inc"
.include "app.inc"

.equ IN_INIT, 4096
.equ ACCEPT_BURST, 256
.equ ACCEPT_BACKOFF_MS, 10                # pause after a failed accept4, as Rust's 10 ms back-off

.section .rodata
DEFSTR .Lmsg_listen, "[server] listening\n"
DEFSTR .Lmsg_bind, "fatal: could not bind the listening socket, errno "
DEFSTR .Lmsg_listenf, "fatal: could not listen on the bound socket, errno "
DEFSTR .Lmsg_wfail, "fatal: worker setup failed\n"


.text

# worker_main(worker): never returns.
.globl worker_main
worker_main:
    mov r15, rdi
    sub rsp, 8                           # align (entered with rsp 8 mod 16)
    mov edi, EV_BATCH * 12
    call rt_alloc
    mov [r15 + W_EVENTS], rax
    mov edi, 0x80000                     # EPOLL_CLOEXEC
    SYS SYS_epoll_create1
    test rax, rax
    js .Lwm_fail
    mov [r15 + W_EPFD], rax
    xor edi, edi
    mov esi, EFD_NONBLOCK | EFD_CLOEXEC
    SYS SYS_eventfd2
    test rax, rax
    js .Lwm_fail
    mov [r15 + W_EVFD], rax
    mov rdi, rax
    mov esi, EPOLLIN
    mov edx, TAG_EVENTFD
    call epoll_add

    # bind the listening socket before any Postgres socket exists: with a wide ip_local_port_range, an
    # ephemeral port picked by a Postgres connect could otherwise be the listen port (listen() comes later)
    call listen_open
    mov [r15 + W_LFD], rax

    # Postgres connections: read conns, then the write conn
    xor ebx, ebx
.Lwm_pg:
    cmp rbx, [rip + g_nread]
    jae .Lwm_pg_done
    xor edi, edi
    call pgio_open
    mov [rax + PC_IDX], rbx
    mov [r15 + W_RDS + rbx*8], rax
    inc rbx
    jmp .Lwm_pg
.Lwm_pg_done:
    mov [r15 + W_NRD], rbx
    mov edi, 1
    call pgio_open
    mov [r15 + W_WR], rax
    call wr_init                         # group-commit batch-delay timer
    mov qword ptr [r15 + W_TURN], 0
    mov qword ptr [r15 + W_GZ], 0
    cmp qword ptr [rip + g_egmode], EG_OFF
    je 1f
    mov edi, GZ_CTX_SIZE
    call rt_alloc                        # a 2^k block: 64-byte aligned
    mov [r15 + W_GZ], rax
    mov rdi, rax
    call gzip_init
1:

    mov edi, [r15 + W_LFD]
    mov esi, 16384
    SYS SYS_listen
    test rax, rax
    js .Lwm_listen_fail
    mov rdi, [r15 + W_LFD]
    mov esi, EPOLLIN
    mov edx, TAG_LISTEN
    call epoll_add
    cmp qword ptr [r15 + W_ID], 0
    jne .Lwm_loop
    lea rdi, [rip + .Lmsg_listen]
    mov esi, .Lmsg_listen_len
    call rt_log

.Lwm_loop:
    mov qword ptr [r15 + W_RDNOW], -1
    cmp qword ptr [r15 + W_RDDUE], 0
    je 1f
    call rt_mono_ms_v                    # a read take is deferred (READ_BATCH_MS): wake at its deadline
    mov rcx, [r15 + W_RDDUE]
    sub rcx, rax
    jg 2f
    xor ecx, ecx
2:  mov [r15 + W_RDNOW], rcx
1:  mov rdi, [r15 + W_EPFD]
    mov rsi, [r15 + W_EVENTS]
    mov edx, EV_BATCH
    mov r10, -1
    cmp qword ptr [r15 + W_NDEAD], 0
    je 1f
    mov r10d, 250                        # a Postgres connection is down: wake up to reconnect it
1:  cmp qword ptr [r15 + W_ACCOFF], 0
    je 1f
    mov r10d, ACCEPT_BACKOFF_MS          # accepting is paused: wake up to resume it
1:  cmp r10, [r15 + W_RDNOW]
    jbe 1f
    mov r10, [r15 + W_RDNOW]
1:  SYS SYS_epoll_wait
    test rax, rax
    jg 2f
    mov rcx, [r15 + W_NDEAD]
    or rcx, [r15 + W_ACCOFF]
    or rcx, [r15 + W_RDDUE]
    jz .Lwm_loop                         # EINTR (or nothing)
    xor eax, eax
2:  mov r14, rax                         # events
    call rt_now_sec
    mov [r15 + W_NOW], rax
    mov r12, [r15 + W_EVENTS]
    xor r13d, r13d
.Lwm_ev:
    cmp qword ptr [r15 + W_DONE], 0
    jne .Lwm_drain
.Lwm_ev1:
    cmp r13, r14
    jae .Lwm_revive
    lea rax, [r13 + r13*2]
    lea rax, [r12 + rax*4]               # event i (12 bytes, packed)
    mov esi, [rax]
    mov rdi, [rax + 4]
    inc r13
    cmp rdi, TAG_LISTEN
    je .Lwm_accept
    cmp rdi, TAG_EVENTFD
    je .Lwm_done
    cmp rdi, TAG_TIMER
    je .Lwm_timer
    cmp dword ptr [rdi], OT_PG
    je .Lwm_pg_ev
    call client_event
    jmp .Lwm_ev
.Lwm_pg_ev:
    call pgio_event
    jmp .Lwm_ev
.Lwm_accept:
    call srv_accept
    jmp .Lwm_ev
.Lwm_done:
    call srv_completions
    jmp .Lwm_ev
.Lwm_drain:                              # jobs answered by another worker: resume them between events
    call srv_drain
    jmp .Lwm_ev1
.Lwm_timer:
    call wr_timer
    jmp .Lwm_ev
.Lwm_revive:
    cmp qword ptr [r15 + W_ACCOFF], 0
    je 1f
    call srv_accept_resume
1:  cmp qword ptr [r15 + W_NDEAD], 0
    je .Lwm_after
    call pgio_revive_due
.Lwm_after:
    # run requests that became ready, then send Postgres output; repeat until both are quiet
    call srv_run_ready
    call wr_service                      # cut the next group-commit unit if the write conn is free
    call readb_service                   # give queued reads to idle read conns (readb.s)
    call pgio_flush_dirty
    cmp qword ptr [r15 + W_READY], 0
    jne .Lwm_after
    call srv_bury
    jmp .Lwm_loop
.Lwm_fail:
    lea rdi, [rip + .Lmsg_wfail]
    mov esi, .Lmsg_wfail_len
    call rt_die
.Lwm_listen_fail:
    lea rdi, [rip + .Lmsg_listenf]
    mov esi, .Lmsg_listenf_len
    jmp srv_die_errno
    .skip 48, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# epoll_add(fd, events, data)
.globl epoll_add
epoll_add:
    sub rsp, 24
    mov [rsp], esi
    mov [rsp + 4], rdx
    mov edx, edi
    mov rdi, [r15 + W_EPFD]
    mov esi, EPOLL_CTL_ADD
    mov r10, rsp
    SYS SYS_epoll_ctl
    add rsp, 24
    ret

# listen_open() -> rax = a socket bound to g_addr:g_port with SO_REUSEADDR + SO_REUSEPORT (one per worker; the
# caller listen()s once its Postgres connections are up).
listen_open:
    push rbx
    sub rsp, 32
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js .Llo_fail
    mov ebx, eax
    mov dword ptr [rsp + 16], 1
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea r10, [rsp + 16]
    mov r8d, 4
    SYS SYS_setsockopt
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEPORT
    lea r10, [rsp + 16]
    mov r8d, 4
    SYS SYS_setsockopt
    # sockaddr_in: family, port (big-endian), addr
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov word ptr [rsp], AF_INET
    mov eax, [rip + g_port]
    xchg al, ah
    mov [rsp + 2], ax
    mov eax, [rip + g_addr]
    mov [rsp + 4], eax
    mov edi, ebx
    mov rsi, rsp
    mov edx, 16
    SYS SYS_bind
    test rax, rax
    js .Llo_fail
    mov eax, ebx
    add rsp, 32
    pop rbx
    ret
.Llo_fail:
    lea rdi, [rip + .Lmsg_bind]
    mov esi, .Lmsg_bind_len
    # fall through

# srv_die_errno(msg, len, rax = -errno): "<msg><errno>\n" to stderr, exit 1.
srv_die_errno:
    mov rdx, rax
    neg rdx
    and rsp, -16
    call rt_log_num
    mov edi, 1
    SYS SYS_exit_group

# srv_accept(): accept a burst of connections.
srv_accept:
    push rbx
    push r12
    sub rsp, 24
    xor r12d, r12d
.Lsa_loop:
    cmp r12d, ACCEPT_BURST
    jae .Lsa_ret
    inc r12d
    mov rdi, [r15 + W_LFD]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_NONBLOCK | SOCK_CLOEXEC
    SYS SYS_accept4
    test rax, rax
    js .Lsa_fail
    mov ebx, eax
    mov dword ptr [rsp], 1
    mov edi, ebx
    mov esi, IPPROTO_TCP
    mov edx, TCP_NODELAY
    mov r10, rsp
    mov r8d, 4
    SYS SYS_setsockopt
    # connection struct
    mov rax, [r15 + W_FREE_CONN]
    test rax, rax
    jz 1f
    mov rcx, [rax + C_NEXT]
    mov [r15 + W_FREE_CONN], rcx
    jmp 2f
1:  mov edi, C_SIZE
    call rt_alloc
2:  mov rdi, rax
    mov rdx, rax
    xor eax, eax
    mov ecx, C_SIZE / 8
    rep stosq
    mov dword ptr [rdx + C_TYPE], OT_CLIENT
    mov [rdx + C_FD], ebx
    mov edi, ebx
    mov esi, EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET
    call epoll_add
    jmp .Lsa_loop
.Lsa_fail:
    cmp rax, -EAGAIN
    je .Lsa_ret
    cmp rax, -EINTR
    je .Lsa_ret
    call srv_accept_pause                # out of descriptors (EMFILE, ENFILE) and the like
.Lsa_ret:
    add rsp, 24
    pop r12
    pop rbx
    ret
    .skip 47, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# client_event(conn, events)
client_event:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    test qword ptr [rbx + C_FLAGS], CF_DEAD
    jnz .Lce_ret
    test r12d, EPOLLOUT
    jz 1f
    cmp qword ptr [rbx + C_OUT], 0
    je 1f
    mov rdi, rbx
    call client_flush
    test qword ptr [rbx + C_FLAGS], CF_DEAD
    jnz .Lce_ret
1:  test r12d, EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR
    jz .Lce_ret
    mov rdi, rbx
    call client_read
.Lce_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# client_read(conn): read what is available (edge-triggered: until a short read or EAGAIN), then start the
# next request if the connection is idle. While a request is in flight its input buffer cannot move (the job
# points into it), so a full buffer then waits (CF_STALL) until the response is sent.
.equ CF_STALL, 16
client_read:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
.Lcr_loop:
    mov rax, [rbx + C_IN]
    test rax, rax
    jnz 1f
    mov edi, IN_INIT
    call rt_alloc
    mov [rbx + C_IN], rax
    mov [rbx + C_INCAP], rdx
    mov qword ptr [rbx + C_INLEN], 0
1:  mov rdx, [rbx + C_INCAP]
    sub rdx, [rbx + C_INLEN]
    jnz .Lcr_read
    # full
    cmp qword ptr [rbx + C_JOB], 0
    jne .Lcr_stall
    mov rcx, [rbx + C_INCAP]
    cmp rcx, MAX_HEAD + MAX_BODY
    jae .Lcr_close                       # larger than any valid request
    mov rdi, [rbx + C_IN]
    mov rsi, [rbx + C_INLEN]
    mov rdx, rcx
    add rcx, rcx
    call rt_grow
    mov [rbx + C_IN], rax
    mov [rbx + C_INCAP], rdx
    jmp 1b
.Lcr_read:
    mov r12, rdx                         # requested
    mov edi, [rbx + C_FD]
    mov rsi, [rbx + C_IN]
    add rsi, [rbx + C_INLEN]
    xor r10d, r10d                       # flags; recvfrom skips the VFS layer read() goes through
    xor r8d, r8d                         # no source address
    SYS SYS_recvfrom
    test rax, rax
    jg .Lcr_got
    jz .Lcr_eof
    cmp rax, -EINTR
    je .Lcr_read
    cmp rax, -EAGAIN
    je .Lcr_done
.Lcr_close:
    mov rdi, rbx
    call client_close
    jmp .Lcr_ret
.Lcr_got:
    add [rbx + C_INLEN], rax
    cmp rax, r12
    je .Lcr_loop                         # filled the space: maybe more
    jmp .Lcr_done
.Lcr_stall:
    or qword ptr [rbx + C_FLAGS], CF_STALL
    jmp .Lcr_done
.Lcr_eof:
    or qword ptr [rbx + C_FLAGS], CF_EOF
.Lcr_done:
    cmp qword ptr [rbx + C_JOB], 0
    jne .Lcr_ret
    cmp qword ptr [rbx + C_OUT], 0
    jne .Lcr_ret
    mov rdi, rbx
    call client_process
.Lcr_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# client_process(conn): the connection is idle (no job, no parked output): parse and start the next request.
# As the Rust read_request, "100 Continue" goes out once per request as soon as its head is complete (even
# when the body is already buffered), and a HEAD request (method bytes exactly "HEAD") is answered with the
# response head only (Content-Length still describes the would-be body).
.section .rodata
.Lcontinue: .ascii "HTTP/1.1 100 Continue\r\n\r\n"
.text
client_process:
    push rbx
    sub rsp, REQ_SIZE + 16                # 8 + 8 + 96 = 112: aligned; [rsp + REQ_SIZE] = parse result
    mov rbx, rdi
    mov rsi, [rbx + C_INLEN]
    test rsi, rsi
    jz .Lcp_empty
    mov rdi, [rbx + C_IN]
    mov rdx, rsp
    call http_parse
    mov [rsp + REQ_SIZE], rax
    test qword ptr [rsp + REQ_FLAGS], REQF_EXPECT
    jz 1f
    test qword ptr [rbx + C_FLAGS], CF_CONT
    jnz 1f
    test rax, rax
    jnz 2f                               # done, or a chunked body that failed after a valid head (Rust: 100, close)
    test qword ptr [rsp + REQ_FLAGS], REQF_HEAD_DONE
    jz 1f
2:  or qword ptr [rbx + C_FLAGS], CF_CONT
.Lcp_cont:
    mov edi, [rbx + C_FD]
    lea rsi, [rip + .Lcontinue]
    mov edx, 25
    xor r10d, r10d
    xor r8d, r8d
    SYS SYS_sendto
    cmp rax, -EINTR
    je .Lcp_cont
    cmp rax, 25
    jne .Lcp_close                       # 25 bytes into an idle socket only fail if the peer is gone
1:  mov rax, [rsp + REQ_SIZE]
    test rax, rax
    js .Lcp_close
    jz .Lcp_partial
    mov [rbx + C_REQEND], rax
    cmp qword ptr [rsp + REQ_METHOD], M_OTHER
    jne 3f
    mov rcx, [rsp + REQ_PATH]            # the target follows "<method> " directly
    mov rdx, rcx
    sub rdx, [rbx + C_IN]
    cmp rdx, 5
    jb 3f
    cmp dword ptr [rcx - 5], 0x44414548  # "HEAD"
    jne 3f
    cmp byte ptr [rcx - 1], ' '
    jne 3f
    cmp rdx, 5
    je 4f
    cmp byte ptr [rcx - 6], 10           # after a skipped empty line
    jne 3f
4:  or qword ptr [rbx + C_FLAGS], CF_HEADM
3:  mov rdi, rbx
    mov rsi, rsp
    call api_request
    jmp .Lcp_ret
.Lcp_empty:
    mov rdi, [rbx + C_IN]
    mov rsi, [rbx + C_INCAP]
    call rt_free
    mov qword ptr [rbx + C_IN], 0
    mov qword ptr [rbx + C_INCAP], 0
.Lcp_partial:
    test qword ptr [rbx + C_FLAGS], CF_EOF
    jz .Lcp_ret
.Lcp_close:
    mov rdi, rbx
    call client_close
.Lcp_ret:
    add rsp, REQ_SIZE + 16
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# srv_respond(job): the job's response is rendered (J_OUT[J_OUTSTART..J_OUTEND]); free the job, consume its
# request bytes and send. The connection becomes ready for its next request once everything is written.
.globl srv_respond
srv_respond:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov r12, rdi                         # job
    mov rbx, [r12 + J_CONN]
    mov r13, [r12 + J_OUT]
    mov r14, [r12 + J_OUTSTART]
    mov rbp, [r12 + J_OUTEND]
    mov qword ptr [rbx + C_JOB], 0
    cmp qword ptr [r12 + J_CLOSE], 0
    je 1f
    or qword ptr [rbx + C_FLAGS], CF_CLOSE
1:  push qword ptr [r12 + J_OUTCAP]
    push qword ptr [r12 + J_OUTCAP]      # [rsp] = output capacity (two pushes keep alignment)
    mov rdi, r12
    call job_free
    test qword ptr [rbx + C_FLAGS], CF_DEAD
    jnz .Lrs_dead
    # consume the request
    mov rdx, [rbx + C_INLEN]
    sub rdx, [rbx + C_REQEND]
    mov [rbx + C_INLEN], rdx
    jz 2f
    mov rdi, [rbx + C_IN]
    mov rsi, rdi
    add rsi, [rbx + C_REQEND]
    call rt_memcpy
2:  mov qword ptr [rbx + C_REQEND], 0
    test qword ptr [rbx + C_FLAGS], CF_HEADM
    jz 4f
    lea rax, [r13 + r14]                 # HEAD: cut the output after the blank line ending the head
3:  cmp dword ptr [rax], 0x0a0d0a0d
    je 5f
    inc rax
    jmp 3b
5:  lea rbp, [rax + 4]
    sub rbp, r13
4:  and qword ptr [rbx + C_FLAGS], ~(CF_CONT | CF_HEADM)
    # send
    lea rsi, [r13 + r14]
    mov rdx, rbp
    sub rdx, r14
.Lrs_write:
    mov edi, [rbx + C_FD]
    xor r10d, r10d                       # flags; sendto skips the VFS layer write() goes through
    xor r8d, r8d                         # no destination address
    SYS SYS_sendto
    cmp rax, -EINTR
    je .Lrs_write_again
    mov rdx, rbp
    sub rdx, r14
    cmp rax, rdx
    je .Lrs_sent
    cmp rax, -EAGAIN
    je .Lrs_park
    test rax, rax
    js .Lrs_err
    add r14, rax
.Lrs_park:
    mov [rbx + C_OUT], r13
    mov [rbx + C_OUTPOS], r14
    mov [rbx + C_OUTEND], rbp
    mov rax, [rsp]
    mov [rbx + C_OUTCAP], rax
    jmp .Lrs_ret
.Lrs_write_again:
    lea rsi, [r13 + r14]
    mov rdx, rbp
    sub rdx, r14
    jmp .Lrs_write
.Lrs_sent:
    mov rdi, r13
    mov rsi, [rsp]
    call rt_free
    mov rdi, rbx
    call client_after_send
    jmp .Lrs_ret
.Lrs_err:
    mov rdi, r13
    mov rsi, [rsp]
    call rt_free
    mov rdi, rbx
    call client_close
    jmp .Lrs_ret
.Lrs_dead:
    # the peer went away while the request ran: drop everything now
    mov rdi, r13
    mov rsi, [rsp]
    call rt_free
    mov rdi, [rbx + C_IN]
    mov rsi, [rbx + C_INCAP]
    call rt_free
    mov qword ptr [rbx + C_IN], 0
    mov rax, [r15 + W_GRAVE]
    mov [rbx + C_NEXT], rax
    mov [r15 + W_GRAVE], rbx
.Lrs_ret:
    add rsp, 16
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# client_after_send(conn): a response went out completely.
client_after_send:
    test qword ptr [rdi + C_FLAGS], CF_CLOSE
    jnz client_close
    cmp qword ptr [rdi + C_INLEN], 0
    jne 1f
    test qword ptr [rdi + C_FLAGS], CF_EOF | CF_STALL
    jnz 1f
    # idle with nothing pending: drop the input buffer
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + C_IN]
    mov rsi, [rbx + C_INCAP]
    call rt_free
    mov qword ptr [rbx + C_IN], 0
    mov qword ptr [rbx + C_INCAP], 0
    pop rbx
    ret
1:  # more to do: queue it for this loop iteration
    test qword ptr [rdi + C_FLAGS], CF_READY
    jnz 2f
    or qword ptr [rdi + C_FLAGS], CF_READY
    mov rax, [r15 + W_READY]
    mov [rdi + C_RNEXT], rax
    mov [r15 + W_READY], rdi
2:  ret

# client_flush(conn): continue a parked response.
client_flush:
    push rbx
    mov rbx, rdi
.Lcf_write:
    mov edi, [rbx + C_FD]
    mov rsi, [rbx + C_OUT]
    add rsi, [rbx + C_OUTPOS]
    mov rdx, [rbx + C_OUTEND]
    sub rdx, [rbx + C_OUTPOS]
    xor r10d, r10d
    xor r8d, r8d
    SYS SYS_sendto
    cmp rax, -EINTR
    je .Lcf_write
    cmp rax, -EAGAIN
    je .Lcf_ret
    test rax, rax
    js .Lcf_err
    add [rbx + C_OUTPOS], rax
    mov rax, [rbx + C_OUTPOS]
    cmp rax, [rbx + C_OUTEND]
    jb .Lcf_write
    mov rdi, [rbx + C_OUT]
    mov rsi, [rbx + C_OUTCAP]
    call rt_free
    mov qword ptr [rbx + C_OUT], 0
    mov rdi, rbx
    call client_after_send
    jmp .Lcf_ret
.Lcf_err:
    mov rdi, rbx
    call client_close
.Lcf_ret:
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# client_close(conn): close the socket. The struct is freed at the end of the loop iteration (events for it may
# still be pending in this batch), or when its in-flight job finishes.
client_close:
    test qword ptr [rdi + C_FLAGS], CF_DEAD
    jnz 2f
    push rbx
    mov rbx, rdi
    or qword ptr [rbx + C_FLAGS], CF_DEAD
    mov edi, [rbx + C_FD]
    SYS SYS_close
    mov rdi, [rbx + C_OUT]
    mov rsi, [rbx + C_OUTCAP]
    call rt_free
    mov qword ptr [rbx + C_OUT], 0
    cmp qword ptr [rbx + C_JOB], 0
    jne 1f                               # srv_respond frees the input and buries the struct
    mov rdi, [rbx + C_IN]
    mov rsi, [rbx + C_INCAP]
    call rt_free
    mov qword ptr [rbx + C_IN], 0
    mov rax, [r15 + W_GRAVE]
    mov [rbx + C_NEXT], rax
    mov [r15 + W_GRAVE], rbx
1:  pop rbx
2:  ret

# srv_run_ready(): start the next request on every connection queued by client_after_send.
srv_run_ready:
    push rbx
.Lrr_loop:
    mov rbx, [r15 + W_READY]
    test rbx, rbx
    jz .Lrr_ret
    mov rax, [rbx + C_RNEXT]
    mov [r15 + W_READY], rax
    and qword ptr [rbx + C_FLAGS], ~CF_READY
    test qword ptr [rbx + C_FLAGS], CF_DEAD
    jnz .Lrr_loop
    cmp qword ptr [rbx + C_JOB], 0
    jne .Lrr_loop
    cmp qword ptr [rbx + C_OUT], 0
    jne .Lrr_loop
    test qword ptr [rbx + C_FLAGS], CF_STALL
    jz 1f
    and qword ptr [rbx + C_FLAGS], ~CF_STALL
    mov rdi, rbx
    call client_read                     # reads, then processes
    jmp .Lrr_loop
1:  mov rdi, rbx
    call client_process
    jmp .Lrr_loop
.Lrr_ret:
    pop rbx
    ret

# srv_bury(): closed connections go back to the free list.
srv_bury:
    mov rax, [r15 + W_GRAVE]
    test rax, rax
    jz 1f
    mov rcx, [rax + C_NEXT]
    mov [r15 + W_GRAVE], rcx
    mov rdx, [r15 + W_FREE_CONN]
    mov [rax + C_NEXT], rdx
    mov [r15 + W_FREE_CONN], rax
    jmp srv_bury
1:  ret

# srv_completions(): bcrypt finished some jobs: resume each (oldest first) with cont(job, 0, 0).
srv_completions:
    push rbx
    push r12
    sub rsp, 24
    mov rdi, [r15 + W_EVFD]
    mov rsi, rsp
    mov edx, 8
    SYS SYS_read
    jmp 4f
# srv_drain(): srv_completions without reading the eventfd (its count only causes one spurious wakeup later).
srv_drain:
    push rbx
    push r12
    sub rsp, 24
4:  xor eax, eax
    xchg rax, [r15 + W_DONE]
    xor r12d, r12d
1:  test rax, rax
    jz 2f
    mov rcx, [rax + J_NEXT]
    mov [rax + J_NEXT], r12
    mov r12, rax
    mov rax, rcx
    jmp 1b
2:  test r12, r12
    jz 3f
    mov rbx, r12
    mov r12, [rbx + J_NEXT]
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call [rbx + J_CONT]
    jmp 2b
3:  add rsp, 24
    pop r12
    pop rbx
    ret

# job_free(job): free a job and its scratch buffer (the output buffer is the caller's business).
.globl job_free
job_free:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + J_SCRALLOC], 0
    je 1f
    mov rdi, [rbx + J_SCR]
    mov rsi, [rbx + J_SCRCAP]
    call rt_free
1:  mov rdi, rbx
    mov esi, J_SIZE
    call rt_free
    pop rbx
    ret

# srv_accept_pause(): accept4 failed with something other than EAGAIN. The listening socket stays readable
# while its backlog is non-empty, so it leaves epoll for ACCEPT_BACKOFF_MS rather than wake this worker over
# and over (at the descriptor limit that spin took a core from Postgres).
srv_accept_pause:
    cmp qword ptr [r15 + W_ACCOFF], 0
    jne 1f
    sub rsp, 8
    call rt_mono_ms
    add rsp, 8
    add rax, ACCEPT_BACKOFF_MS
    mov [r15 + W_ACCOFF], rax
    xor esi, esi
    jmp srv_listen_mod
1:  ret

# srv_accept_resume(): puts the listening socket back in epoll once the pause has passed.
srv_accept_resume:
    sub rsp, 8
    call rt_mono_ms
    add rsp, 8
    cmp rax, [r15 + W_ACCOFF]
    jb 1f
    mov qword ptr [r15 + W_ACCOFF], 0
    mov esi, EPOLLIN
    jmp srv_listen_mod
1:  ret

# srv_listen_mod(events): EPOLL_CTL_MOD of this worker's listening socket.
srv_listen_mod:
    sub rsp, 24
    mov [rsp], esi
    mov qword ptr [rsp + 4], TAG_LISTEN
    mov rdi, [r15 + W_EPFD]
    mov esi, EPOLL_CTL_MOD
    mov edx, [r15 + W_LFD]
    mov r10, rsp
    SYS SYS_epoll_ctl
    add rsp, 24
    ret

    .skip 4, 0xcc                      # padding: keeps the code after this at its previous 64-byte alignment

.section .note.GNU-stack,"",@progbits
