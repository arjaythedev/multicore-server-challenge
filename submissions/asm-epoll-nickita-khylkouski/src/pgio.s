# pgio.s: the worker's Postgres connections. Each connection pipelines: ops (requests, batches, BEGIN/COMMIT)
# append their messages to the connection's output buffer and join its FIFO; replies are matched to ops in
# order, one op per ReadyForQuery. Output is flushed once per event-loop iteration (pgio_flush_dirty).
.include "defs.inc"
.include "app.inc"

.equ PG_BUF_INIT, 65536

.section .rodata
DEFSTR .Lmsg_connect, "[db] connect failed, retrying: "
DEFSTR .Lmsg_nodb, "fatal: could not connect to Postgres\n"
DEFSTR .Lmsg_lost, "[db] connection lost\n"
DEFSTR .Lmsg_back, "[db] reconnected\n"
DEFSTR .Lmsg_pgerr, "[db] error: "
DEFSTR .Lmsg_nl, "\n"


.text

# pgio_open(kind) -> rax = pgconn: connect (retrying for 50 s while Postgres starts), session settings, prepare
# every statement, switch to non-blocking and register with the worker's epoll. Dies on failure.
.globl pgio_open
pgio_open:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call rt_mono_ms
    lea r13, [rax + 50000]               # deadline
.Lpo_retry:
    lea rdi, [rip + g_pgcfg]
    call pg_connect
    test rax, rax
    jns .Lpo_connected
    mov rdx, rax
    lea rdi, [rip + .Lmsg_connect]
    mov esi, .Lmsg_connect_len
    call rt_log_num
    call rt_mono_ms
    cmp rax, r13
    jge .Lpo_die
    sub rsp, 16                          # timespec 0.5 s
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 500000000
    mov rdi, rsp
    xor esi, esi
    SYS SYS_nanosleep
    add rsp, 16
    jmp .Lpo_retry
.Lpo_connected:
    mov ebx, eax                         # fd
    mov edi, ebx
    call sql_prepare_all
    test rax, rax
    js .Lpo_die
    test r12, r12
    jnz 1f
    mov edi, ebx
    call readb_prepare                   # read conns: the batched statements too (readb.s)
    test rax, rax
    js .Lpo_die
1:
    mov edi, ebx
    mov esi, F_GETFL
    SYS SYS_fcntl
    mov edx, eax
    or edx, O_NONBLOCK
    mov edi, ebx
    mov esi, F_SETFL
    SYS SYS_fcntl
    # the struct
    mov edi, PC_SIZE
    call rt_alloc
    mov r13, rax
    mov rdi, rax
    xor eax, eax
    mov ecx, PC_SIZE / 8
    rep stosq
    mov dword ptr [r13 + PC_TYPE], OT_PG
    mov [r13 + PC_FD], ebx
    mov [r13 + PC_KIND], r12
    mov edi, PG_BUF_INIT
    call rt_alloc
    mov [r13 + PC_OUT + PGB_PTR], rax
    mov [r13 + PC_OUT + PGB_CAP], rdx
    mov edi, PG_BUF_INIT
    call rt_alloc
    mov [r13 + PC_IN], rax
    mov [r13 + PC_INCAP], rdx
    # epoll: edge-triggered in + out
    sub rsp, 16
    mov dword ptr [rsp], EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET
    mov [rsp + 4], r13
    mov rdi, [r15 + W_EPFD]
    mov esi, EPOLL_CTL_ADD
    mov edx, ebx
    mov r10, rsp
    SYS SYS_epoll_ctl
    add rsp, 16
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    ret
.Lpo_die:
    lea rdi, [rip + .Lmsg_nodb]
    mov esi, .Lmsg_nodb_len
    call rt_die

# pgio_event(pc, events): epoll readiness for a Postgres connection.
.globl pgio_event
pgio_event:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz 1f
    test r12d, EPOLLOUT
    jz 2f
    mov rax, [rbx + PC_OUT + PGB_LEN]
    cmp rax, [rbx + PC_OUTSENT]
    je 2f
    mov rdi, rbx
    call pgio_flush
