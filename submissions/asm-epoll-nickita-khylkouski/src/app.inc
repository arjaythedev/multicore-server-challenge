# app.inc: struct layouts and macros shared by the app files (main.s rt.s server.s pgio.s api.s render.s sql.s
# bcq.s writer.s). Included after defs.inc.
#
# Register convention inside worker threads: r15 always holds the current worker struct (W_*). App code never
# changes r15 after worker_main sets it, and every module preserves it (callee-saved), so it works like a
# thread pointer. The bcrypt thread and main do not use r15.

.equ SYS_prlimit64, 302
.equ SYS_setsockopt_, 54
.equ RLIMIT_NOFILE, 7
.equ SIGPIPE, 13
.equ SIG_IGN, 1
.equ EFD_NONBLOCK, 0x800
.equ EFD_CLOEXEC, 0x80000
.equ MAP_SHARED_ANON, 0x22             # MAP_PRIVATE | MAP_ANONYMOUS
.equ SYS_timerfd_create, 283
.equ SYS_timerfd_settime, 286
.equ CLOCK_MONOTONIC, 1
.equ TFD_NONBLOCK, 0x800
.equ TFD_CLOEXEC, 0x80000
.equ WR_BATCH_MAX, 128                  # writes per group (Rust writer.rs batch_limit)

# ---------------------------------------------------------------- limits
.equ MAX_HEAD, 65536
.equ MAX_BODY, 16777216
.equ MAX_WORKERS, 64
.equ MAX_RCONNS, 16                     # read connections per worker
.equ EV_BATCH, 256                      # epoll_wait events per call
.equ OUT_HEAD_ROOM, 256                 # bytes reserved before a rendered body for the HTTP head
.equ JOB_INLINE_SCR, 1024               # inline scratch bytes inside a job
.equ NCLASS, 32                         # allocator size classes (class k = 2^k bytes)

# ---------------------------------------------------------------- epoll tags (epoll_data.u64 values < 16)
.equ TAG_LISTEN, 1
.equ TAG_EVENTFD, 2
.equ TAG_TIMER, 3                       # the writer's batch-delay timerfd
# objects (pointers) start with a dword type
.equ OT_CLIENT, 1
.equ OT_PG, 2

# ---------------------------------------------------------------- worker (W_*), one per worker thread
.equ W_ID, 0
.equ W_EPFD, 8
.equ W_LFD, 16
.equ W_EVFD, 24
.equ W_DONE, 32                         # completion stack head (bcrypt thread pushes finished jobs)
.equ W_NOW, 40                          # unix seconds, refreshed after each epoll_wait
.equ W_NRD, 48                          # number of read connections
.equ W_WR, 56                           # write connection (pgconn*)
.equ W_FREE_CONN, 64                    # free list of client conns
.equ W_RR, 72                           # round-robin cursor over read connections
.equ W_EVENTS, 80                       # epoll_event array (EV_BATCH * 12 B)
.equ W_DIRTY, 88                        # singly linked list of pgconns with unsent output (PC_DIRTY_NEXT)
.equ W_READY, 96                        # client conns whose next pipelined request should be parsed (C_RNEXT list)
.equ W_GRAVE, 104                       # client conns closed this loop iteration (freed at its end)
.equ W_RDS, 128                         # MAX_RCONNS pgconn pointers
.equ W_CLS, 256                         # NCLASS free-list heads
.equ W_BQ, 512                          # read batch queues (batch.s), 12 families * 32 B
.equ W_TFD, 904                         # writer.s: batch-delay timerfd
.equ W_GZ, 912                          # gzip_compress context (GZ_CTX_SIZE; 0 when HTTP_GZIP=0)
.equ W_TURN, 920                        # egress_compress turn counter (worker-local)
.equ W_RDDUE, 928                       # readb.s: monotonic ms when a deferred read take is due (0 = none)
.equ W_RDNOW, 936                       # readb.s / server.s: scratch monotonic ms
.equ W_NDEAD, 944                       # pgio.s: this worker's Postgres connections that are down
.equ W_RETRY, 952                       # pgio.s: monotonic ms before which no reconnect is tried
.equ W_RSIG, 960                        # readb.s: workers whose eventfd rb_signal writes (bit = W_ID, worker-local)
.equ W_ACCOFF, 976                      # server.s: monotonic ms when accepting resumes after accept4 failed (0 = on)
.equ W_KEEPN, 984                       # rt.s: blocks on the class 17..20 free lists (4 dwords, 984..999)
.equ W_SIZE, 1024

