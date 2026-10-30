# writer.s: durable group commit on the worker's write connection, a port of the Rust writer.rs actor.
#
# Writes (db_write) queue on the write connection. The writer keeps one unit on the connection at a time:
#   - a single write: the job's own Bind/Execute/Sync (autocommit), answered at its ReadyForQuery;
#   - a group of 2..WR_BATCH_MAX writes: BEGIN, each job's Bind/Execute/Sync, COMMIT, all pipelined. Each job's
#     reply segment is copied aside and the jobs are answered only after COMMIT's ReadyForQuery;
#   - a retry pass: if any statement in a group failed, Postgres rolled the whole group back (an error aborts
#     the transaction and COMMIT answers ROLLBACK). Every job then runs again on its own, in order, so that one
#     invalid request cannot reject the others.
# A failed BEGIN or COMMIT (or a dead connection) fails every job in the group: an uncertain commit is never
# retried. The next unit is cut only when the current one has finished, so under load the jobs that queued up
# meanwhile form the next group. When the writer goes to cut a unit and finds exactly one job, it first waits
# WRITE_BATCH_US (default 1000 us; 0 = no wait) on a timerfd, giving concurrent writes a chance to share the
# flush, as Rust does.
#
# Inside a group, a run of 2+ consecutive favorites (or unfavorites, follows, unfollows, new comments) is sent as
# one statement over arrays of the jobs' params (S_*_N, sql.s) instead of one statement per job. Its rows carry
# each job's ordinal in the run, so the reply is split back into one copy per job, shaped as that job's own
# statement would have answered (a job with no row, e.g. an unknown slug, gets a reply with no rows). Only
# consecutive jobs of one type merge, so the order of the group's effects is unchanged. If the merged statement
# fails, the group rolls back and every job retries on its own, as for any failed statement.
.include "defs.inc"
.include "app.inc"

.section .rodata
DEFSTR .Lsql_begin, "BEGIN"
DEFSTR .Lsql_commit, "COMMIT"
DEFSTR .Lmsg_retry, "[db] grouped writes rolled back for isolated retry: "
DEFSTR .Lmsg_tfd, "fatal: timerfd failed\n"

.data
.globl g_wdelay_us
g_wdelay_us: .quad 1000                  # WRITE_BATCH_US (main.s may override)

.text

# wr_init(): create the worker's batch-delay timerfd and register it with epoll (after W_WR is open).
.globl wr_init
wr_init:
    sub rsp, 8
    cmp qword ptr [rip + g_wdelay_us], 0
    je 1f
    mov edi, CLOCK_MONOTONIC
    mov esi, TFD_NONBLOCK | TFD_CLOEXEC
    SYS SYS_timerfd_create
    test rax, rax
    js 2f
    mov [r15 + W_TFD], rax
    mov rdi, rax
    mov esi, EPOLLIN
    mov edx, TAG_TIMER
    call epoll_add
1:  add rsp, 8
    ret
2:  lea rdi, [rip + .Lmsg_tfd]
    mov esi, .Lmsg_tfd_len
    call rt_die

# db_write(job): queue a write on the worker's write connection. Called as the job's last step; the job's
# J_CONT runs once its write is durable (or has failed).
.globl db_write
db_write:
    mov rax, [r15 + W_WR]
    mov qword ptr [rdi + J_WNEXT], 0
    mov rcx, [rax + PC_WPTAIL]
    test rcx, rcx
    jz 1f
    mov [rcx + J_WNEXT], rdi
    jmp 2f
1:  mov [rax + PC_WPEND], rdi
2:  mov [rax + PC_WPTAIL], rdi
    inc qword ptr [rax + PC_WNPEND]
    ret

# wr_timer(): the batch-delay timerfd fired.
.globl wr_timer
wr_timer:
    sub rsp, 8
    mov edi, [r15 + W_TFD]
    mov rsi, rsp                         # drain the 8-byte expiry count
    mov edx, 8
    SYS SYS_read
    mov rax, [r15 + W_WR]
    cmp qword ptr [rax + PC_WTIMER], 1
    jne 1f
    mov qword ptr [rax + PC_WTIMER], 2