2:  test r12d, EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLRDHUP
    jz 1f
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz 1f
    mov rdi, rbx
    call pgio_read
    # Postgres closed the connection (a terminated backend): pgio_read stops at the short read before the
    # EOF, and an idle connection gets no further event, so it is down now
    test r12d, EPOLLERR | EPOLLHUP | EPOLLRDHUP
    jz 1f
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz 1f
    mov rdi, rbx
    call pgio_dead
1:  add rsp, 8
    pop r12
    pop rbx
    ret
    .skip 37, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# pgio_read(pc): read everything available and dispatch complete replies.
pgio_read:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
.Lpr_loop:
    # make room: compact consumed bytes away, then grow if less than a quarter is free
    mov rax, [rbx + PC_INCAP]
    sub rax, [rbx + PC_INLEN]
    mov rcx, [rbx + PC_INCAP]
    shr rcx, 2
    cmp rax, rcx
    jae .Lpr_read
    mov rdi, rbx
    call pgio_compact
    mov rax, [rbx + PC_INCAP]
    sub rax, [rbx + PC_INLEN]
    mov rcx, [rbx + PC_INCAP]
    shr rcx, 2
    cmp rax, rcx
    jae .Lpr_read
    mov rdi, [rbx + PC_IN]
    mov rsi, [rbx + PC_INLEN]
    mov rdx, [rbx + PC_INCAP]
    lea rcx, [rdx + rdx]
    call rt_grow
    mov [rbx + PC_IN], rax
    mov [rbx + PC_INCAP], rdx
.Lpr_read:
    mov edi, [rbx + PC_FD]
    mov rsi, [rbx + PC_IN]
    add rsi, [rbx + PC_INLEN]
    mov rdx, [rbx + PC_INCAP]
    sub rdx, [rbx + PC_INLEN]
    mov r12, rdx                         # requested
    xor r10d, r10d                       # recvfrom: no VFS layer, unlike read()
    xor r8d, r8d
    SYS SYS_recvfrom
    test rax, rax
    jg .Lpr_got
    cmp rax, -EINTR
    je .Lpr_read
    cmp rax, -EAGAIN
    je .Lpr_done
    mov rdi, rbx                         # EOF or error
    call pgio_dead
    jmp .Lpr_ret
.Lpr_got:
    add [rbx + PC_INLEN], rax
    push rax
    push rax
    mov rdi, rbx
    call pgio_dispatch
    pop rax
    pop rax
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz .Lpr_ret
    cmp rax, r12
    je .Lpr_loop                         # filled the buffer: there may be more
.Lpr_done:
    mov rdi, rbx
    call pgio_compact
.Lpr_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# pgio_compact(pc): move the unprocessed input to the start of the buffer.
pgio_compact:
    mov rax, [rdi + PC_INPOS]
    test rax, rax
    jz 1f
    push rbx
    mov rbx, rdi
    mov rdx, [rbx + PC_INLEN]
    sub rdx, rax
    mov rsi, [rbx + PC_IN]
    add rsi, rax
    mov rdi, [rbx + PC_IN]
    call rt_memcpy
    mov rax, [rbx + PC_INPOS]
    sub [rbx + PC_INLEN], rax
    sub [rbx + PC_SCAN], rax
    mov qword ptr [rbx + PC_INPOS], 0
    pop rbx
1:  ret

# pgio_dispatch(pc): walk complete messages; each ReadyForQuery completes the FIFO head op with its segment.
pgio_dispatch:
    push rbx
    push r12
    push r13
    mov rbx, rdi