# ---------------------------------------------------------------- client connection (C_*), 128 B
.equ C_TYPE, 0                          # dword OT_CLIENT
.equ C_FD, 4                            # dword
.equ C_FLAGS, 8
.equ C_IN, 16                           # input buffer (0 when no request bytes are pending)
.equ C_INLEN, 24
.equ C_INCAP, 32
.equ C_OUT, 40                          # parked output buffer (0 = none)
.equ C_OUTPOS, 48                       # next byte to send
.equ C_OUTEND, 56
.equ C_OUTCAP, 64
.equ C_JOB, 72                          # request in flight (0 = none)
.equ C_NEXT, 80                         # free list / graveyard link
.equ C_REQEND, 88                       # bytes of C_IN consumed by the request in flight
.equ C_RNEXT, 96                        # W_READY list link
.equ C_SIZE, 128
.equ CF_EOF, 1                          # peer closed its side
.equ CF_CLOSE, 2                        # close after the pending output is sent
.equ CF_DEAD, 4                         # fd closed; free the struct when the job finishes
.equ CF_READY, 8                        # on the W_READY list
.equ CF_CONT, 32                        # "100 Continue" already sent for the request being read
.equ CF_HEADM, 64                       # the request in flight is a HEAD: send the response head only

# ---------------------------------------------------------------- Postgres connection (PC_*), 256 B
.equ PC_TYPE, 0                         # dword OT_PG
.equ PC_FD, 4
.equ PC_OUT, 8                          # pgbuf {ptr, len, cap} at 8/16/24
.equ PC_OUTSENT, 32                     # bytes of the output already written
.equ PC_IN, 40                          # input buffer
.equ PC_INLEN, 48
.equ PC_INCAP, 56
.equ PC_INPOS, 64                       # start of the unprocessed input (first message of the head op)
.equ PC_SCAN, 72                        # parse cursor (>= PC_INPOS)
.equ PC_QHEAD, 80                       # FIFO of ops waiting for their ReadyForQuery
.equ PC_QTAIL, 88
.equ PC_NQ, 96                          # ops in the FIFO
.equ PC_DIRTY_NEXT, 104
.equ PC_FLAGS, 112
.equ PC_KIND, 120                       # 0 read, 1 write
.equ PC_IDX, 128                        # index among the worker's read conns
.equ PC_WPEND, 136                      # write conn (writer.s): jobs waiting for the next group, J_WNEXT links
.equ PC_WPTAIL, 144
.equ PC_WNPEND, 152
.equ PC_WBUSY, 160                      # 1 while a group, a single write or a retry pass is on the connection
.equ PC_WTIMER, 168                     # batch delay: 0 off, 1 armed (waiting), 2 expired
.equ PC_GJOBS, 176                      # the group in flight, in order (J_WNEXT links)
.equ PC_GN, 184                         # jobs in the group; during a retry pass, retries still outstanding
.equ PC_GERR, 192                       # GE_* bits
.equ PC_GBEGIN, 200                     # op for the group's BEGIN (OP_NEXT/OP_CONT, 16 B)
.equ PC_GCOMMIT, 216                    # op for the group's COMMIT (16 B)
.equ PC_SIZE, 256
.equ PCF_DIRTY, 1
.equ PCF_DEAD, 2
.equ GE_STMT, 1                         # a statement in the group failed (the COMMIT rolls back)
.equ GE_BEGIN, 2                        # BEGIN failed
.equ GE_DEAD, 4                         # the connection died

# ---------------------------------------------------------------- pg op: anything queued on a pgconn.
# A job (request) is an op; batches and BEGIN/COMMIT markers are ops too. The op's continuation is called as
#   cont(op, seg_ptr, seg_len)   with the bytes of all its backend messages through ReadyForQuery,
# or seg_len = -1 if the connection failed.
.equ OP_NEXT, 0                         # FIFO link on the pgconn
.equ OP_CONT, 8                         # continuation