1:  add rsp, 8
    ret

# wr_service(): once per event-loop pass, before the Postgres output is flushed: if the connection is free
# and writes are waiting, cut the next unit (after the batch delay when only one is waiting).
.globl wr_service
wr_service:
    push rbx
    mov rbx, [r15 + W_WR]
    cmp qword ptr [rbx + PC_WBUSY], 0
    jne .Lws_ret
    mov rcx, [rbx + PC_WNPEND]
    test rcx, rcx
    jz .Lws_ret
    mov rax, [rbx + PC_WTIMER]
    cmp rax, 2
    je .Lws_go                           # the delay is over: take what has arrived
    cmp rax, 1
    je .Lws_ret                          # still waiting
    cmp rcx, 1
    jne .Lws_go
    mov rax, [rip + g_wdelay_us]
    test rax, rax
    jz .Lws_go
    # arm the timer: itimerspec {interval 0, value us}
    sub rsp, 32
    xor edx, edx
    mov ecx, 1000000
    div rcx                              # rax = seconds, rdx = microseconds
    imul rdx, rdx, 1000
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov edi, [r15 + W_TFD]
    xor esi, esi
    mov rdx, rsp
    xor r10d, r10d
    SYS SYS_timerfd_settime
    add rsp, 32
    mov qword ptr [rbx + PC_WTIMER], 1
    jmp .Lws_ret
.Lws_go:
    mov qword ptr [rbx + PC_WTIMER], 0
    mov rdi, rbx
    call wr_start
.Lws_ret:
    pop rbx
    ret

# wr_start(pc): put the next unit on the write connection (PC_WNPEND > 0, not busy).
wr_start:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov rbx, rdi
    mov qword ptr [rbx + PC_WBUSY], 1
    mov r12, [rbx + PC_WPEND]            # first job
    cmp qword ptr [rbx + PC_WNPEND], 1
    jne .Lst_group
    # a single write: autocommit
    mov qword ptr [rbx + PC_WPEND], 0
    mov qword ptr [rbx + PC_WPTAIL], 0
    mov qword ptr [rbx + PC_WNPEND], 0
    mov rax, [r12 + J_CONT]
    mov [r12 + J_WCONT], rax
    lea rax, [rip + wr_single_done]
    mov [r12 + J_CONT], rax
    mov rdi, rbx
    mov rsi, r12
    call pgio_put_job
    mov rdi, rbx
    mov rsi, r12
    call pgio_enqueue                    # (on a dead connection the job is answered right here)
    jmp .Lst_ret

.Lst_group:
    # detach up to WR_BATCH_MAX jobs
    mov r13, [rbx + PC_WNPEND]
    cmp r13, WR_BATCH_MAX
    jbe 1f
    mov r13d, WR_BATCH_MAX
1:  mov [rbx + PC_GN], r13
    sub [rbx + PC_WNPEND], r13
    mov rax, r12
    mov rcx, r13
2:  dec rcx
    jz 3f
    mov rax, [rax + J_WNEXT]
    jmp 2b
3:  mov rcx, [rax + J_WNEXT]             # rax = last job of the group
    mov qword ptr [rax + J_WNEXT], 0
    mov [rbx + PC_WPEND], rcx
    test rcx, rcx
    jnz 4f
    mov qword ptr [rbx + PC_WPTAIL], 0
4:  mov [rbx + PC_GJOBS], r12
    mov qword ptr [rbx + PC_GERR], 0

    # BEGIN
    mov rdi, rbx
    mov esi, 16
    call pgio_reserve
    lea rdi, [rbx + PC_OUT]
    lea rsi, [rip + .Lsql_begin]
    mov edx, .Lsql_begin_len
    call pgw_query
    lea rax, [rip + wr_begin_done]
    mov [rbx + PC_GBEGIN + OP_CONT], rax
    mov rdi, rbx
    lea rsi, [rbx + PC_GBEGIN]
    call pgio_enqueue

    # the writes, each with its own Sync (inside the transaction a Sync does not commit)
    mov r14, r12
