# readb.s: the read scheduler, a port of the Rust read_batch.rs / sched.rs read path (default flags: packed
# lists, shared article/comment sets, tag broadcast).
#
# Every read job joins its family's FIFO (12 families = RK_*, one per read statement). The FIFOs are process-wide
# (one spinlock), as Rust's one scheduler over all read conns: whenever a read connection of any worker has
# nothing in flight, it takes the family whose head is the oldest and up to RB_CAP (512) of its jobs, as Rust's
# scheduler does with READ_BATCH_US=0 (flush whatever has arrived):
#   n == 1          the job's own statement (pgio_put_job), answered by its own continuation.
#   tags, n > 1     one execution of the tag statement; the reply goes to every job.
#   otherwise       one Bind of the batched statement: param p of every job, in order, becomes element i of
#                   array param p (int8[] / text[], binary); each row's last column is the request ordinal
#                   (1..n; 0 = a row shared by several requests). Lists always use the shared ("packed")
#                   statement; article-by-slug and comments use it when distinct slugs * 2 <= n.
# Replies are demuxed as Rust's demux(): unpacked single-row statements go to the job's continuation with its
# row (or no row); packed lists / article / comments are rendered by readr.s. An ErrorResponse or a reply of an
# unexpected shape re-runs every job of the batch on its own (db_read), as Rust retries them individually.
#
# A take can hold other workers' jobs. Their answers go back to the owner (J_WORKER) the way bcrypt results do:
# the job is pushed on the owner's W_DONE with J_CONT = rb_remote, and rb_remote runs the job's continuation /
# renderer / retry there, so client sockets, gzip and allocations stay with their worker. The reply bytes they
# need are copied once per batch into a shared block (reference counted). A batch
# answers its other workers' jobs first, writes each such worker's eventfd once (only if its W_DONE was empty),
# then renders its own. A job is freed only by its owner after its answer (srv_respond), and a closed client
# keeps its job (CF_DEAD), so a queued or remotely batched job stays valid until rb_remote has run.
# Blocks go back to the free lists of the worker that allocated them: the shared copy (its last reference) and
# the owner's block J_RA are pushed on that worker's rb_wk RW_FREE stack when freed elsewhere, and it frees them
# (rb_reclaim) at its next readb_service. Freed into another worker's lists they would pile up there while the
# allocating worker keeps carving new chunks.
# A worker whose connections are all busy (or all down) while jobs wait wakes the workers that said they have an
# idle one (rb_wk RW_IDLE); a worker with no live read connection takes nothing while another worker has one.
#
# readb_enqueue(job), readb_service() and readb_prepare(fd) are the hooks (api.s, server.s, pgio.s).
.include "defs.inc"
.include "app.inc"

.equ RB_CAP, 512
.equ RB_NSTMT, 13                       # batched statements b00..b12

# rb_remote actions (J_RACT)
.equ RA_CONT, 0                         # cont(job, J_RA, J_RB)
.equ RA_RENDER, 1                       # rb_render(J_RFN, J_RA, J_RB)
.equ RA_READ, 2                         # db_read(job)
.equ RA_404, 3
.equ RA_500, 4

.equ RB_SPINS, 256                      # lock spins before sched_yield

# queue {head, tail, count, key}: key = ~J_ORD of the head (0 = empty), so the oldest head has the largest key
.equ Q_HEAD, 0
.equ Q_TAIL, 8
.equ Q_COUNT, 16
.equ Q_KEY, 24

# per-worker wake flags, one cache line each (rb_wk + W_ID * 64)
.equ RW_IDLE, 0                         # 1: this worker has an idle read connection and saw nothing queued
.equ RW_WAKE, 8                         # 1: its eventfd was written for that (xchg)
.equ RW_FREE, 16                        # blocks of this worker's freed on others: {next, cap} (rb_free_to)

.data
.globl g_rd_wait_ms
g_rd_wait_ms: .quad 0                   # READ_BATCH_MS
.globl g_share_pct
g_share_pct: .quad 100                  # READ_SHARE_PCT (article by slug; comments share at 50)

.bss
.align 64
rb_lock: .quad 0
rb_seq: .quad 0                         # arrival counter (J_ORD while queued)
rb_count: .quad 0                       # queued jobs, all families (also read without the lock, as a hint)
.align 64
rb_q: .zero RK_COUNT * 32               # 12 queues
.align 64
rb_wk: .zero MAX_WORKERS * 64

# RB_LOCK / RB_UNLOCK: the queue spinlock. Clobbers eax and the flags. Nothing that can block or allocate runs
# while it is held.
.macro RB_LOCK
    mov eax, 1
    xchg eax, [rip + rb_lock]
    test eax, eax
    jz .Llkd\@
    call rb_lock_wait
.Llkd\@:
.endm
.macro RB_UNLOCK
    mov dword ptr [rip + rb_lock], 0
.endm

# batch op (rt_alloc'd, 64 B): OP_NEXT/OP_CONT, then
.equ BO_FIRST, 16                       # first job (J_BNEXT chain, in ordinal order)
.equ BO_N, 24
.equ BO_KIND, 32
.equ BO_SIZE, 64

.equ K_BCAST, 0                         # tags: the same reply for every job
.equ K_ROWS, 1                          # unpacked rows: each job's continuation gets its row
.equ K_PLIST, 2                         # packed list (19 columns)
.equ K_PART, 3                          # packed article (16 columns)
.equ K_PCOM, 4                          # packed comments (12 columns)
.equ K_COM, 5                           # unpacked comments (10 columns), several rows per job

# readb_done frame
.equ RD_SEG, 0
.equ RD_SEGLEN, 8
.equ RD_FIRST, 16
.equ RD_SCR, 24                         # scratch block: jobs[n] | hdr[n] | hash[H] | recs[m] | recs2[m] | gst | rows
.equ RD_SCRCAP, 32
.equ RD_M, 40                           # DataRows in the reply
.equ RD_HDR, 48                         # per job: its header (packed) / its row (unpacked)
.equ RD_HASH, 56                        # {key, value} slots, value 0 = empty
.equ RD_HMASK, 64
.equ RD_HSHIFT, 72
.equ RD_RECS, 80                        # comment records {group, ~created_at, ~id, msg} in reply order
.equ RD_RECS2, 88                       # the same, grouped and sorted
.equ RD_GST, 96                         # group ends (after the counting sort)
.equ RD_ROWS, 104                       # rows handed to readr
.equ RD_G, 112                          # groups
.equ RD_CUR, 120                        # reply cursor
.equ RD_NHDR, 128
.equ RD_I, 136
.equ RD_NREC, 144
.equ RD_TMP, 152
.equ RD_COLS, 160
.equ RD_NCOLS, 20
.equ RD_SH, RD_COLS + RD_NCOLS * 16     # shared copy of the reply for other workers' jobs (0 = none yet)
.equ RD_PASS, RD_SH + 8                 # pass 3: 0 = other workers' jobs, 1 = this worker's
.equ RD_SIZE, RD_PASS + 8               # 496

.section .rodata
# per family: batched stmt, its kind, shared stmt (0xff none), its kind, text-param mask (bit p: param p is text)
rb_fam:
    .byte 0, K_PLIST, 0xff, 0, 0, 0, 0, 0          # RK_ALL        (lists always share)
    .byte 1, K_PLIST, 0xff, 0, 8, 0, 0, 0          # RK_TAG
    .byte 2, K_PLIST, 0xff, 0, 8, 0, 0, 0          # RK_AUTHOR
    .byte 3, K_PLIST, 0xff, 0, 8, 0, 0, 0          # RK_FAVORITED
    .byte 4, K_PLIST, 0xff, 0, 0, 0, 0, 0          # RK_FEED
    .byte 5, K_ROWS, 6, K_PART, 2, 0, 0, 0         # RK_SLUG
    .byte 7, K_ROWS, 0xff, 0, 0, 0, 0, 0           # RK_ID
    .byte 8, K_ROWS, 0xff, 0, 2, 0, 0, 0           # RK_PROFILE
    .byte 9, K_ROWS, 0xff, 0, 0, 0, 0, 0           # RK_USERID
    .byte 10, K_ROWS, 0xff, 0, 1, 0, 0, 0          # RK_EMAIL
    .byte 11, K_COM, 12, K_PCOM, 2, 0, 0, 0        # RK_COMMENTS
# columns per row of each packed kind (0 = not checked here)
rb_kind_cols: .byte 0, 0, 19, 16, 12, 10
.align 8
rb_one: .quad 1                         # eventfd increment
rb_none: .quad 0                        # the segment of an empty reply handed to another worker
.align 4
rb_names:
    .irp i, 00,01,02,03,04,05,06,07,08,09,10,11,12
    .ascii "b\i"
    .byte 0
    .endr
.align 8
rb_sql:
    .quad qb_f00_shared, qb_f00_shared_end
    .quad qb_f01_shared, qb_f01_shared_end
    .quad qb_f02_shared, qb_f02_shared_end
    .quad qb_f03_shared, qb_f03_shared_end
    .quad qb_f04_shared, qb_f04_shared_end
    .quad qb_f05_batch, qb_f05_batch_end
    .quad qb_f05_shared, qb_f05_shared_end
    .quad qb_f06_batch, qb_f06_batch_end
    .quad qb_f07_batch, qb_f07_batch_end
    .quad qb_f08_batch, qb_f08_batch_end
    .quad qb_f09_batch, qb_f09_batch_end
    .quad qb_f10_batch, qb_f10_batch_end
    .quad qb_f10_shared, qb_f10_shared_end

.text

# readb_prepare(fd) -> 0 | -1: Parse the batched statements (blocking, at startup, read connections).
.globl readb_prepare
readb_prepare:
    push rbx
    push r12
    push r13
    mov ebx, edi
    xor r12d, r12d
1:  cmp r12d, RB_NSTMT
    jae 2f
    lea r13, [rip + rb_sql]
    mov rax, r12
    shl rax, 4
    add r13, rax
    mov edi, ebx
    lea rsi, [rip + rb_names]
    lea rsi, [rsi + r12*4]
    mov rdx, [r13]
    mov rcx, [r13 + 8]
    sub rcx, rdx
    call pg_prepare
    test rax, rax
    js 3f
    inc r12d
    jmp 1b