# ---------------------------------------------------------------- job (J_*): one HTTP request in flight, 2048 B
.equ J_NEXT, 0                          # = OP_NEXT
.equ J_CONT, 8                          # = OP_CONT
.equ J_CONN, 16
.equ J_EP, 24                           # endpoint id (EP_*)
.equ J_VIEWER, 32
.equ J_TOK, 40                          # presented token (ptr/len into the conn's input)
.equ J_TOKLEN, 48
.equ J_STMT, 56                         # statement index (S_*)
.equ J_NP, 64                           # number of params
.equ J_ID, 72                           # saved id (article id after a write ...)
.equ J_FLAG, 80                         # endpoint-specific flag (follow on/off ...)
.equ J_SCR, 88                          # scratch buffer for decoded strings: ptr, used, cap
.equ J_SCRUSED, 96
.equ J_SCRCAP, 104
.equ J_SCRALLOC, 112                    # nonzero if J_SCR was allocated (cap = J_SCRCAP)
.equ J_OUT, 120                         # rendered response buffer: ptr, start, end, cap
.equ J_OUTSTART, 128
.equ J_OUTEND, 136
.equ J_OUTCAP, 144
.equ J_STATUS, 152
.equ J_WORKER, 160
.equ J_T0, 168                          # submit time (bcrypt shedding), unix seconds
.equ J_BNEXT, 176                       # batch/group-commit link
.equ J_ORD, 184                         # position inside a read batch (1-based)
.equ J_FAM, 192                         # read family (RK_*)
.equ J_PT, 200                          # param types, 8 bytes (PT_*)
.equ J_P, 256                           # params: 8 x {ptr|value, len} (len -1 = NULL)
.equ J_BC, 384                          # bcrypt job (BCJ_SIZE = 64)
.equ J_HASH, 448                        # bcrypt hash output (60 B, padded to 64)
.equ J_SALT, 512                        # 16 B
.equ J_STORED, 528                      # stored hash copy (login), 64 B
.equ J_STOREDLEN, 592
.equ J_SQLSTATE, 600
.equ J_BCKIND, 608                      # 1 verify, 2 hash
.equ J_TAGS, 616                        # tag list: ptr to {ptr,len} pairs, count at J_NTAGS
.equ J_NTAGS, 624
.equ J_CLOSE, 632                       # 1: answer with Connection: close
.equ J_REQ, 640                         # copy of the parsed request (REQ_SIZE = 80)
.equ J_SEG, 720                         # path segments after /api/: 4 x {ptr, len} (decoded)
.equ J_NSEG, 784
.equ J_QV, 792                          # query values limit/offset/tag/author/favorited: 5 x {ptr, len}, len -1 = absent
.equ J_PW, 872                          # password (decoded) for bcrypt
.equ J_PWLEN, 880
.equ J_BUSY, 888                        # bcrypt thread shed the job (503)
.equ J_WCONT, 896                       # writer.s: the endpoint's continuation while the writer holds the job
.equ J_WNEXT, 904                       # writer.s: pending / group link
.equ J_WSEG, 912                        # writer.s: copied reply segment of a grouped write (block; cap at +0)
.equ J_WSEGLEN, 920                     # its length (-1 conn died, -2 the statement failed)
.equ J_RCONT, 928                       # readb.s, a job answered on another worker: its J_CONT while rb_remote holds it
.equ J_RACT, 936                        # what rb_remote does (RA_*)
.equ J_RA, 944                          # its argument: the reply / rows (in a block or the shared copy)
.equ J_RCAP, 952                        # cap of the block J_RA to free (0 = none)
.equ J_RB, 960                          # length / row count
.equ J_RFN, 968                         # renderer (RA_RENDER)
.equ J_RSH, 976                         # shared reply copy to drop (0 = none)
.equ J_RW, 984                          # the worker that posted it (allocated J_RA)
.equ J_WRUN, 1016                       # writer.s: jobs in a merged run (on the run's first job)
.equ J_INL, 1024                        # inline scratch (JOB_INLINE_SCR bytes)
.equ J_SIZE, 2048

.equ PT_TEXT, 0
.equ PT_INT8, 1
.equ PT_TEXTARR, 2                      # p.ptr = array of {ptr,len}, p.len = count

# ---------------------------------------------------------------- endpoints
.equ EP_TAGS, 1
.equ EP_REGISTER, 2
.equ EP_LOGIN, 3
.equ EP_USER, 4
.equ EP_UPD_USER, 5
.equ EP_PROFILE, 6
.equ EP_FOLLOW, 7
.equ EP_LIST, 8
.equ EP_CREATE, 9
.equ EP_FEED, 10
.equ EP_ARTICLE, 11
.equ EP_UPD_ART, 12
.equ EP_DEL_ART, 13
.equ EP_FAVORITE, 14
.equ EP_COMMENTS, 15
.equ EP_ADD_COMMENT, 16
.equ EP_DEL_COMMENT, 17