.Lpd_loop:
    mov rdi, [rbx + PC_IN]
    add rdi, [rbx + PC_SCAN]
    mov rsi, [rbx + PC_INLEN]
    sub rsi, [rbx + PC_SCAN]
    jz .Lpd_ret
    call pgr_next
    test rax, rax
    jz .Lpd_ret
    add [rbx + PC_SCAN], rdx
    cmp al, 'Z'
    jne .Lpd_loop
    # pop the head op
    mov r12, [rbx + PC_QHEAD]
    mov rsi, [rbx + PC_IN]
    add rsi, [rbx + PC_INPOS]            # segment start
    mov rdx, [rbx + PC_SCAN]
    sub rdx, [rbx + PC_INPOS]            # segment length
    mov rax, [rbx + PC_SCAN]
    mov [rbx + PC_INPOS], rax
    test r12, r12
    jz .Lpd_loop                         # nobody waiting (should not happen)
    mov rax, [r12 + OP_NEXT]
    mov [rbx + PC_QHEAD], rax
    test rax, rax
    jnz 1f
    mov qword ptr [rbx + PC_QTAIL], 0
1:  dec qword ptr [rbx + PC_NQ]
    jnz 2f
    cmp qword ptr [rbx + PC_KIND], 0
    jne 2f
    push rsi                             # a read connection just went idle: give it its next take and send it
    push rdx                             # now, so Postgres runs it while this reply is rendered
    call readb_service
    call pgio_flush_dirty
    pop rdx
    pop rsi
2:  mov rdi, r12
    call [r12 + OP_CONT]
    jmp .Lpd_loop
.Lpd_ret:
    pop r13
    pop r12
    pop rbx
    ret

# pgio_dead(pc): the connection failed: close it and fail every waiting op (cont(op, 0, -1)).
.globl pgio_dead
pgio_dead:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz .Lpx_fail
    or qword ptr [rbx + PC_FLAGS], PCF_DEAD
    inc qword ptr [r15 + W_NDEAD]        # the event loop reconnects it (pgio_revive_due)
    mov edi, [rbx + PC_FD]
    SYS SYS_close
    lea rdi, [rip + .Lmsg_lost]
    mov esi, .Lmsg_lost_len
    call rt_log
.Lpx_fail:
    mov r12, [rbx + PC_QHEAD]
    test r12, r12
    jz .Lpx_ret
    mov rax, [r12 + OP_NEXT]
    mov [rbx + PC_QHEAD], rax
    dec qword ptr [rbx + PC_NQ]
    mov rdi, r12
    xor esi, esi
    mov rdx, -1
    call [r12 + OP_CONT]
    jmp .Lpx_fail
.Lpx_ret:
    mov qword ptr [rbx + PC_QTAIL], 0
    mov qword ptr [rbx + PC_OUT + PGB_LEN], 0    # output for failed ops is never sent
    mov qword ptr [rbx + PC_OUTSENT], 0
    add rsp, 8
    pop r12
    pop rbx
    ret
    .skip 41, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# pgio_reserve(pc, n): make sure the output buffer has n free bytes.
.globl pgio_reserve
pgio_reserve:
    mov rax, [rdi + PC_OUT + PGB_CAP]
    sub rax, [rdi + PC_OUT + PGB_LEN]
    cmp rax, rsi
    jae 1f
    push rbx
    mov rbx, rdi
    mov rcx, [rbx + PC_OUT + PGB_LEN]
    add rcx, rsi
    mov rdi, [rbx + PC_OUT + PGB_PTR]
    mov rsi, [rbx + PC_OUT + PGB_LEN]
    mov rdx, [rbx + PC_OUT + PGB_CAP]
    call rt_grow
    mov [rbx + PC_OUT + PGB_PTR], rax
    mov [rbx + PC_OUT + PGB_CAP], rdx
    pop rbx
1:  ret

# pgio_enqueue(pc, op): op waits for the next unclaimed ReadyForQuery; schedule a flush. On a dead connection
# the op fails at once (its continuation runs before this returns), so callers enqueue as their last step.
.globl pgio_enqueue
pgio_enqueue:
    mov qword ptr [rsi + OP_NEXT], 0
    mov rax, [rdi + PC_QTAIL]
    test rax, rax
    jz 1f
    mov [rax + OP_NEXT], rsi
    jmp 2f
1:  mov [rdi + PC_QHEAD], rsi
2:  mov [rdi + PC_QTAIL], rsi
    inc qword ptr [rdi + PC_NQ]
    test qword ptr [rdi + PC_FLAGS], PCF_DEAD
    jnz 3f
    # fall through to mark dirty