2:  xor eax, eax
3:  pop r13
    pop r12
    pop rbx
    ret

# readb_enqueue(job): queue a read job (J_STMT = its family). Anything else goes straight to db_read.
.globl readb_enqueue
readb_enqueue:
    mov rax, [rdi + J_STMT]
    cmp rax, RK_COUNT
    jae db_read
    cmp qword ptr [rip + g_rd_wait_ms], 0
    je 0f
    push rdi
    call rt_mono_ms_v
    pop rdi
    mov [rdi + J_T0], rax               # arrival (READ_BATCH_MS)
    mov rax, [rdi + J_STMT]
0:  mov [rdi + J_FAM], rax
    mov [rdi + J_WORKER], r15
    mov qword ptr [rdi + J_BNEXT], 0
    shl rax, 5
    lea rdx, [rip + rb_q]
    add rdx, rax
    RB_LOCK
    mov rcx, [rip + rb_seq]
    inc rcx
    mov [rip + rb_seq], rcx
    mov [rdi + J_ORD], rcx
    mov rax, [rdx + Q_TAIL]
    test rax, rax
    jz 1f
    mov [rax + J_BNEXT], rdi
    jmp 2f
1:  mov [rdx + Q_HEAD], rdi
    not rcx
    mov [rdx + Q_KEY], rcx
2:  mov [rdx + Q_TAIL], rdi
    inc qword ptr [rdx + Q_COUNT]
    inc qword ptr [rip + rb_count]
    RB_UNLOCK
    ret

# readb_service(): while some family has queued jobs and some read connection of this worker is idle (nothing
# in flight), give the oldest family's next take to that connection. If jobs still wait once every connection
# is busy, wake the workers with an idle one. A worker whose read connections are all down leaves the jobs to
# the others; only when no worker has a live one do its takes go to its first connection, where they fail at
# once (500).
.globl readb_service
readb_service:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov rbp, [r15 + W_ID]
    shl rbp, 6
    lea rax, [rip + rb_wk]
    add rbp, rax                        # this worker's wake flags
    mov qword ptr [r15 + W_RDDUE], 0
    cmp qword ptr [rbp + RW_FREE], 0
    je 1f
    mov rdi, rbp
    call rb_reclaim
1:  cmp qword ptr [rbp + RW_WAKE], 0
    je .Lsv_loop
    mov qword ptr [rbp + RW_WAKE], 0
.Lsv_loop:
    xor ebx, ebx                        # idle connection
    xor edx, edx                        # 1 if any connection is alive
    xor ecx, ecx
3:  cmp rcx, [r15 + W_NRD]
    jae 4f
    mov rax, [r15 + W_RDS + rcx*8]
    inc rcx
    test qword ptr [rax + PC_FLAGS], PCF_DEAD
    jnz 3b
    mov edx, 1
    cmp qword ptr [rax + PC_NQ], 0
    jne 3b
    mov rbx, rax
4:  test rbx, rbx
    jnz .Lsv_idle
    test edx, edx
    jnz .Lsv_busy
    cmp qword ptr [rip + rb_count], 0   # every connection is down
    je .Lsv_ret
    call rb_any_live
    test eax, eax
    jnz .Lsv_busy                       # another worker can run them
    mov rbx, [r15 + W_RDS]
    jmp .Lsv_take
.Lsv_idle:
    cmp qword ptr [rip + rb_count], 0
    jne .Lsv_take
    # nothing queued: say so, then look again (a worker with jobs waiting reads RW_IDLE after queueing them)
    mov qword ptr [rbp + RW_IDLE], 1
    mfence
    cmp qword ptr [rip + rb_count], 0
    je .Lsv_ret
.Lsv_take:
    cmp qword ptr [rip + g_rd_wait_ms], 0
    je 0f
    call rt_mono_ms_v
    mov [r15 + W_RDNOW], rax
0:  RB_LOCK
    xor r12d, r12d                      # queue of the oldest head (the largest key)
    xor r14d, r14d
    xor ecx, ecx
    lea r8, [rip + rb_q]
1:  mov rax, rcx
    shl rax, 5
    mov rdx, [r8 + rax + Q_KEY]
    cmp rdx, r14
    jbe 2f
    mov r14, rdx
    lea r12, [r8 + rax]
    mov r13, rcx                        # family
2:  inc ecx
    cmp ecx, RK_COUNT
    jb 1b
    test r12, r12
    jnz 5f
    RB_UNLOCK                           # emptied by another worker
    jmp .Lsv_loop
5:  cmp qword ptr [rip + g_rd_wait_ms], 0
    je 55f
    # READ_BATCH_MS: leave the oldest queue to gather until its head has waited that long (or RB_CAP wait)
    cmp qword ptr [r12 + Q_COUNT], RB_CAP
    jae 55f
    mov rax, [r12 + Q_HEAD]
    mov rax, [rax + J_T0]
    add rax, [rip + g_rd_wait_ms]
    cmp rax, [r15 + W_RDNOW]
    jbe 55f
    RB_UNLOCK
    mov [r15 + W_RDDUE], rax            # the loop's epoll_wait wakes at the deadline
    mov qword ptr [rbp + RW_IDLE], 0    # the timer covers it: busy workers need not wake this one
    jmp .Lsv_ret
55: mov rdi, [r12 + Q_HEAD]             # detach the whole queue
    mov rsi, [r12 + Q_TAIL]
    mov r14, [r12 + Q_COUNT]
    xor eax, eax
    mov [r12 + Q_HEAD], rax
    mov [r12 + Q_TAIL], rax
    mov [r12 + Q_COUNT], rax
    mov [r12 + Q_KEY], rax
    sub [rip + rb_count], r14
    RB_UNLOCK
    cmp qword ptr [rbp + RW_IDLE], 0
    je 6f
    mov qword ptr [rbp + RW_IDLE], 0
6:  cmp r14, RB_CAP
    jbe 8f
    # more than RB_CAP: cut after RB_CAP jobs (outside the lock), then put the rest back in front: it is older
    # than anything queued meanwhile
    mov rax, rdi
    mov ecx, RB_CAP - 1
7:  mov rax, [rax + J_BNEXT]
    dec ecx
    jnz 7b
    mov rdx, [rax + J_BNEXT]            # the rest: rdx .. rsi
    mov qword ptr [rax + J_BNEXT], 0
    mov r8, [rdx + J_ORD]
    not r8
    sub r14, RB_CAP
    RB_LOCK
    mov rax, [r12 + Q_HEAD]
    mov [rsi + J_BNEXT], rax
    mov [r12 + Q_HEAD], rdx
    test rax, rax
    jnz 9f
    mov [r12 + Q_TAIL], rsi
9:  mov [r12 + Q_KEY], r8
    add [r12 + Q_COUNT], r14
    add [rip + rb_count], r14
    RB_UNLOCK
    mov r14d, RB_CAP
8:  mov rdx, rdi
    mov rdi, rbx
    mov rsi, r13
    mov rcx, r14
    call rb_issue
    jmp .Lsv_loop
.Lsv_busy:
    cmp qword ptr [rbp + RW_IDLE], 0
    je 1f
    mov qword ptr [rbp + RW_IDLE], 0
1:  cmp qword ptr [rip + rb_count], 0
    je .Lsv_ret
    mfence                              # pairs with the idle worker's RW_IDLE store + mfence
    xor r12d, r12d
2:  cmp r12, [rip + g_nworkers]
    jae .Lsv_ret
    lea rax, [rip + g_workers]
    mov r13, [rax + r12*8]
    mov r14, r12
    inc r12
    test r13, r13
    jz 2b
    cmp r13, r15
    je 2b
    shl r14, 6
    lea rax, [rip + rb_wk]
    add r14, rax
    cmp qword ptr [r14 + RW_IDLE], 0
    je 2b
    cmp qword ptr [r14 + RW_WAKE], 0
    jne 2b                              # already woken
    mov eax, 1
    xchg rax, [r14 + RW_WAKE]
    test rax, rax
    jnz 2b
    mov rdi, [r13 + W_EVFD]
    lea rsi, [rip + rb_one]
    mov edx, 8
    SYS SYS_write
    jmp 2b
.Lsv_ret:
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rb_lock_wait(): RB_LOCK's slow path. Spins (pause) while the lock is held; after RB_SPINS rounds it yields the
# CPU, since the holder may have been preempted. Returns holding the lock. Clobbers eax and the flags only.
rb_lock_wait:
    push rcx
    push rdx
    push r11
    mov edx, RB_SPINS
1:  pause
    cmp dword ptr [rip + rb_lock], 0
    je 2f
    dec edx
    jnz 1b
    SYS SYS_sched_yield
    mov edx, RB_SPINS
    jmp 1b
2:  mov eax, 1
    xchg eax, [rip + rb_lock]
    test eax, eax
    jnz 1b
    pop r11
    pop rdx
    pop rcx
    ret

# rb_any_live() -> eax = 1 if another worker has a live read connection (read without its owner's ordering: a
# hint). Leaf: clobbers rax, rcx, rdx, r8.
rb_any_live:
    xor ecx, ecx
1:  cmp rcx, [rip + g_nworkers]
    jae 3f
    lea rax, [rip + g_workers]
    mov r8, [rax + rcx*8]
    inc rcx
    test r8, r8
    jz 1b
    cmp r8, r15
    je 1b
    xor edx, edx
2:  cmp rdx, [r8 + W_NRD]
    jae 1b
    mov rax, [r8 + W_RDS + rdx*8]
    inc rdx
    test qword ptr [rax + PC_FLAGS], PCF_DEAD
    jnz 2b
    mov eax, 1
    ret
3:  xor eax, eax
    ret

# rb_issue(pc, family, first, n): write one take to the connection and queue its op.
# frame: [rsp] stmt, [rsp+8] kind, [rsp+16] text mask, [rsp+24] nparams, [rsp+32] p, [rsp+40] array handle,
# [rsp+48] bind handle
rb_issue:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp r14, 1
    jne .Lis_batch
    mov rdi, rbx
    mov rsi, r13
    call pgio_put_job
    mov rsi, r13
    cmp [r13 + J_WORKER], r15
    je 1f
    mov edi, BO_SIZE                    # another worker's job: its reply goes through rb_one_done
    call rt_alloc
    lea rcx, [rip + rb_one_done]
    mov [rax + OP_CONT], rcx
    mov [rax + BO_FIRST], r13
    mov rsi, rax