.Lst_job:
    test r14, r14
    jz .Lst_commit
    mov rdi, r14
    call wr_run_len
    cmp rax, 2
    jb 1f
    mov rdi, rbx                         # a run: one merged statement for its jobs
    mov rsi, r14
    mov rdx, rax
    call wr_put_run
    mov r14, rax                         # the job after the run
    jmp .Lst_job
1:  mov rbp, [r14 + J_WNEXT]             # read before enqueueing (a dead connection runs conts at once)
    mov rax, [r14 + J_CONT]
    mov [r14 + J_WCONT], rax
    lea rax, [rip + wr_stash]
    mov [r14 + J_CONT], rax
    mov qword ptr [r14 + J_WSEG], 0
    mov qword ptr [r14 + J_WSEGLEN], 0
    mov rdi, rbx
    mov rsi, r14
    call pgio_put_job
    mov rdi, rbx
    mov rsi, r14
    call pgio_enqueue
    mov r14, rbp
    jmp .Lst_job

.Lst_commit:
    mov rdi, rbx
    mov esi, 16
    call pgio_reserve
    lea rdi, [rbx + PC_OUT]
    lea rsi, [rip + .Lsql_commit]
    mov edx, .Lsql_commit_len
    call pgw_query
    lea rax, [rip + wr_commit_done]
    mov [rbx + PC_GCOMMIT + OP_CONT], rax
    mov rdi, rbx
    lea rsi, [rbx + PC_GCOMMIT]
    call pgio_enqueue
.Lst_ret:
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# wr_run_len(job) -> rax = number of consecutive jobs from `job` on (J_WNEXT) that can merge with it: the same
# mergeable statement with the same param types (int8 / text, none NULL). 0 if `job` cannot merge.
wr_run_len:
    xor eax, eax
    mov rcx, [rdi + J_STMT]
    cmp rcx, S_FAVORITE
    je 1f
    cmp rcx, S_UNFAVORITE
    je 1f
    cmp rcx, S_FOLLOW
    je 1f
    cmp rcx, S_UNFOLLOW
    je 1f
    cmp rcx, S_COMMENT_CREATE
    jne 9f
1:  mov r8, rdi                          # the first job: its param types
    mov r9, [rdi + J_NP]
    test r9, r9
    jz 9f
    cmp r9, 8
    ja 9f
2:  cmp [rdi + J_STMT], rcx
    jne 9f
    cmp [rdi + J_NP], r9
    jne 9f
    xor edx, edx
3:  movzx r10d, byte ptr [rdi + J_PT + rdx]
    cmp r10b, [r8 + J_PT + rdx]
    jne 9f
    cmp r10d, PT_INT8
    je 4f
    cmp r10d, PT_TEXT
    jne 9f
4:  mov r11, rdx
    shl r11, 4
    cmp qword ptr [rdi + J_P + r11 + 8], 0
    jl 9f
    inc rdx
    cmp rdx, r9
    jb 3b
    inc rax
    mov rdi, [rdi + J_WNEXT]
    test rdi, rdi
    jnz 2b
9:  ret

# wr_put_run(pc, job, n) -> rax = the job after the run: Bind/Execute/Sync of the merged statement for the n jobs
# from `job` on (param i = the array of the jobs' param i), queued as one op: the first job, with J_CONT =
# wr_stash_run. Every job keeps its own J_WCONT.
wr_put_run:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 32                          # [rsp] bind handle, [rsp + 8] array handle, [rsp + 16] param
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # set the jobs up and bound the message size: 256 + per job and param 16 + len (an int8 element is 12)
    mov r14, r12
    mov rbp, r13
    mov esi, 256
1:  mov rax, [r14 + J_CONT]
    mov [r14 + J_WCONT], rax
    mov qword ptr [r14 + J_WSEG], 0
    mov qword ptr [r14 + J_WSEGLEN], 0
    xor ecx, ecx