.globl pgio_mark_dirty
pgio_mark_dirty:
    test qword ptr [rdi + PC_FLAGS], PCF_DIRTY
    jnz 4f
    or qword ptr [rdi + PC_FLAGS], PCF_DIRTY
    mov rax, [r15 + W_DIRTY]
    mov [rdi + PC_DIRTY_NEXT], rax
    mov [r15 + W_DIRTY], rdi
4:  ret
3:  jmp pgio_dead                       # dead connection: fail the op (and any others) right away

# pgio_flush(pc): write pending output; stops at EAGAIN (EPOLLOUT resumes it).
.globl pgio_flush
pgio_flush:
    push rbx
    mov rbx, rdi
.Lpf_loop:
    mov rdx, [rbx + PC_OUT + PGB_LEN]
    sub rdx, [rbx + PC_OUTSENT]
    jz .Lpf_all
    mov edi, [rbx + PC_FD]
    mov rsi, [rbx + PC_OUT + PGB_PTR]
    add rsi, [rbx + PC_OUTSENT]
    xor r10d, r10d                       # sendto: no VFS layer, unlike write()
    xor r8d, r8d
    SYS SYS_sendto
    test rax, rax
    jle .Lpf_err
    add [rbx + PC_OUTSENT], rax
    jmp .Lpf_loop
.Lpf_all:
    mov qword ptr [rbx + PC_OUT + PGB_LEN], 0
    mov qword ptr [rbx + PC_OUTSENT], 0
    pop rbx
    ret
.Lpf_err:
    cmp rax, -EINTR
    je .Lpf_loop
    cmp rax, -EAGAIN
    je .Lpf_ret
    mov rdi, rbx
    call pgio_dead
.Lpf_ret:
    pop rbx
    ret
    .skip 58, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# pgio_flush_dirty(): flush every connection that got output this iteration.
.globl pgio_flush_dirty
pgio_flush_dirty:
    push rbx
.Lfd_loop:
    mov rbx, [r15 + W_DIRTY]
    test rbx, rbx
    jz .Lfd_ret
    mov rax, [rbx + PC_DIRTY_NEXT]
    mov [r15 + W_DIRTY], rax
    and qword ptr [rbx + PC_FLAGS], ~PCF_DIRTY
    test qword ptr [rbx + PC_FLAGS], PCF_DEAD
    jnz .Lfd_loop
    mov rdi, rbx
    call pgio_flush
    jmp .Lfd_loop
.Lfd_ret:
    pop rbx
    ret

# pgio_put_job(pc, job): Bind/Execute/Sync for the job's statement and params (J_STMT, J_NP, J_PT, J_P).
.globl pgio_put_job
pgio_put_job:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov rbx, rdi
    mov r12, rsi
    # size bound: 64 + per param (len + 8), arrays: 32 + per element (len + 8)
    mov rsi, 128
    xor ecx, ecx
.Lpj_size:
    cmp rcx, [r12 + J_NP]
    jae .Lpj_sized
    mov rax, rcx
    shl rax, 4
    mov rdx, [r12 + J_P + rax + 8]
    cmp byte ptr [r12 + J_PT + rcx], PT_TEXTARR
    jne 1f
    mov r8, [r12 + J_P + rax]            # pairs
    xor r9d, r9d
2:  cmp r9, rdx
    jae 3f
    mov r10, r9
    shl r10, 4
    mov r10, [r8 + r10 + 8]
    lea rsi, [rsi + r10 + 8]
    inc r9
    jmp 2b
3:  add rsi, 32
    jmp 4f
1:  test rdx, rdx
    js 4f
    lea rsi, [rsi + rdx]
4:  add rsi, 8
    inc rcx
    jmp .Lpj_size
.Lpj_sized:
    mov rdi, rbx
    call pgio_reserve
    lea r13, [rbx + PC_OUT]              # the pgbuf
    mov rdi, r13
    lea rsi, [rip + sql_names]
    mov rax, [r12 + J_STMT]
    lea rsi, [rsi + rax*4]
    mov edx, 3
    mov rcx, [r12 + J_NP]
    call pgw_bind_begin
    mov rbp, rax                         # bind handle
    xor r14d, r14d