1:  mov rdi, rbx
    call pgio_enqueue
    jmp .Lis_ret
.Lis_batch:
    mov edi, BO_SIZE
    call rt_alloc
    mov rbp, rax
    lea rax, [rip + readb_done]
    mov [rbp + OP_CONT], rax
    mov [rbp + BO_FIRST], r13
    mov [rbp + BO_N], r14
    cmp r12, RK_TAGS
    jne .Lis_fam
    mov qword ptr [rbp + BO_KIND], K_BCAST
    mov rdi, rbx
    mov esi, 128
    call pgio_reserve
    lea rdi, [rbx + PC_OUT]
    lea rsi, [rip + sql_names + S_TAGS*4]
    mov edx, 3
    xor ecx, ecx
    call pgw_bind_begin
    lea rdi, [rbx + PC_OUT]
    mov rsi, rax
    call pgw_bind_end
    jmp .Lis_exec
.Lis_fam:
    lea rax, [rip + rb_fam]
    lea r12, [rax + r12*8]              # family entry (the family number is no longer needed)
    movzx eax, byte ptr [r12]
    mov [rsp], rax
    movzx eax, byte ptr [r12 + 1]
    mov [rsp + 8], rax
    movzx eax, byte ptr [r12 + 4]
    mov [rsp + 16], rax
    cmp byte ptr [r12 + 2], 0xff
    je 1f
    mov rdi, r13
    mov rsi, r14
    mov edx, 50                         # comments: share at 2 requests per slug
    cmp byte ptr [r12], 5               # article by slug (RK_SLUG's batched statement)
    jne .Lis_fam_pct
    mov rdx, [rip + g_share_pct]
.Lis_fam_pct:
    call rb_should_share
    test eax, eax
    jz 1f
    movzx eax, byte ptr [r12 + 2]
    mov [rsp], rax
    movzx eax, byte ptr [r12 + 3]
    mov [rsp + 8], rax
1:  mov rax, [rsp + 8]
    mov [rbp + BO_KIND], rax
    # J_ORD = 1..n, and the output bound: 128 + 32 per param + per element 12 + its bytes
    mov rcx, [r13 + J_NP]
    mov [rsp + 24], rcx
    mov rsi, rcx
    shl rsi, 5
    add rsi, 128
    mov r8, r13
    xor r10d, r10d
2:  test r8, r8
    jz 5f
    inc r10
    mov [r8 + J_ORD], r10
    xor r9d, r9d
3:  cmp r9, rcx
    jae 4f
    mov rax, r9
    shl rax, 4
    mov rax, [r8 + J_P + rax + 8]
    lea rsi, [rsi + 12]
    test rax, rax
    jle 6f
    add rsi, rax
6:  inc r9
    jmp 3b
4:  mov r8, [r8 + J_BNEXT]
    jmp 2b
5:  mov rdi, rbx
    call pgio_reserve
    lea rdi, [rbx + PC_OUT]
    lea rsi, [rip + rb_names]
    mov rax, [rsp]
    lea rsi, [rsi + rax*4]
    mov edx, 3
    mov rcx, [rsp + 24]
    call pgw_bind_begin
    mov [rsp + 48], rax
    mov qword ptr [rsp + 32], 0
.Lis_param:
    mov rax, [rsp + 32]
    cmp rax, [rsp + 24]
    jae .Lis_bend
    mov esi, OID_INT8
    mov ecx, OID_TEXT
    bt qword ptr [rsp + 16], rax
    cmovc esi, ecx
    lea rdi, [rbx + PC_OUT]
    call pgw_array_begin
    mov [rsp + 40], rax
    mov r12, r13
.Lis_elem:
    test r12, r12
    jz .Lis_aend
    mov r8, [rsp + 32]
    mov rax, r8
    shl rax, 4
    mov rdx, [r12 + J_P + rax]
    mov rcx, [r12 + J_P + rax + 8]
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp + 40]
    test rcx, rcx
    js 2f
    cmp byte ptr [r12 + J_PT + r8], PT_INT8
    je 1f
    call pgw_array_text
    jmp 3f
1:  call pgw_array_int8
    jmp 3f
2:  call pgw_array_null
3:  mov r12, [r12 + J_BNEXT]
    jmp .Lis_elem
.Lis_aend:
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp + 40]
    call pgw_array_end
    inc qword ptr [rsp + 32]
    jmp .Lis_param
.Lis_bend:
    lea rdi, [rbx + PC_OUT]
    mov rsi, [rsp + 48]
    call pgw_bind_end
.Lis_exec:
    lea rdi, [rbx + PC_OUT]
    call pgw_execute
    lea rdi, [rbx + PC_OUT]
    call pgw_sync
    mov rdi, rbx
    mov rsi, rbp
    call pgio_enqueue
.Lis_ret:
    add rsp, 64
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rb_should_share(first, n, pct) -> eax = 1 if the take's distinct param-1 texts (slugs) * 100 <= n * pct
# (Rust should_share with share_pct). Counted with an FNV-1a open-addressing set of {ptr, len + 2}.
rb_should_share:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 32
    mov [rsp + 16], rdx                 # pct
    mov rbx, rdi
    mov r12, rsi
    lea rcx, [r12 + r12]
    mov eax, 16
1:  cmp rax, rcx
    jae 2f
    shl rax, 1
    jmp 1b
2:  mov r13, rax                        # H
    mov rdi, rax
    shl rdi, 4
    call rt_alloc
    mov r14, rax
    mov [rsp], rdx
    mov rdi, rax
    lea rcx, [r13 + r13]
    xor eax, eax
    rep stosq
    xor ebp, ebp                        # distinct
.Lsh_job:
    test rbx, rbx
    jz .Lsh_done
    mov rsi, [rbx + J_P + 16]
    mov rdx, [rbx + J_P + 24]
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor ecx, ecx
    test rdx, rdx
    js 4f
3:  cmp rcx, rdx
    jae 4f
    movzx r9d, byte ptr [rsi + rcx]
    xor rax, r9
    imul rax, r8
    inc rcx
    jmp 3b
4:  lea rcx, [r13 - 1]
    and rax, rcx
    mov [rsp + 8], rax                  # slot
.Lsh_probe:
    mov rax, [rsp + 8]
    shl rax, 4
    add rax, r14
    mov rcx, [rax + 8]
    test rcx, rcx
    jz .Lsh_new
    mov rdx, [rbx + J_P + 24]
    lea r8, [rdx + 2]
    cmp rcx, r8
    jne .Lsh_skip
    test rdx, rdx
    js .Lsh_same                        # NULL == NULL
    mov rdi, [rax]
    mov rsi, rdx
    mov rdx, [rbx + J_P + 16]
    mov rcx, rsi
    call rt_memeq
    test eax, eax
    jnz .Lsh_same
.Lsh_skip:
    mov rax, [rsp + 8]
    inc rax
    lea rcx, [r13 - 1]
    and rax, rcx
    mov [rsp + 8], rax
    jmp .Lsh_probe
.Lsh_new:
    mov rcx, [rbx + J_P + 16]
    mov [rax], rcx
    mov rcx, [rbx + J_P + 24]
    add rcx, 2
    mov [rax + 8], rcx
    inc rbp
.Lsh_same:
    mov rbx, [rbx + J_BNEXT]
    jmp .Lsh_job
.Lsh_done:
    mov rdi, r14
    mov rsi, [rsp]
    call rt_free
    xor eax, eax
    imul rbp, rbp, 100
    imul r12, [rsp + 16]
    cmp rbp, r12
    setbe al
    add rsp, 32
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rb_hslot(table, key, mask, shift in rcx) -> rax = the slot {key, value} holding key, or the empty slot
# (value 0) where it would go. Fibonacci hash, linear probing. Leaf: clobbers rax, r8.
rb_hslot:
    mov rax, rsi
    mov r8, 0x9E3779B97F4A7C15
    imul rax, r8
    shr rax, cl
1:  mov r8, rax
    shl r8, 4
    add r8, rdi
    cmp qword ptr [r8 + 8], 0
    je 2f
    cmp [r8], rsi
    je 2f
    inc rax
    and rax, rdx
    jmp 1b
2:  mov rax, r8
    ret

# HSLOT key_reg: rb_hslot on the frame's table (readb_done frame at rsp + \off).
.macro HSLOT off=0
    mov rdi, [rsp + \off + RD_HASH]
    mov rdx, [rsp + \off + RD_HMASK]
    mov rcx, [rsp + \off + RD_HSHIFT]
    call rb_hslot
.endm

# COL8 i, bad: rax = the int8 in decoded column i (frame cols); jumps to \bad unless it is 8 bytes.
.macro COL8 i, bad, off=0
    cmp qword ptr [rsp + \off + RD_COLS + (\i)*16 + 8], 8
    jne \bad
    mov rax, [rsp + \off + RD_COLS + (\i)*16]
    mov rax, [rax]
    bswap rax
.endm

# KEYDESC i: rdx = sort key of int8 column i for descending order (~v; NULL -> INT64_MAX, i.e. last).
.macro KEYDESC i
    mov rdx, [rsp + RD_COLS + (\i)*16 + 8]
    cmp rdx, -1
    jne .Lkd_v\@
    mov rdx, 0x7fffffffffffffff
    jmp .Lkd_e\@
.Lkd_v\@:
    cmp rdx, 8
    jne .Ld_bad
    mov rdx, [rsp + RD_COLS + (\i)*16]
    mov rdx, [rdx]
    bswap rdx
    not rdx
.Lkd_e\@:
.endm

# RENDER: rb_render(fn, rows, n) for the job in rbx inside readb_done's pass 3 (pass 0: another worker's job).
.macro RENDER
    cmp qword ptr [rsp + RD_PASS], 0
    jne .Lrl\@
    mov rcx, rsp
    call rb_far_render
    jmp .Lre\@
.Lrl\@:
    call rb_render
.Lre\@:
.endm