# ---------------------------------------------------------------- read families (Rust ReadKind order)
.equ RK_ALL, 0
.equ RK_TAG, 1
.equ RK_AUTHOR, 2
.equ RK_FAVORITED, 3
.equ RK_FEED, 4
.equ RK_SLUG, 5
.equ RK_ID, 6
.equ RK_PROFILE, 7
.equ RK_USERID, 8
.equ RK_EMAIL, 9
.equ RK_COMMENTS, 10
.equ RK_TAGS, 11
.equ RK_COUNT, 12

# ---------------------------------------------------------------- statements (sql.s table order)
.equ S_LIST_ALL, 0
.equ S_LIST_TAG, 1
.equ S_LIST_AUTHOR, 2
.equ S_LIST_FAVORITED, 3
.equ S_LIST_FEED, 4
.equ S_ARTICLE_SLUG, 5
.equ S_ARTICLE_ID, 6
.equ S_PROFILE, 7
.equ S_USER_ID, 8
.equ S_USER_EMAIL, 9
.equ S_COMMENTS, 10
.equ S_TAGS, 11
.equ S_FAVORITE, 12
.equ S_UNFAVORITE, 13
.equ S_ARTICLE_CREATE, 14
.equ S_ARTICLE_UPDATE, 15
.equ S_ARTICLE_DELETE, 16
.equ S_COMMENT_CREATE, 17
.equ S_COMMENT_DELETE, 18
.equ S_FOLLOW, 19
.equ S_UNFOLLOW, 20
.equ S_USER_INSERT, 21
.equ S_USER_UPDATE, 22
.equ S_FAVORITE_N, 23                   # merged runs of the writes above (writer.s)
.equ S_UNFAVORITE_N, 24
.equ S_FOLLOW_N, 25
.equ S_UNFOLLOW_N, 26
.equ S_COMMENT_CREATE_N, 27

# ---------------------------------------------------------------- macros
# DEFSTR name, "text": defines `name` and `name_len`.
.macro DEFSTR name, text
\name: .ascii "\text"
.equ \name\()_len, . - \name
.endm

# PUTL lit: append the rodata literal `lit` (length `lit_len`) at rdi; rdi = new end. Clobbers rax rcx rsi rdx.
.macro PUTL lit
    lea rsi, [rip + \lit]
    mov edx, \lit\()_len
    call rt_memcpy
    mov rdi, rax
.endm

# PUTC byte: append one byte at rdi.
.macro PUTC c
    mov byte ptr [rdi], \c
    inc rdi
.endm

# ENDLIT name: after `name: .ascii "..."`, defines name_len.
.macro ENDLIT name
.equ \name\()_len, . - \name
.endm

# PUTL_R reg, lit: like PUTL but the output cursor lives in \reg (not rdi); updates \reg to the new end.
# Call only where rsp is 16-aligned (it calls rt_memcpy). Clobbers rax rcx rsi rdx rdi.
.macro PUTL_R reg, lit
    mov rdi, \reg
    lea rsi, [rip + \lit]
    mov edx, \lit\()_len
    call rt_memcpy
    mov \reg, rax
.endm

# OPT_FIELD key, slot, non_empty: an optional body field (rbx = job, body object at objlen=[rsp], obj=[rsp+8],
# inside a `sub rsp, 24` endpoint frame). None -> param NULL; a value -> param TEXT; a 422 -> unwind and return.
.macro OPT_FIELD key, slot, non_empty
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + \key]
    mov ecx, \key\()_len
    mov r8d, \non_empty
    call optional
    jnc 1f
    add rsp, 24
    ret
1:  cmp rdx, -1
    jne 2f
    mov qword ptr [rbx + J_P + (\slot)*16], 0
    mov qword ptr [rbx + J_P + (\slot)*16 + 8], -1
    mov byte ptr [rbx + J_PT + (\slot)], PT_TEXT
    jmp 3f
2:  mov [rbx + J_P + (\slot)*16], rax
    mov [rbx + J_P + (\slot)*16 + 8], rdx
    mov byte ptr [rbx + J_PT + (\slot)], PT_TEXT
3:
.endm