2:  mov rax, rcx
    shl rax, 4
    mov rax, [r14 + J_P + rax + 8]
    lea rsi, [rsi + rax + 16]
    inc rcx
    cmp rcx, [r14 + J_NP]
    jb 2b
    mov r14, [r14 + J_WNEXT]
    dec rbp
    jnz 1b
    mov rbp, r14                         # read before enqueueing (a dead connection runs conts at once)
    mov [r12 + J_WRUN], r13
    lea rax, [rip + wr_stash_run]
    mov [r12 + J_CONT], rax
    mov rdi, rbx
    call pgio_reserve
    # the statement: S_FAVORITE -> S_FAVORITE_N, ...
    mov rax, [r12 + J_STMT]
    mov ecx, S_FAVORITE_N
    cmp rax, S_FAVORITE
    je 3f
    mov ecx, S_UNFAVORITE_N
    cmp rax, S_UNFAVORITE
    je 3f
    mov ecx, S_FOLLOW_N
    cmp rax, S_FOLLOW
    je 3f
    mov ecx, S_UNFOLLOW_N
    cmp rax, S_UNFOLLOW
    je 3f
    mov ecx, S_COMMENT_CREATE_N
3:  lea rdi, [rbx + PC_OUT]
    lea rsi, [rip + sql_names]
    lea rsi, [rsi + rcx*4]
    mov edx, 3
    mov rcx, [r12 + J_NP]
    call pgw_bind_begin
    mov [rsp], rax
    mov qword ptr [rsp + 16], 0
.Lpr_param:
    mov rax, [rsp + 16]
    cmp rax, [r12 + J_NP]
    jae .Lpr_end
    lea rdi, [rbx + PC_OUT]
    mov esi, OID_INT8
    cmp byte ptr [r12 + J_PT + rax], PT_INT8
    je 4f
    mov esi, OID_TEXT
4:  call pgw_array_begin
    mov [rsp + 8], rax
    mov r14, r12
.Lpr_elem:
    cmp r14, rbp
    je .Lpr_arr_end
    mov rax, [rsp + 16]
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp + 8]
    cmp byte ptr [r14 + J_PT + rax], PT_INT8
    jne 5f
    shl rax, 4
    mov rdx, [r14 + J_P + rax]
    call pgw_array_int8
    jmp 6f
5:  shl rax, 4
    mov rdx, [r14 + J_P + rax]
    mov rcx, [r14 + J_P + rax + 8]
    call pgw_array_text
6:  mov r14, [r14 + J_WNEXT]
    jmp .Lpr_elem
.Lpr_arr_end:
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp + 8]
    call pgw_array_end
    inc qword ptr [rsp + 16]
    jmp .Lpr_param
.Lpr_end:
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp]
    call pgw_bind_end
    lea rdi, [rbx + PC_OUT]
    call pgw_execute
    lea rdi, [rbx + PC_OUT]
    call pgw_sync
    mov rdi, rbx
    mov rsi, r12
    call pgio_enqueue
    mov rax, rbp
    add rsp, 32
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# seg_has_error(seg, len) -> rax = 1 if the segment holds an ErrorResponse, else 0.
seg_has_error:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    lea r12, [rdi + rsi]
1:  mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    jle 2f
    call pgr_next
    test rax, rax
    jle 2f
    cmp al, 'E'
    je 3f
    add rbx, rdx
    jmp 1b
2:  xor eax, eax
    jmp 4f
3:  mov eax, 1
4:  add rsp, 8
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- continuations: cont(op, seg, seglen)

# A single write finished: the connection is free; hand the reply to the endpoint.
wr_single_done:
    mov rax, [r15 + W_WR]
    mov qword ptr [rax + PC_WBUSY], 0
    mov rax, [rdi + J_WCONT]
    mov [rdi + J_CONT], rax
    jmp rax

# The group's BEGIN answered.
wr_begin_done:
    sub rsp, 8
    lea rcx, [rdi - PC_GBEGIN]           # pc
    cmp rdx, -1
    jne 1f
    or qword ptr [rcx + PC_GERR], GE_DEAD
    jmp 2f
1:  push rcx
    push rcx
    mov rdi, rsi
    mov rsi, rdx
    call seg_has_error
    pop rcx
    pop rcx
    test rax, rax
    jz 2f
    or qword ptr [rcx + PC_GERR], GE_BEGIN
2:  add rsp, 8
    ret

# A grouped write answered (inside the transaction): keep a copy of its reply for after the COMMIT.
wr_stash:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, -1
    jne 1f
    mov qword ptr [rbx + J_WSEGLEN], -1
    jmp 9f