# readb_done(op, seg, len): a batch's reply.
.globl readb_done
readb_done:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, RD_SIZE
    mov [rsp + RD_SEG], rsi
    mov [rsp + RD_SEGLEN], rdx
    mov qword ptr [rsp + RD_SH], 0
    mov rax, [rdi + BO_FIRST]
    mov [rsp + RD_FIRST], rax
    mov r13, [rdi + BO_N]
    mov r14, [rdi + BO_KIND]
    mov esi, BO_SIZE
    call rt_free
    cmp qword ptr [rsp + RD_SEGLEN], -1
    je .Ld_each
    cmp r14, K_BCAST
    je .Ld_each
    mov rdi, [rsp + RD_SEG]
    mov rsi, [rsp + RD_SEGLEN]
    call seg_scan
    test rdx, rdx
    jnz .Ld_retry
    mov [rsp + RD_M], rcx
    # hash size H = 2^b >= 2 (m + 1), at least 16
    lea rcx, [rcx*2 + 2]
    mov eax, 16
    mov edx, 4
1:  cmp rax, rcx
    jae 2f
    shl rax, 1
    inc edx
    jmp 1b
2:  lea r8, [rax - 1]
    mov [rsp + RD_HMASK], r8
    mov ecx, 64
    sub ecx, edx
    mov [rsp + RD_HSHIFT], rcx
    lea r8, [r13*8]
    mov [rsp + RD_HDR], r8              # offsets first
    lea r9, [r8 + r8]
    mov [rsp + RD_HASH], r9
    shl rax, 4
    add r9, rax
    mov [rsp + RD_RECS], r9
    mov r10, [rsp + RD_M]
    shl r10, 5
    add r9, r10
    mov [rsp + RD_RECS2], r9
    add r9, r10
    mov [rsp + RD_GST], r9
    mov r11, [rsp + RD_M]
    lea r11, [r11 + r13 + 2]
    shl r11, 3
    add r9, r11
    mov [rsp + RD_ROWS], r9
    mov r11, [rsp + RD_M]
    lea r11, [r11*8 + 16]
    lea rdi, [r9 + r11]
    call rt_alloc
    mov [rsp + RD_SCR], rax
    mov [rsp + RD_SCRCAP], rdx
    add [rsp + RD_HDR], rax
    add [rsp + RD_HASH], rax
    add [rsp + RD_RECS], rax
    add [rsp + RD_RECS2], rax
    add [rsp + RD_GST], rax
    add [rsp + RD_ROWS], rax
    mov rdi, [rsp + RD_HDR]             # zero hdr[] and the hash table
    mov rcx, [rsp + RD_RECS]
    sub rcx, rdi
    shr rcx, 3
    xor eax, eax
    rep stosq
    mov rax, [rsp + RD_SCR]             # jobs[], bit 0 set for this worker's (none is answered yet)
    mov rcx, [rsp + RD_FIRST]
3:  test rcx, rcx
    jz 4f
    xor edx, edx
    cmp [rcx + J_WORKER], r15
    sete dl
    or rdx, rcx
    mov [rax], rdx
    add rax, 8
    mov rcx, [rcx + J_BNEXT]
    jmp 3b
4:  xor eax, eax
    mov [rsp + RD_NREC], rax
    mov [rsp + RD_NHDR], rax
    mov [rsp + RD_G], rax
    mov rax, [rsp + RD_SEG]
    mov [rsp + RD_CUR], rax

# ---------------------------------------------------------------- pass 1: route every DataRow
.Ld_row:
    mov rdi, [rsp + RD_CUR]
    mov rsi, [rsp + RD_SEG]
    add rsi, [rsp + RD_SEGLEN]
    call seg_next_row
    test rax, rax
    jz .Ld_rows_done
    mov r12, rax                        # the row message
    add rax, rdx
    mov [rsp + RD_CUR], rax
    mov rdi, r12
    lea rsi, [rsp + RD_COLS]
    mov edx, RD_NCOLS
    call pgr_datarow
    cmp rax, 2
    jb .Ld_bad
    cmp rax, RD_NCOLS
    ja .Ld_bad
    mov rbp, rax                        # columns
    shl rax, 4
    lea rcx, [rsp + RD_COLS + rax - 16] # last column: the request ordinal
    cmp qword ptr [rcx + 8], 8
    jne .Ld_bad
    mov rcx, [rcx]
    mov rcx, [rcx]
    bswap rcx
    cmp r14, K_ROWS
    je .Ld_r_rows
    lea rax, [rip + rb_kind_cols]
    movzx eax, byte ptr [rax + r14]
    cmp rbp, rax
    jne .Ld_bad
    cmp r14, K_COM
    je .Ld_r_com
    test rcx, rcx
    jnz .Ld_r_hdr
    cmp r14, K_PCOM
    je .Ld_r_pcom
    # a shared list / article row, keyed by its article id (list: column 1, article: column 0)
    cmp r14, K_PLIST
    jne 1f
    COL8 1, .Ld_bad
    jmp 2f
1:  COL8 0, .Ld_bad
2:  mov rsi, rax
    HSLOT
    cmp qword ptr [rax + 8], 0
    jne .Ld_bad                         # the same article twice
    mov [rax], rsi
    mov [rax + 8], r12
    jmp .Ld_row
.Ld_r_hdr:                              # a request's header: exactly one per ordinal
    dec rcx
    cmp rcx, r13
    jae .Ld_bad
    mov rax, [rsp + RD_HDR]
    cmp qword ptr [rax + rcx*8], 0
    jne .Ld_bad
    mov [rax + rcx*8], r12
    inc qword ptr [rsp + RD_NHDR]
    jmp .Ld_row
.Ld_r_rows:                             # unpacked: the job's (first) row
    dec rcx
    cmp rcx, r13
    jae .Ld_bad
    mov rax, [rsp + RD_HDR]
    cmp qword ptr [rax + rcx*8], 0
    jne .Ld_row
    mov [rax + rcx*8], r12
    jmp .Ld_row
.Ld_r_pcom:                             # a shared comment: group = its article id (column 0)
    COL8 0, .Ld_bad
    mov rsi, rax
    HSLOT
    mov rcx, [rax + 8]
    test rcx, rcx
    jnz 1f
    mov [rax], rsi
    mov rcx, [rsp + RD_G]
    inc rcx
    mov [rsp + RD_G], rcx
    mov [rax + 8], rcx
1:  dec rcx
    jmp .Ld_rec
.Ld_r_com:                              # an unpacked comment: group = its request
    dec rcx
    cmp rcx, r13
    jae .Ld_bad
.Ld_rec:                                # record {group, ~created_at (col 3), ~id (col 1), msg}
    mov rax, [rsp + RD_NREC]
    shl rax, 5
    add rax, [rsp + RD_RECS]
    mov [rax], rcx
    mov [rax + 24], r12
    KEYDESC 3
    mov [rax + 8], rdx
    KEYDESC 1
    mov [rax + 16], rdx
    inc qword ptr [rsp + RD_NREC]
    jmp .Ld_row

# ---------------------------------------------------------------- pass 2: check the shape before answering
.Ld_rows_done:
    cmp r14, K_PLIST
    je .Ld_v_list
    cmp r14, K_PART
    je .Ld_v_part
    cmp r14, K_PCOM
    je .Ld_v_pcom
    cmp r14, K_COM
    jne .Ld_render
    mov [rsp + RD_G], r13
    jmp .Ld_sort
.Ld_v_list:                             # every request has a header and every page id has its row
    cmp [rsp + RD_NHDR], r13
    jne .Ld_bad
    mov qword ptr [rsp + RD_I], 0
1:  mov rax, [rsp + RD_I]
    cmp rax, r13
    jae .Ld_render
    inc qword ptr [rsp + RD_I]
    mov rcx, [rsp + RD_HDR]
    mov rdi, [rcx + rax*8]
    mov rsi, [rsp + RD_ROWS]
    call .Ld_listrows
    test rax, rax
    js .Ld_bad
    jmp 1b
.Ld_v_part:                             # a header's article row must be there
    mov qword ptr [rsp + RD_I], 0
1:  mov rax, [rsp + RD_I]
    cmp rax, r13
    jae .Ld_render
    inc qword ptr [rsp + RD_I]
    mov rcx, [rsp + RD_HDR]
    mov rdi, [rcx + rax*8]
    test rdi, rdi
    jz 1b
    lea rsi, [rsp + RD_COLS]
    mov edx, RD_NCOLS
    call pgr_datarow
    COL8 0, .Ld_bad
    mov rsi, rax
    HSLOT
    cmp qword ptr [rax + 8], 0
    je .Ld_bad
    jmp 1b
.Ld_v_pcom:
    cmp [rsp + RD_NHDR], r13
    jne .Ld_bad
.Ld_sort:                               # counting sort by group, then insertion sort inside each group
    mov rdi, [rsp + RD_GST]
    mov rcx, [rsp + RD_G]
    inc rcx
    xor eax, eax
    rep stosq
    mov r8, [rsp + RD_RECS]
    mov r9, [rsp + RD_NREC]
    shl r9, 5
    add r9, r8
    mov r10, [rsp + RD_GST]
1:  cmp r8, r9
    jae 2f
    mov rax, [r8]
    inc qword ptr [r10 + rax*8 + 8]
    add r8, 32
    jmp 1b
2:  mov ecx, 1                          # prefix sums: gst[g] = start of group g
3:  cmp rcx, [rsp + RD_G]
    ja 4f
    mov rax, [r10 + rcx*8 - 8]
    add [r10 + rcx*8], rax
    inc rcx
    jmp 3b
4:  mov r8, [rsp + RD_RECS]             # place (gst[g] becomes the end of group g)
    mov r11, [rsp + RD_RECS2]
5:  cmp r8, r9
    jae 6f
    mov rax, [r8]
    mov rcx, [r10 + rax*8]
    inc qword ptr [r10 + rax*8]
    shl rcx, 5
    add rcx, r11
    movdqu xmm0, [r8]
    movdqu xmm1, [r8 + 16]
    movdqu [rcx], xmm0
    movdqu [rcx + 16], xmm1
    add r8, 32
    jmp 5b
6:  xor ecx, ecx                        # group g: [gst[g-1], gst[g])
    xor esi, esi                        # lo
.Ld_isort_g:
    cmp rcx, [rsp + RD_G]
    jae .Ld_render
    mov rdi, [r10 + rcx*8]              # hi
    mov r12, rsi
    shl r12, 5
    add r12, r11                        # &rec[lo]
    lea r8, [rsi + 1]                   # i