.Lpj_param:
    cmp r14, [r12 + J_NP]
    jae .Lpj_end
    mov rax, r14
    shl rax, 4
    mov rsi, [r12 + J_P + rax]
    mov rdx, [r12 + J_P + rax + 8]
    movzx ecx, byte ptr [r12 + J_PT + r14]
    cmp ecx, PT_TEXTARR
    je .Lpj_arr
    test rdx, rdx
    js .Lpj_null
    mov rdi, r13
    cmp ecx, PT_INT8
    je .Lpj_int
    call pgw_param_text
    jmp .Lpj_next
.Lpj_int:
    call pgw_param_int8
    jmp .Lpj_next
.Lpj_null:
    mov rdi, r13
    call pgw_param_null
    jmp .Lpj_next
.Lpj_arr:
    push rsi                             # pairs
    push rdx                             # count
    mov rdi, r13
    mov esi, OID_TEXT
    call pgw_array_begin
    pop rdx
    pop rsi
    push rbx                             # (rbx is reloaded from the stack below)
    push rax                             # array handle
    mov rbx, rsi
    lea r8, [rdx]
    shl r8, 4
    add r8, rsi                          # end of pairs
    push r8
    push r8                              # keep alignment: 4 pushes
.Lpj_elem:
    cmp rbx, [rsp]
    jae .Lpj_arr_end
    mov rdi, r13
    mov rsi, [rsp + 16]                  # handle
    mov rdx, [rbx]
    mov rcx, [rbx + 8]
    call pgw_array_text
    add rbx, 16
    jmp .Lpj_elem
.Lpj_arr_end:
    mov rsi, [rsp + 16]
    add rsp, 24
    pop rbx
    mov rdi, r13
    call pgw_array_end
.Lpj_next:
    inc r14
    jmp .Lpj_param
.Lpj_end:
    mov rdi, r13
    mov rsi, rbp
    call pgw_bind_end
    mov rdi, r13
    call pgw_execute
    mov rdi, r13
    call pgw_sync
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- reply segments

# seg_scan(seg, len) -> rax = first DataRow message (0 if none), rdx = SQLSTATE of the first ErrorResponse
# (0 if none), rcx = number of DataRows. Unexpected errors (anything but 23505) are logged.
.globl seg_scan
seg_scan:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov rbx, rdi
    lea r12, [rdi + rsi]                 # end
    xor r13d, r13d                       # first row
    xor r14d, r14d                       # sqlstate
    xor ebp, ebp                         # rows
.Lss_loop:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    jz .Lss_ret
    call pgr_next
    test rax, rax
    jz .Lss_ret
    cmp al, 'D'
    jne 1f
    test r13, r13
    jnz 2f
    mov r13, rbx
2:  inc rbp
    jmp 3f
1:  cmp al, 'E'
    jne 3f
    test r14, r14
    jnz 3f
    push rdx
    push rdx
    mov rdi, rbx
    call pgr_error_sqlstate
    mov r14, rax
    mov rdi, rbx
    call seg_log_error
    pop rdx
    pop rdx
3:  add rbx, rdx
    jmp .Lss_loop
.Lss_ret:
    mov rax, r13
    mov rdx, r14
    mov rcx, rbp
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# seg_next_row(p, end) -> rax = the next DataRow at or after p (0 if none), rdx = its length.
.globl seg_next_row
seg_next_row:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
.Lsn_loop:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    jle .Lsn_none
    call pgr_next
    test rax, rax
    jz .Lsn_none
    cmp al, 'D'
    je .Lsn_found
    add rbx, rdx
    jmp .Lsn_loop
.Lsn_found:
    mov rax, rbx
    jmp .Lsn_ret
.Lsn_none:
    xor eax, eax
    xor edx, edx