1:  mov rdi, r12
    mov rsi, r13
    call seg_has_error
    test rax, rax
    jz 2f
    mov rax, [r15 + W_WR]
    or qword ptr [rax + PC_GERR], GE_STMT
    mov qword ptr [rbx + J_WSEGLEN], -2
    jmp 9f
2:  lea rdi, [r13 + 8]
    call rt_alloc
    mov [rax], rdx                       # cap, for rt_free
    mov [rbx + J_WSEG], rax
    mov [rbx + J_WSEGLEN], r13
    lea rdi, [rax + 8]
    mov rsi, r12
    mov rdx, r13
    call rt_memcpy
9:  pop r13
    pop r12
    pop rbx
    ret

# A merged run answered (inside the transaction): split it into one reply copy per job. Each DataRow ends with
# the job's 1-based ordinal (int8); the copy is that row without the ordinal column, then a ReadyForQuery. A job
# with no row gets just the ReadyForQuery. On an error every job of the run is marked failed (-2), as wr_stash
# does for one job.
wr_stash_run:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, WR_BATCH_MAX * 8            # the run's jobs by ordinal
    mov r12, rsi
    mov r13, rdx
    mov rbp, [rdi + J_WRUN]
    xor ecx, ecx
    mov rax, rdi
1:  mov [rsp + rcx*8], rax
    mov rax, [rax + J_WNEXT]
    inc rcx
    cmp rcx, rbp
    jb 1b
    mov rdx, -1
    cmp r13, -1
    je .Lsr_mark
    mov rdi, r12
    mov rsi, r13
    call seg_has_error
    test rax, rax
    jz .Lsr_rows
    mov rax, [r15 + W_WR]
    or qword ptr [rax + PC_GERR], GE_STMT
    mov rdx, -2
.Lsr_mark:
    xor ecx, ecx
2:  mov rax, [rsp + rcx*8]
    mov [rax + J_WSEGLEN], rdx
    inc rcx
    cmp rcx, rbp
    jb 2b
    jmp .Lsr_ret
.Lsr_rows:
    add r13, r12                         # end of the segment
.Lsr_next:
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    jle .Lsr_rest
    call pgr_next
    test rax, rax
    jle .Lsr_rest
    mov r14, rdx                         # message length
    cmp al, 'D'
    jne .Lsr_skip
    cmp r14, 7 + 12
    jb .Lsr_skip
    cmp dword ptr [r12 + r14 - 12], 0x08000000  # last column: 8 bytes
    jne .Lsr_skip
    mov rax, [r12 + r14 - 8]
    bswap rax
    dec rax                              # 0-based ordinal
    cmp rax, rbp
    jae .Lsr_skip
    mov rbx, [rsp + rax*8]
    cmp qword ptr [rbx + J_WSEGLEN], 0
    jne .Lsr_skip                        # (one row per job; keep the first)
    lea rdi, [r14 + 8 - 12 + 6]
    call rt_alloc
    mov [rax], rdx                       # cap, for rt_free
    mov [rbx + J_WSEG], rax
    lea rcx, [r14 - 12 + 6]
    mov [rbx + J_WSEGLEN], rcx
    lea rdi, [rax + 8]
    mov rsi, r12
    lea rdx, [r14 - 12]
    call rt_memcpy                       # the row up to the ordinal column
    mov byte ptr [rax], 'Z'
    mov dword ptr [rax + 1], 0x05000000
    mov byte ptr [rax + 5], 'T'
    mov rdi, [rbx + J_WSEG]
    lea eax, [r14 - 13]                  # message length field without the column
    bswap eax
    mov [rdi + 8 + 1], eax
    movzx eax, word ptr [rdi + 8 + 5]    # column count - 1
    rol ax, 8
    dec ax
    rol ax, 8
    mov [rdi + 8 + 5], ax
.Lsr_skip:
    add r12, r14
    jmp .Lsr_next
.Lsr_rest:
    xor r14d, r14d                       # jobs without a row: a reply with no rows