7:  cmp r8, rdi
    jae 9f
    mov rax, r8
    shl rax, 5
    add rax, r11
    mov rbx, [rax]                      # t
    mov rdx, [rax + 8]
    mov r9, [rax + 16]
    mov rbp, [rax + 24]
8:  cmp rax, r12
    jbe 10f
    cmp rdx, [rax - 24]                 # t.k1 vs prev.k1
    jg 10f
    jl 11f
    cmp r9, [rax - 16]                  # t.k2 vs prev.k2
    jge 10f
11: movdqu xmm0, [rax - 32]
    movdqu xmm1, [rax - 16]
    movdqu [rax], xmm0
    movdqu [rax + 16], xmm1
    sub rax, 32
    jmp 8b
10: mov [rax], rbx
    mov [rax + 8], rdx
    mov [rax + 16], r9
    mov [rax + 24], rbp
    inc r8
    jmp 7b
9:  mov rsi, rdi
    inc rcx
    jmp .Ld_isort_g

# ---------------------------------------------------------------- pass 3: answer every job, in order
# (other workers' jobs first, so their workers can start on them while this one renders its own)
.Ld_render:
    mov qword ptr [rsp + RD_PASS], 0
.Ld_rpass:
    mov qword ptr [rsp + RD_I], 0
.Ld_rn:
    mov rax, [rsp + RD_I]
    cmp rax, r13
    jae .Ld_rnext
    inc qword ptr [rsp + RD_I]
    mov rcx, [rsp + RD_SCR]
    mov rbx, [rcx + rax*8]              # the job | this worker's
    mov rdx, rbx
    and edx, 1
    cmp rdx, [rsp + RD_PASS]
    jne .Ld_rn
    and rbx, -2
    mov rcx, [rsp + RD_HDR]
    mov r12, [rcx + rax*8]              # its header / row (0 = none)
    cmp r14, K_ROWS
    je .Ld_a_rows
    cmp r14, K_PLIST
    je .Ld_a_list
    cmp r14, K_PART
    je .Ld_a_part
    cmp r14, K_PCOM
    je .Ld_a_pcom
    # K_COM: the request's group, sorted
    mov rcx, rax
    mov rdi, [rsp + RD_ROWS]
    call .Ld_group
    test rax, rax
    jz .Ld_a_404
    lea rdi, [rip + readr_comments]
    mov rsi, [rsp + RD_ROWS]
    mov rdx, rax
    RENDER
    jmp .Ld_rn
.Ld_a_rows:
    mov rsi, r12
    test r12, r12
    jz 1f
    mov edx, [r12 + 1]
    bswap edx
    inc rdx
    jmp 2f
1:  mov rsi, [rsp + RD_SEG]
    xor edx, edx
2:  mov rdi, rbx
    cmp qword ptr [rsp + RD_PASS], 0
    jne 3f
    mov rcx, rsp
    call rb_far_cont
    jmp .Ld_rn
3:  call [rdi + J_CONT]
    jmp .Ld_rn
.Ld_a_list:
    mov rdi, r12
    mov rsi, [rsp + RD_ROWS]
    call .Ld_listrows
    lea rdi, [rip + readr_list]
    mov rsi, [rsp + RD_ROWS]
    mov rdx, rax
    RENDER
    jmp .Ld_rn
.Ld_a_part:
    test r12, r12
    jz .Ld_a_404
    mov rdi, r12
    lea rsi, [rsp + RD_COLS]
    mov edx, RD_NCOLS
    call pgr_datarow
    COL8 0, .Ld_a_500
    mov rsi, rax
    HSLOT
    mov rcx, [rsp + RD_ROWS]
    mov [rcx], r12
    mov rax, [rax + 8]
    mov [rcx + 8], rax
    lea rdi, [rip + readr_article]
    mov rsi, rcx
    mov edx, 2
    RENDER
    jmp .Ld_rn
.Ld_a_pcom:
    mov rdi, r12
    lea rsi, [rsp + RD_COLS]
    mov edx, RD_NCOLS
    call pgr_datarow
    cmp qword ptr [rsp + RD_COLS + 8], -1
    je .Ld_a_404                        # no such article
    COL8 0, .Ld_a_500
    mov rsi, rax
    HSLOT
    mov rcx, [rax + 8]                  # group + 1 (0: the article has no comments)
    mov rdi, [rsp + RD_ROWS]
    mov [rdi], r12
    add rdi, 8
    xor eax, eax
    test rcx, rcx
    jz 1f
    dec rcx
    call .Ld_group
1:  inc rax
    lea rdi, [rip + readr_comments]
    mov rsi, [rsp + RD_ROWS]
    mov rdx, rax
    RENDER
    jmp .Ld_rn
.Ld_a_404:
    call rb_404
    jmp .Ld_rn
.Ld_a_500:
    call rb_500
    jmp .Ld_rn

.Ld_rnext:
    cmp qword ptr [rsp + RD_PASS], 0
    jne .Ld_free
    call rb_signal                      # the other workers' answers are posted
    mov qword ptr [rsp + RD_PASS], 1
    jmp .Ld_rpass
.Ld_free:
    mov rdi, [rsp + RD_SCR]
    mov rsi, [rsp + RD_SCRCAP]
    call rt_free
.Ld_ret:
    call rb_signal
    mov rdi, [rsp + RD_SH]              # readb_done's reference to the shared copy
    test rdi, rdi
    jz 1f
    call rb_drop
1:  add rsp, RD_SIZE
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# a dead connection (cont(job, 0, -1)) or a tag broadcast (cont(job, seg, len)): every job gets the segment.
# Other workers' jobs are posted first (each read before it is posted); this worker's are chained in r13.
.Ld_each:
    mov rbx, [rsp + RD_FIRST]
    xor r13d, r13d
    xor r14d, r14d                      # tail of the chain
1:  test rbx, rbx
    jz 3f
    mov r12, [rbx + J_BNEXT]
    cmp [rbx + J_WORKER], r15
    je 2f
    mov rdi, rbx
    mov rsi, [rsp + RD_SEG]
    mov rdx, [rsp + RD_SEGLEN]
    mov rcx, rsp
    call rb_far_cont
    mov rbx, r12
    jmp 1b
2:  mov qword ptr [rbx + J_BNEXT], 0
    test r14, r14
    jz 4f
    mov [r14 + J_BNEXT], rbx
    jmp 5f
4:  mov r13, rbx
5:  mov r14, rbx
    mov rbx, r12
    jmp 1b
3:  call rb_signal
    mov rbx, r13
6:  test rbx, rbx
    jz .Ld_ret
    mov r12, [rbx + J_BNEXT]
    mov rdi, rbx
    mov rsi, [rsp + RD_SEG]
    mov rdx, [rsp + RD_SEGLEN]
    call [rbx + J_CONT]
    mov rbx, r12
    jmp 6b

# the batch failed or its reply is not what the demux expects: run every job on its own
.Ld_bad:
    mov rdi, [rsp + RD_SCR]
    mov rsi, [rsp + RD_SCRCAP]
    call rt_free
.Ld_retry:
    mov rbx, [rsp + RD_FIRST]
1:  test rbx, rbx
    jz .Ld_ret
    mov r12, [rbx + J_BNEXT]
    mov rdi, rbx
    call rb_read
    mov rbx, r12
    jmp 1b

# .Ld_listrows(hdr, rows) -> rax = rows written (the header, then the page's article rows in the header's id
# order), or -1 if an id has no row or the id array is malformed. Called from readb_done (frame at rsp + 8);
# calls only leaf functions.
.Ld_listrows:
    mov [rsp + 8 + RD_TMP], rsi
    mov [rsi], rdi
    lea rsi, [rsp + 8 + RD_COLS]
    mov edx, RD_NCOLS
    call pgr_datarow
    mov r9, [rsp + 8 + RD_COLS + 15*16]  # page ids (int8[])
    mov r10, [rsp + 8 + RD_COLS + 15*16 + 8]
    cmp r10, 12
    jl 4f
    mov eax, [r9]
    bswap eax                           # ndim
    test eax, eax
    jnz 1f
    cmp r10, 12
    jne 4f
    mov eax, 1                          # empty page
    ret
1:  cmp eax, 1
    jne 4f
    mov r11d, [r9 + 12]
    bswap r11d
    cmp r11, [rsp + 8 + RD_M]
    ja 4f
    lea rax, [r11 + r11*2]
    lea rax, [rax*4 + 20]
    cmp rax, r10
    jne 4f
    add r9, 20
    mov r10, [rsp + 8 + RD_TMP]
    add r10, 8
2:  test r11, r11
    jz 3f
    cmp dword ptr [r9], 0x08000000
    jne 4f
    mov rsi, [r9 + 4]
    bswap rsi
    HSLOT 8
    mov rax, [rax + 8]
    test rax, rax
    jz 4f
    mov [r10], rax
    add r10, 8
    add r9, 12
    dec r11
    jmp 2b
3:  mov rax, r10
    sub rax, [rsp + 8 + RD_TMP]
    shr rax, 3
    ret
4:  mov rax, -1
    ret

# .Ld_group(group in rcx, out in rdi) -> rax = rows written: the sorted comment rows of a group. Leaf, called
# from readb_done (frame at rsp + 8).
.Ld_group:
    mov r10, [rsp + 8 + RD_GST]
    xor eax, eax
    test rcx, rcx
    jz 1f
    mov rax, [r10 + rcx*8 - 8]
1:  mov rdx, [r10 + rcx*8]
    mov r11, [rsp + 8 + RD_RECS2]
    mov r8, rdi
2:  cmp rax, rdx
    jae 3f
    mov r9, rax
    shl r9, 5
    mov r9, [r11 + r9 + 24]
    mov [rdi], r9
    add rdi, 8
    inc rax
    jmp 2b
3:  mov rax, rdi
    sub rax, r8
    shr rax, 3
    ret

# rb_render(fn, rows, n): answer the job in rbx with fn(dst, rows, n) (a readr_* renderer): 200 with the body,
# or 404 / 500 when fn returns 0 / -1. Runs on the job's worker.
rb_render:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    call readr_bound
    mov rdi, rax
    call api_body
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call r12
    test rax, rax
    jle 1f
    mov qword ptr [rbx + J_STATUS], 200
    mov rdi, rax
    call api_send
    jmp 3f