.Lsn_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# seg_log_error(msg): log an ErrorResponse's message to stderr unless it is a unique violation (23505).
seg_log_error:
    push rbx
    sub rsp, 32
    mov rbx, rdi
    call pgr_error_sqlstate
    mov rcx, 0x3530353332                # "23505" little-endian packed
    cmp rax, rcx
    je 1f
    mov rdi, rbx
    lea rsi, [rsp]
    lea rdx, [rsp + 8]
    call pgr_error_message
    lea rdi, [rip + .Lmsg_pgerr]
    mov esi, .Lmsg_pgerr_len
    call rt_log
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    cmp rsi, 2000
    jbe 2f
    mov esi, 2000
2:  call rt_log
    lea rdi, [rip + .Lmsg_nl]
    mov esi, 1
    call rt_log
1:  add rsp, 32
    pop rbx
    ret

# pgio_revive(pc) -> rax = 0, or < 0 if Postgres is still unreachable: reconnect a dead connection in place (the
# same struct, so W_RDS / W_WR stay valid). Its FIFO is empty: pgio_dead failed every op.
pgio_revive:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea rdi, [rip + g_pgcfg]
    call pg_connect
    test rax, rax
    js .Lpv_ret
    mov r12d, eax
    mov edi, r12d
    call sql_prepare_all
    test rax, rax
    js .Lpv_close
    cmp qword ptr [rbx + PC_KIND], 0
    jne 1f
    mov edi, r12d
    call readb_prepare
    test rax, rax
    js .Lpv_close
1:  mov edi, r12d
    mov esi, F_GETFL
    SYS SYS_fcntl
    mov edx, eax
    or edx, O_NONBLOCK
    mov edi, r12d
    mov esi, F_SETFL
    SYS SYS_fcntl
    xor eax, eax
    mov [rbx + PC_OUT + PGB_LEN], rax
    mov [rbx + PC_OUTSENT], rax
    mov [rbx + PC_INLEN], rax
    mov [rbx + PC_INPOS], rax
    mov [rbx + PC_SCAN], rax
    sub rsp, 16
    mov dword ptr [rsp], EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET
    mov [rsp + 4], rbx
    mov rdi, [r15 + W_EPFD]
    mov esi, EPOLL_CTL_ADD
    mov edx, r12d
    mov r10, rsp
    SYS SYS_epoll_ctl
    add rsp, 16
    test rax, rax
    js .Lpv_close                        # not watched, so its replies would never be read: stay dead
    mov [rbx + PC_FD], r12d
    and qword ptr [rbx + PC_FLAGS], ~PCF_DEAD
    lea rdi, [rip + .Lmsg_back]
    mov esi, .Lmsg_back_len
    call rt_log
    xor eax, eax
    jmp .Lpv_ret
.Lpv_close:
    mov r13, rax
    mov edi, r12d
    SYS SYS_close
    mov rax, r13
.Lpv_ret:
    pop r13
    pop r12
    pop rbx
    ret

# pgio_revive_due(): called by the event loop while W_NDEAD > 0. At most every 500 ms, reconnect the dead
# connections (write conn first); stop at the first failure and try again next time.
.globl pgio_revive_due
pgio_revive_due:
    push rbx
    push r12
    sub rsp, 8
    call rt_mono_ms
    cmp rax, [r15 + W_RETRY]
    jl .Lrv_ret
    add rax, 500
    mov [r15 + W_RETRY], rax
    mov r12, -1                          # -1 = the write conn, then read conns 0..W_NRD-1
.Lrv_next:
    mov rdi, [r15 + W_WR]
    test r12, r12
    js 1f
    cmp r12, [r15 + W_NRD]
    jae .Lrv_ret
    mov rdi, [r15 + W_RDS + r12*8]
1:  inc r12
    test qword ptr [rdi + PC_FLAGS], PCF_DEAD
    jz .Lrv_next
    call pgio_revive
    test rax, rax
    js .Lrv_ret
    dec qword ptr [r15 + W_NDEAD]
    jmp .Lrv_next
.Lrv_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

    .skip 48, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

.section .note.GNU-stack,"",@progbits