3:  mov rbx, [rsp + r14*8]
    cmp qword ptr [rbx + J_WSEGLEN], 0
    jne 4f
    mov edi, 8 + 6
    call rt_alloc
    mov [rax], rdx
    mov [rbx + J_WSEG], rax
    mov qword ptr [rbx + J_WSEGLEN], 6
    mov byte ptr [rax + 8], 'Z'
    mov dword ptr [rax + 9], 0x05000000
    mov byte ptr [rax + 13], 'T'
4:  inc r14
    cmp r14, rbp
    jb 3b
.Lsr_ret:
    add rsp, WR_BATCH_MAX * 8
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# The group's COMMIT answered: answer every job (success), retry them one by one (a statement failed and the
# group rolled back), or fail them all (BEGIN/COMMIT failed or the connection died).
wr_commit_done:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    lea rbx, [rdi - PC_GCOMMIT]          # pc
    mov r12, [rbx + PC_GJOBS]
    mov qword ptr [rbx + PC_GJOBS], 0
    cmp rdx, -1
    je .Lcd_fail
    test qword ptr [rbx + PC_GERR], GE_BEGIN | GE_DEAD
    jnz .Lcd_fail
    test qword ptr [rbx + PC_GERR], GE_STMT
    jnz .Lcd_retry
    mov rdi, rsi
    mov rsi, rdx
    call seg_has_error
    test rax, rax
    jnz .Lcd_fail

    # committed: answer in order
    mov qword ptr [rbx + PC_WBUSY], 0
.Lcd_ok:
    test r12, r12
    jz .Lcd_ret
    mov r13, [r12 + J_WNEXT]
    mov r14, [r12 + J_WSEG]
    mov rax, [r12 + J_WCONT]
    mov [r12 + J_CONT], rax
    mov rdi, r12
    lea rsi, [r14 + 8]
    mov rdx, [r12 + J_WSEGLEN]
    call rax                             # answers (and frees) the job
    mov rdi, r14
    mov rsi, [r14]
    call rt_free
    mov r12, r13
    jmp .Lcd_ok

.Lcd_fail:
    mov qword ptr [rbx + PC_WBUSY], 0
.Lcd_fail_loop:
    test r12, r12
    jz .Lcd_ret
    mov rdi, r12
    call wr_drop_copy
    mov r13, [r12 + J_WNEXT]
    mov rax, [r12 + J_WCONT]
    mov [r12 + J_CONT], rax
    mov rdi, r12
    xor esi, esi
    mov rdx, -1
    call rax                             # 500
    mov r12, r13
    jmp .Lcd_fail_loop

.Lcd_retry:
    # nothing committed; run each job again on its own (still busy until the last one answers)
    lea rdi, [rip + .Lmsg_retry]
    mov esi, .Lmsg_retry_len
    mov rdx, [rbx + PC_GN]
    call rt_log_num
.Lcd_retry_loop:
    test r12, r12
    jz .Lcd_ret
    mov rdi, r12
    call wr_drop_copy
    mov r13, [r12 + J_WNEXT]
    lea rax, [rip + wr_retry_done]
    mov [r12 + J_CONT], rax
    mov rdi, rbx
    mov rsi, r12
    call pgio_put_job
    mov rdi, rbx
    mov rsi, r12
    call pgio_enqueue
    mov r12, r13
    jmp .Lcd_retry_loop
.Lcd_ret:
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# wr_drop_copy(job): free a stashed reply copy, if any.
wr_drop_copy:
    cmp qword ptr [rdi + J_WSEGLEN], 0
    jle 1f
    mov rax, [rdi + J_WSEG]
    mov qword ptr [rdi + J_WSEGLEN], 0
    sub rsp, 8
    mov rdi, rax
    mov rsi, [rax]
    call rt_free
    add rsp, 8
1:  ret

# A retried write answered (autocommit): the connection is free after the last one.
wr_retry_done:
    mov rax, [r15 + W_WR]
    dec qword ptr [rax + PC_GN]
    jnz 1f
    mov qword ptr [rax + PC_WBUSY], 0
1:  mov rax, [rdi + J_WCONT]
    mov [rdi + J_CONT], rax
    jmp rax
    .skip 49, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

.section .note.GNU-stack,"",@progbits