1:  mov r12, rax
    mov rdi, [rbx + J_OUT]
    mov rsi, [rbx + J_OUTCAP]
    call rt_free
    mov qword ptr [rbx + J_OUT], 0
    test r12, r12
    jz 2f
    call api_500
    jmp 3f
2:  call api_404
3:  pop r14
    pop r13
    pop r12
    ret

# ---------------------------------------------------------------- answers for other workers' jobs
# rb_share(frame) -> rax = copy - reply, rdx = block: readb_done's shared copy of its reply, a block
# {refs, cap, worker, 0, bytes}, made on first use with one reference (readb_done's own, dropped at its end).
rb_share:
    mov rdx, [rdi + RD_SH]
    test rdx, rdx
    jz 1f
    lea rax, [rdx + 32]
    sub rax, [rdi + RD_SEG]
    ret
1:  push rbx
    mov rbx, rdi
    mov rdi, [rbx + RD_SEGLEN]
    add rdi, 32
    call rt_alloc
    mov qword ptr [rax], 1
    mov [rax + 8], rdx
    mov [rax + 16], r15
    mov [rbx + RD_SH], rax
    lea rdi, [rax + 32]
    mov rsi, [rbx + RD_SEG]
    mov rdx, [rbx + RD_SEGLEN]
    call rt_memcpy
    mov rdx, [rbx + RD_SH]
    lea rax, [rdx + 32]
    sub rax, [rbx + RD_SEG]
    pop rbx
    ret

# rb_drop(block): drop a reference to a shared reply copy; the last one frees it (to the worker that made it).
rb_drop:
    lock dec qword ptr [rdi]
    jz 1f
    ret
1:  mov rsi, [rdi + 8]
    mov rdx, [rdi + 16]
    jmp rb_free_to

# rb_free_to(ptr, cap, worker): rt_free(ptr, cap) for a block worker allocated: here if it is this worker,
# else pushed on its RW_FREE stack ({next, cap} in the block) for rb_reclaim. Leaf.
rb_free_to:
    cmp rdx, r15
    je rt_free
    mov [rdi + 8], rsi
    mov rdx, [rdx + W_ID]
    shl rdx, 6
    lea rax, [rip + rb_wk]
    add rdx, rax
    mov rax, [rdx + RW_FREE]
1:  mov [rdi], rax
    lock cmpxchg [rdx + RW_FREE], rdi
    jnz 1b
    ret

# rb_reclaim(flags): free the blocks other workers returned on this worker's RW_FREE stack (flags = its rb_wk
# line). Pushes only add, and the stack is taken whole, so there is no ABA.
rb_reclaim:
    push rbx
    xor eax, eax
    xchg rax, [rdi + RW_FREE]
1:  test rax, rax
    jz 2f
    mov rbx, [rax]
    mov rdi, rax
    mov rsi, [rax + 8]
    call rt_free
    mov rax, rbx
    jmp 1b
2:  pop rbx
    ret

# rb_far_cont(job, ptr, len, frame): post cont(job, ptr, len) to the job's worker, ptr moved into the frame's
# shared copy (len 0: rb_none; len -1, a dead connection: ptr as given, no bytes).
rb_far_cont:
    mov qword ptr [rdi + J_RCAP], 0
    mov qword ptr [rdi + J_RSH], 0
    mov [rdi + J_RB], rdx
    test rdx, rdx
    jg 1f
    lea rax, [rip + rb_none]
    cmovs rax, rsi
    mov [rdi + J_RA], rax
    jmp 2f
1:  push rdi
    push rsi
    sub rsp, 8
    mov rdi, rcx
    call rb_share
    add rsp, 8
    pop rsi
    pop rdi
    add rsi, rax
    mov [rdi + J_RA], rsi
    lock inc qword ptr [rdx]
    mov [rdi + J_RSH], rdx
2:  mov esi, RA_CONT
    jmp rb_post

# rb_far_render(fn, rows, n, frame): post rb_render(fn, rows', n) to the worker of the job in rbx; rows' (an
# rt_alloc'd array the owner frees) are the rows moved into the frame's shared copy.
rb_far_render:
    push r12
    push r13
    push r14
    mov [rbx + J_RFN], rdi
    mov [rbx + J_RB], rdx
    mov r12, rsi
    mov r13, rdx
    mov rdi, rcx
    call rb_share
    lock inc qword ptr [rdx]
    mov [rbx + J_RSH], rdx
    mov r14, rax
    lea rdi, [r13*8]
    call rt_alloc
    mov [rbx + J_RA], rax
    mov [rbx + J_RCAP], rdx
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    mov rdx, [r12 + rcx*8]
    add rdx, r14
    mov [rax + rcx*8], rdx
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov esi, RA_RENDER
    call rb_post
    pop r14
    pop r13
    pop r12
    ret

# rb_cont(job, seg, len): cont(job, seg, len) on the job's worker, for rb_one_done: another worker's job gets
# its own copy of the segment (an empty one: rb_none; a dead connection, len -1: seg as given).
rb_cont:
    cmp [rdi + J_WORKER], r15
    jne 1f
    jmp [rdi + J_CONT]
1:  push rbx
    mov rbx, rdi
    mov [rbx + J_RA], rsi
    mov qword ptr [rbx + J_RCAP], 0
    mov qword ptr [rbx + J_RSH], 0
    mov [rbx + J_RB], rdx
    test rdx, rdx
    js 3f
    jnz 2f
    lea rax, [rip + rb_none]
    mov [rbx + J_RA], rax
    jmp 3f
2:  push rsi
    push rdx
    mov rdi, rdx
    call rt_alloc
    mov [rbx + J_RA], rax
    mov [rbx + J_RCAP], rdx
    pop rcx
    pop rsi
    mov rdi, rax
    rep movsb
3:  mov rdi, rbx
    mov esi, RA_CONT
    call rb_post
    pop rbx
    ret

# rb_read(job): db_read(job) on the job's worker (the retry of a failed take).
rb_read:
    cmp [rdi + J_WORKER], r15
    je db_read
    mov qword ptr [rdi + J_RCAP], 0
    mov qword ptr [rdi + J_RSH], 0
    mov esi, RA_READ
    jmp rb_post

# rb_404 / rb_500: api_404 / api_500 for the job in rbx, on its worker.
rb_404:
    cmp [rbx + J_WORKER], r15
    je api_404
    mov esi, RA_404
    jmp 1f
rb_500:
    cmp [rbx + J_WORKER], r15
    je api_500
    mov esi, RA_500
1:  mov qword ptr [rbx + J_RCAP], 0
    mov qword ptr [rbx + J_RSH], 0
    mov rdi, rbx
    jmp rb_post

# rb_post(job, action): push the job on its worker's W_DONE with J_CONT = rb_remote. If the stack was empty,
# rb_signal writes that worker's eventfd (otherwise whoever made it non-empty does). The job is not touched
# after the push. Leaf.
rb_post:
    mov rax, [rdi + J_CONT]
    mov [rdi + J_RCONT], rax
    lea rax, [rip + rb_remote]
    mov [rdi + J_CONT], rax
    mov [rdi + J_RACT], rsi
    mov [rdi + J_RW], r15
    mov rdx, [rdi + J_WORKER]
    mov rcx, [rdx + W_ID]
    mov rax, [rdx + W_DONE]
1:  mov [rdi + J_NEXT], rax
    lock cmpxchg [rdx + W_DONE], rdi
    jnz 1b
    test rax, rax
    jnz 2f
    bts qword ptr [r15 + W_RSIG], rcx
2:  ret

# rb_signal(): write the eventfd of every worker rb_post asked to since the last call.
rb_signal:
    mov rax, [r15 + W_RSIG]
    test rax, rax
    jnz 1f
    ret
1:  push rbx
    push r12
    sub rsp, 8
    mov qword ptr [r15 + W_RSIG], 0
    mov rbx, rax
2:  bsf r12, rbx
    btr rbx, r12
    lea rax, [rip + g_workers]
    mov rax, [rax + r12*8]
    mov rdi, [rax + W_EVFD]
    lea rsi, [rip + rb_one]
    mov edx, 8
    SYS SYS_write
    test rbx, rbx
    jnz 2b
    add rsp, 8
    pop r12
    pop rbx
    ret

# rb_one_done(op, seg, len): the reply of another worker's single job (rb_issue, n = 1).
rb_one_done:
    push rbx
    push rsi
    push rdx
    mov rbx, [rdi + BO_FIRST]
    mov esi, BO_SIZE
    call rt_free
    pop rdx
    pop rsi
    mov rdi, rbx
    call rb_cont
    call rb_signal
    pop rbx
    ret

# rb_remote(job, 0, 0): srv_completions on the job's worker: restore J_CONT and do what rb_post was asked to,
# then free the job's block (to the worker that posted it) and drop its shared copy (read first: the job may be
# gone by then).
rb_remote:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov rax, [rbx + J_RCONT]
    mov [rbx + J_CONT], rax
    mov r12, [rbx + J_RA]
    mov r13, [rbx + J_RCAP]
    mov r14, [rbx + J_RSH]
    mov rax, [rbx + J_RW]
    mov [rsp], rax
    mov rax, [rbx + J_RACT]
    cmp eax, RA_CONT
    jne 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbx + J_RB]
    call [rbx + J_CONT]
    jmp 5f
1:  cmp eax, RA_RENDER
    jne 2f
    mov rdi, [rbx + J_RFN]
    mov rsi, r12
    mov rdx, [rbx + J_RB]
    call rb_render
    jmp 5f
2:  cmp eax, RA_READ
    jne 3f
    mov rdi, rbx
    call db_read
    jmp 5f
3:  cmp eax, RA_404
    jne 4f
    call api_404
    jmp 5f
4:  call api_500
5:  test r13, r13
    jz 6f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    call rb_free_to
6:  test r14, r14
    jz 7f
    mov rdi, r14
    call rb_drop
7:  add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- SQL (verbatim from Rust, see test/pg/batch)
.section .rodata
# Generated by test/pg/batch/gen_sql.py from the Rust read_batch.rs SQL (default env flags). Do not edit.
qb_f00_shared:
    .ascii "WITH requests AS MATERIALIZED (\012"
    .ascii "         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord)),\012"
    .ascii "         \012"
    .ascii "         counted AS MATERIALIZED (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s),\012"
    .ascii "         page_keys AS MATERIALIZED (SELECT DISTINCT p2, p3 FROM requests),\012"
    .ascii "         pages AS MATERIALIZED (\012"
    .ascii "         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL (SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2) p ON true),\012"
    .ascii "         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),\012"
    .ascii "         tg AS MATERIALIZED (\012"
    .ascii "         SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id\012"
    .ascii "         WHERE at.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),\012"
    .ascii "         fc AS MATERIALIZED (\012"
    .ascii "         SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),\012"
    .ascii "         enriched AS MATERIALIZED (\012"
    .ascii "         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,\012"
    .ascii "         COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc,\012"
    .ascii "         u.username, u.bio, u.image\012"
    .ascii "         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id\012"
    .ascii "         LEFT JOIN tg ON tg.article_id = a.id LEFT JOIN fc ON fc.article_id = a.id),\012"
    .ascii "         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM enriched),\012"
    .ascii "         pa AS MATERIALIZED (\012"
    .ascii "         SELECT p2, p3, array_agg(id ORDER BY id DESC) FILTER (WHERE id IS NOT NULL) AS ids FROM pages GROUP BY p2, p3),\012"
    .ascii "         vf AS MATERIALIZED (\012"
    .ascii "         SELECT f.user_id, array_agg(f.article_id) AS ids FROM favorites f\012"
    .ascii "         WHERE f.user_id = ANY(ARRAY(SELECT p1 FROM requests))\012"
    .ascii "           AND f.article_id BETWEEN (SELECT lo FROM bounds) AND (SELECT hi FROM bounds) GROUP BY 1),\012"
    .ascii "         vo AS MATERIALIZED (\012"
    .ascii "         SELECT fo.follower_id, array_agg(fo.followee_id) AS ids FROM follows fo\012"
    .ascii "         WHERE fo.follower_id = ANY(ARRAY(SELECT p1 FROM requests))\012"
    .ascii "           AND fo.followee_id = ANY((SELECT au FROM bounds)::bigint[]) GROUP BY 1),\012"
    .ascii "         fl AS MATERIALIZED (\012"
    .ascii "         SELECT q.ord, pa.ids, vf.ids AS favs, vo.ids AS fols\012"
    .ascii "         FROM requests q JOIN pa ON pa.p2 = q.p2 AND pa.p3 = q.p3\012"
    .ascii "         LEFT JOIN vf ON vf.user_id = q.p1 LEFT JOIN vo ON vo.follower_id = q.p1)\012"
    .ascii "         SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,\012"
    .ascii "         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,\012"
    .ascii "         NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "         FROM enriched e\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         COALESCE(fl.ids, '{}'), COALESCE(fl.favs, '{}'), COALESCE(fl.fols, '{}'), q.ord::bigint\012"
    .ascii "         FROM requests q CROSS JOIN counted c JOIN fl ON fl.ord = q.ord"
qb_f00_shared_end:
qb_f01_shared:
    .ascii "WITH requests AS MATERIALIZED (\012"
    .ascii "         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),\012"
    .ascii "         keys AS MATERIALIZED (SELECT DISTINCT p4 FROM requests),\012"
    .ascii "         counted AS MATERIALIZED (SELECT r.p4, c.n FROM keys r CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n) c),\012"
    .ascii "         page_keys AS MATERIALIZED (SELECT DISTINCT p2, p3, p4 FROM requests),\012"
    .ascii "         pages AS MATERIALIZED (\012"
    .ascii "         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3) p ON true),\012"
    .ascii "         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),\012"
    .ascii "         tg AS MATERIALIZED (\012"
    .ascii "         SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id\012"
    .ascii "         WHERE at.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),\012"
    .ascii "         fc AS MATERIALIZED (\012"
    .ascii "         SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),\012"
    .ascii "         enriched AS MATERIALIZED (\012"
    .ascii "         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,\012"
    .ascii "         COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc,\012"
    .ascii "         u.username, u.bio, u.image\012"
    .ascii "         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id\012"
    .ascii "         LEFT JOIN tg ON tg.article_id = a.id LEFT JOIN fc ON fc.article_id = a.id),\012"
    .ascii "         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM enriched),\012"
    .ascii "         fl0 AS MATERIALIZED (\012"
    .ascii "         SELECT q.ord, q.p1, array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids,\012"
    .ascii "         array_agg(DISTINCT e.author_id) FILTER (WHERE e.author_id IS NOT NULL) AS au\012"
    .ascii "         FROM requests q JOIN pages p ON p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4\012"
    .ascii "         LEFT JOIN enriched e ON e.id = p.id GROUP BY q.ord, q.p1),\012"
    .ascii "         fl AS MATERIALIZED (\012"
    .ascii "         SELECT ord, ids,\012"
    .ascii "         ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = fl0.p1 AND f.article_id = ANY(fl0.ids)) AS favs,\012"
    .ascii "         ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = fl0.p1 AND fo.followee_id = ANY(fl0.au)) AS fols\012"
    .ascii "         FROM fl0)\012"
    .ascii "         SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,\012"
    .ascii "         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,\012"
    .ascii "         NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "         FROM enriched e\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         COALESCE(fl.ids, '{}'), COALESCE(fl.favs, '{}'), COALESCE(fl.fols, '{}'), q.ord::bigint\012"
    .ascii "         FROM requests q JOIN counted c ON c.p4 = q.p4 JOIN fl ON fl.ord = q.ord"
qb_f01_shared_end:
qb_f02_shared:
    .ascii "WITH requests AS MATERIALIZED (\012"
    .ascii "         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),\012"
    .ascii "         keys AS MATERIALIZED (SELECT k.p4, u.id AS uid, u.username, u.bio, u.image\012"
    .ascii "         FROM (SELECT DISTINCT p4 FROM requests) k LEFT JOIN users u ON u.username = k.p4),\012"
    .ascii "         counted AS MATERIALIZED (SELECT r.p4, c.n FROM keys r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = r.uid LIMIT 1000) s) c),\012"
    .ascii "         page_keys AS MATERIALIZED (SELECT r.p2, r.p3, r.p4, k.uid FROM (SELECT DISTINCT p2, p3, p4 FROM requests) r JOIN keys k ON k.p4 = r.p4),\012"
    .ascii "         pages AS MATERIALIZED (\012"
    .ascii "         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = r.uid ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3) p ON true),\012"
    .ascii "         article_ids AS (SELECT DISTINCT id, p4 FROM pages WHERE id IS NOT NULL),\012"
    .ascii "         enriched AS MATERIALIZED (\012"
    .ascii "         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,\012"
    .ascii "         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name\012"
    .ascii "               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,\012"
    .ascii "         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,\012"
    .ascii "         k.username, k.bio, k.image\012"
    .ascii "         FROM article_ids i JOIN articles a ON a.id = i.id JOIN keys k ON k.p4 = i.p4),\012"
    .ascii "         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM enriched),\012"
    .ascii "         fl0 AS MATERIALIZED (\012"
    .ascii "         SELECT q.ord, q.p1, array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids\012"
    .ascii "         FROM requests q JOIN pages p ON p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4 GROUP BY q.ord, q.p1),\012"
    .ascii "         fl AS MATERIALIZED (\012"
    .ascii "         SELECT ord, ids,\012"
    .ascii "         ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = fl0.p1 AND f.article_id = ANY(fl0.ids)) AS favs\012"
    .ascii "         FROM fl0)\012"
    .ascii "         SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,\012"
    .ascii "         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,\012"
    .ascii "         NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "         FROM enriched e\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         COALESCE(fl.ids, '{}'), COALESCE(fl.favs, '{}'), CASE WHEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = k.uid) THEN ARRAY[k.uid] ELSE '{}'::bigint[] END, q.ord::bigint\012"
    .ascii "         FROM requests q JOIN counted c ON c.p4 = q.p4 JOIN fl ON fl.ord = q.ord JOIN keys k ON k.p4 = q.p4"
qb_f02_shared_end:
qb_f03_shared:
    .ascii "WITH requests AS MATERIALIZED (\012"
    .ascii "         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),\012"
    .ascii "         keys AS MATERIALIZED (SELECT DISTINCT p4 FROM requests),\012"
    .ascii "         counted AS MATERIALIZED (SELECT r.p4, c.n FROM keys r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s) c),\012"
    .ascii "         page_keys AS MATERIALIZED (SELECT DISTINCT p2, p3, p4 FROM requests),\012"
    .ascii "         pages AS MATERIALIZED (\012"
    .ascii "         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3) p ON true),\012"
    .ascii "         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),\012"
    .ascii "         enriched AS MATERIALIZED (\012"
    .ascii "         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,\012"
    .ascii "         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name\012"
    .ascii "               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,\012"
    .ascii "         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,\012"
    .ascii "         u.username, u.bio, u.image\012"
    .ascii "         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id),\012"
    .ascii "         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM enriched),\012"
    .ascii "         fl0 AS MATERIALIZED (\012"
    .ascii "         SELECT q.ord, q.p1, array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids,\012"
    .ascii "         array_agg(DISTINCT e.author_id) FILTER (WHERE e.author_id IS NOT NULL) AS au\012"
    .ascii "         FROM requests q JOIN pages p ON p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4\012"
    .ascii "         LEFT JOIN enriched e ON e.id = p.id GROUP BY q.ord, q.p1),\012"
    .ascii "         fl AS MATERIALIZED (\012"
    .ascii "         SELECT ord, ids,\012"
    .ascii "         ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = fl0.p1 AND f.article_id = ANY(fl0.ids)) AS favs,\012"
    .ascii "         ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = fl0.p1 AND fo.followee_id = ANY(fl0.au)) AS fols\012"
    .ascii "         FROM fl0)\012"
    .ascii "         SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,\012"
    .ascii "         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,\012"
    .ascii "         NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "         FROM enriched e\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         COALESCE(fl.ids, '{}'), COALESCE(fl.favs, '{}'), COALESCE(fl.fols, '{}'), q.ord::bigint\012"
    .ascii "         FROM requests q JOIN counted c ON c.p4 = q.p4 JOIN fl ON fl.ord = q.ord"
qb_f03_shared_end:
qb_f04_shared:
    .ascii "WITH r AS MATERIALIZED (\012"
    .ascii " SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1) AS fl\012"
    .ascii " FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),\012"
    .ascii " bounds AS MATERIALIZED (\012"
    .ascii " SELECT b.f AS author_id,\012"
    .ascii "   ARRAY(SELECT s.id FROM (SELECT a3.id FROM articles a3 WHERE a3.author_id = b.f ORDER BY a3.id DESC LIMIT b.take) s ORDER BY s.id) AS ids,\012"
    .ascii "   EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = b.f ORDER BY a3.id DESC OFFSET 999 LIMIT 1) AS big\012"
    .ascii " FROM (SELECT f, max(GREATEST(r.p4, 1)) AS take FROM r, unnest(r.fl) AS f GROUP BY f HAVING count(*) >= 2\012"
    .ascii "       ORDER BY count(*) DESC, f LIMIT 20) b),\012"
    .ascii " sh AS MATERIALIZED (\012"
    .ascii " SELECT j.ord, max(j.ids[cardinality(j.ids) - j.p4 + 1]) AS cutoff, bool_or(j.big) AS anybig\012"
    .ascii " FROM (SELECT r.ord, r.p4, b.ids, b.big FROM r, unnest(r.fl) AS f JOIN bounds b ON b.author_id = f) j GROUP BY j.ord),\012"
    .ascii " wq AS MATERIALIZED (\012"
    .ascii " SELECT sh.ord, sh.cutoff FROM sh\012"
    .ascii " WHERE sh.cutoff > (SELECT max(a.id) FROM articles a)\012"
    .ascii "   - CASE WHEN cardinality($1::bigint[]) < 32 THEN 0 ELSE LEAST(2048, 32 * cardinality($1::bigint[])) END),\012"
    .ascii " win AS MATERIALIZED (\012"
    .ascii " SELECT a.id, a.author_id FROM articles a WHERE a.id >= (SELECT min(wq.cutoff) FROM wq)),\012"
    .ascii " wc AS MATERIALIZED (\012"
    .ascii " SELECT q.ord, q.p3, q.p4, array_agg(w.id ORDER BY w.id DESC) AS ids, array_agg(w.author_id ORDER BY w.id DESC) AS aus\012"
    .ascii " FROM (SELECT r.ord, r.p3, r.p4, r.fl, wq.cutoff FROM r JOIN wq ON wq.ord = r.ord) q\012"
    .ascii " CROSS JOIN LATERAL unnest(q.fl) AS f(followee_id) JOIN win w ON w.author_id = f.followee_id AND w.id >= q.cutoff\012"
    .ascii " GROUP BY q.ord, q.p3, q.p4),\012"
    .ascii " page AS MATERIALIZED (\012"
    .ascii " SELECT wc.ord, p.id, p.author_id FROM wc\012"
    .ascii " CROSS JOIN LATERAL unnest(wc.ids[wc.p3 + 1 : wc.p4], wc.aus[wc.p3 + 1 : wc.p4]) AS p(id, author_id)\012"
    .ascii " UNION ALL\012"
    .ascii " SELECT r.ord, p.id, p.author_id FROM r LEFT JOIN sh ON sh.ord = r.ord\012"
    .ascii " CROSS JOIN LATERAL (\012"
    .ascii "   SELECT x.id, fo.followee_id AS author_id FROM unnest(r.fl) AS fo(followee_id) CROSS JOIN LATERAL (\012"
    .ascii "     SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id\012"
    .ascii "       AND a3.id >= COALESCE(sh.cutoff, '-9223372036854775808'::bigint) ORDER BY a3.id DESC LIMIT r.p4) x\012"
    .ascii "   ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3) p\012"
    .ascii " WHERE NOT EXISTS (SELECT 1 FROM wc WHERE wc.ord = r.ord)),\012"
    .ascii " ids AS MATERIALIZED (SELECT DISTINCT id FROM page),\012"
    .ascii " ea AS MATERIALIZED (\012"
    .ascii " SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id\012"
    .ascii " FROM articles a WHERE a.id = ANY(ARRAY(SELECT id FROM ids)))\012"
    .ascii "SELECT NULL::bigint AS n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, COALESCE(tg.tags, '{}'), COALESCE(fc.n, 0),\012"
    .ascii " NULL::boolean, u.username, u.bio, u.image, NULL::boolean, a.author_id,\012"
    .ascii " NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "FROM ea a\012"
    .ascii "JOIN (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY(ARRAY(SELECT DISTINCT author_id FROM ea))) u ON u.id = a.author_id\012"
    .ascii "LEFT JOIN (SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id\012"
    .ascii "           WHERE at.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY 1) tg ON tg.article_id = a.id\012"
    .ascii "LEFT JOIN (SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY 1) fc ON fc.article_id = a.id\012"
    .ascii "UNION ALL\012"
    .ascii "SELECT CASE WHEN sh.anybig THEN 1000::bigint\012"
    .ascii "   ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(r.fl) LIMIT 1000) s) END,\012"
    .ascii " NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii " COALESCE(pg.ids, '{}'),\012"
    .ascii " COALESCE(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.p1 AND f.article_id = ANY(pg.ids)), '{}'),\012"
    .ascii " COALESCE(pg.fols, '{}'), r.ord::bigint\012"
    .ascii "FROM r LEFT JOIN sh ON sh.ord = r.ord\012"
    .ascii "LEFT JOIN (SELECT p.ord, array_agg(p.id ORDER BY p.id DESC) AS ids, array_agg(p.author_id) AS fols FROM page p GROUP BY p.ord) pg ON pg.ord = r.ord"
qb_f04_shared_end:
qb_f05_batch:
    .ascii "SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,\012"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\012"
    .ascii " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),\012"
    .ascii " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),\012"
    .ascii " u.username, u.bio, u.image,\012"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.p2) q"
qb_f05_batch_end:
qb_f05_shared:
    .ascii "WITH requests AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord)),\012"
    .ascii "         e0 AS MATERIALIZED (\012"
    .ascii "         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id\012"
    .ascii "         FROM articles a WHERE a.slug IN (SELECT DISTINCT p2 FROM requests)),\012"
    .ascii "         tg AS MATERIALIZED (\012"
    .ascii "         SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id\012"
    .ascii "         WHERE at.article_id = ANY(ARRAY(SELECT id FROM e0)) GROUP BY 1),\012"
    .ascii "         e AS MATERIALIZED (\012"
    .ascii "         SELECT e0.id, e0.slug, e0.title, e0.description, e0.body, e0.created_at, e0.updated_at, e0.author_id,\012"
    .ascii "         COALESCE(tg.tags, '{}') AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = e0.id) AS fc, u.username, u.bio, u.image\012"
    .ascii "         FROM e0 JOIN users u ON u.id = e0.author_id LEFT JOIN tg ON tg.article_id = e0.id)\012"
    .ascii "         SELECT e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc,\012"
    .ascii "         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id, 0::bigint AS __request_id\012"
    .ascii "         FROM e\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT e.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = q.p1),\012"
    .ascii "         NULL, NULL, NULL,\012"
    .ascii "         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = e.author_id),\012"
    .ascii "         NULL, q.ord::bigint\012"
    .ascii "         FROM requests q JOIN e ON e.slug = q.p2"
qb_f05_shared_end:
qb_f06_batch:
    .ascii "SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,\012"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\012"
    .ascii " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),\012"
    .ascii " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),\012"
    .ascii " u.username, u.bio, u.image,\012"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = r.p2) q"
qb_f06_batch_end:
qb_f07_batch:
    .ascii "SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image,\012"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = u.id)\012"
    .ascii "FROM users u WHERE u.username = r.p2) q"
qb_f07_batch_end:
qb_f08_batch:
    .ascii "SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image FROM users WHERE id = r.p1) q"
qb_f08_batch_end:
qb_f09_batch:
    .ascii "SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::text[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image, password_hash FROM users WHERE email = r.p1) q"
qb_f09_batch_end:
qb_f10_batch:
    .ascii "SELECT NULL::bigint, q.cid, q.body, q.created_at, NULLIF(q.updated_at, q.created_at), q.username, q.bio, q.image, q.following,\012"
    .ascii " r.ord::bigint AS __request_id\012"
    .ascii "FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(p1,p2,ord)\012"
    .ascii "CROSS JOIN LATERAL (\012"
    .ascii " SELECT a.id AS aid, c.id AS cid, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,\012"
    .ascii " CASE WHEN c.id IS NULL THEN false ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = c.author_id) END AS following\012"
    .ascii " FROM articles a\012"
    .ascii " LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id\012"
    .ascii "                    ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\012"
    .ascii " LEFT JOIN users u ON u.id = c.author_id\012"
    .ascii " WHERE a.slug = r.p2 OFFSET 0) q"
qb_f10_batch_end:
qb_f10_shared:
    .ascii "WITH requests AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord)),\012"
    .ascii "         e AS MATERIALIZED (\012"
    .ascii "         SELECT a.slug, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image\012"
    .ascii "         FROM articles a\012"
    .ascii "         LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id\012"
    .ascii "                            ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\012"
    .ascii "         LEFT JOIN users u ON u.id = c.author_id\012"
    .ascii "         WHERE a.slug IN (SELECT DISTINCT p2 FROM requests)),\012"
    .ascii "         arts AS MATERIALIZED (SELECT slug, aid, array_agg(DISTINCT author_id) FILTER (WHERE author_id IS NOT NULL) AS au\012"
    .ascii "                               FROM e GROUP BY slug, aid)\012"
    .ascii "         SELECT e.aid, e.id, e.body, e.created_at, e.updated_at, e.username, e.bio, e.image, NULL::boolean, e.author_id,\012"
    .ascii "         NULL::bigint[], 0::bigint AS __request_id\012"
    .ascii "         FROM e WHERE e.id IS NOT NULL\012"
    .ascii "         UNION ALL\012"
    .ascii "         SELECT arts.aid, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,\012"
    .ascii "         ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = ANY(arts.au)),\012"
    .ascii "         q.ord::bigint\012"
    .ascii "         FROM requests q LEFT JOIN arts ON arts.slug = q.p2"
qb_f10_shared_end:

.section .note.GNU-stack,"",@progbits
