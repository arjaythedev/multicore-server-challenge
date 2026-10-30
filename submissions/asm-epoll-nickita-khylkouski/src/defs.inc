# defs.inc: shared constants for every module (GNU as, Intel syntax).
# Append-only: add new lines inside your own module's section at the end; never change existing lines.

.intel_syntax noprefix

# ---------------------------------------------------------------- Linux x86-64 syscall numbers
.equ SYS_read,            0
.equ SYS_write,           1
.equ SYS_close,           3
.equ SYS_fstat,           5
.equ SYS_mmap,            9
.equ SYS_mprotect,        10
.equ SYS_munmap,          11
.equ SYS_brk,             12
.equ SYS_rt_sigaction,    13
.equ SYS_rt_sigprocmask,  14
.equ SYS_ioctl,           16
.equ SYS_writev,          20
.equ SYS_sched_yield,     24
.equ SYS_madvise,         28
.equ SYS_nanosleep,       35
.equ SYS_getpid,          39
.equ SYS_socket,          41
.equ SYS_connect,         42
.equ SYS_accept,          43
.equ SYS_sendto,          44
.equ SYS_recvfrom,        45
.equ SYS_shutdown,        48
.equ SYS_bind,            49
.equ SYS_listen,          50
.equ SYS_setsockopt,      54
.equ SYS_getsockopt,      55
.equ SYS_clone,           56
.equ SYS_exit,            60
.equ SYS_fcntl,           72
.equ SYS_gettid,          186
.equ SYS_futex,           202
.equ SYS_sched_setscheduler, 144
.equ SYS_sched_getaffinity, 204
.equ SYS_epoll_wait,      232
.equ SYS_epoll_ctl,       233
.equ SYS_exit_group,      231
.equ SYS_clock_gettime,   228
.equ SYS_accept4,         288
.equ SYS_eventfd2,        290
.equ SYS_epoll_create1,   291
.equ SYS_getrandom,       318

# ---------------------------------------------------------------- errno (returned negated by syscalls)
.equ EINTR,   4
.equ EAGAIN,  11
.equ ENOMEM,  12
.equ EINPROGRESS, 115

# ---------------------------------------------------------------- misc kernel constants
.equ AF_INET, 2
.equ SOCK_STREAM, 1
.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC, 0x80000
.equ IPPROTO_TCP, 6
.equ SOL_SOCKET, 1
.equ SO_REUSEADDR, 2
.equ SO_REUSEPORT, 15
.equ SO_RCVTIMEO, 20
.equ SO_SNDTIMEO, 21
.equ TCP_NODELAY, 1
.equ F_GETFL, 3
.equ F_SETFL, 4
.equ O_NONBLOCK, 0x800
.equ EPOLL_CTL_ADD, 1
.equ EPOLL_CTL_DEL, 2
.equ EPOLL_CTL_MOD, 3
.equ EPOLLIN, 0x001
.equ EPOLLOUT, 0x004
.equ EPOLLERR, 0x008
.equ EPOLLHUP, 0x010
.equ EPOLLRDHUP, 0x2000
.equ EPOLLET, 0x80000000
.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_PRIVATE, 0x02
.equ MAP_ANONYMOUS, 0x20
.equ MAP_NORESERVE, 0x4000
.equ MAP_STACK, 0x20000
.equ CLOCK_REALTIME, 0
.equ CLOCK_MONOTONIC, 1
.equ FUTEX_WAIT_PRIVATE, 128
.equ FUTEX_WAKE_PRIVATE, 129
.equ SCHED_BATCH, 3                     # sched_setscheduler policy
.equ CLONE_THREAD_FLAGS, 0x00050f00   # CLONE_VM|FS|FILES|SIGHAND (0xf00) | CLONE_THREAD 0x10000 | CLONE_SYSVSEM 0x40000
.equ CLONE_SYSVSEM, 0x40000

# ---------------------------------------------------------------- CPU features (cpu.s: cpu_detect sets cpu_features)
.equ CPU_SHA,     1          # SHA-NI (CPUID.7.0:EBX bit 29)
.equ CPU_AVX2,    2          # AVX2 (+ OS XSAVE support for ymm)
.equ CPU_BMI2,    4
.equ CPU_AVX512,  8          # AVX-512 F+BW+VL (+ OS support for zmm/opmask)
.equ CPU_SSE42,   16

# ---------------------------------------------------------------- common macros
# SYS nr: rdi, rsi, rdx, r10, r8, r9 are args; clobbers rcx, r11; result in rax (-errno on error).
# (Not named SYSCALL: GAS macro names are case-insensitive, so it would shadow the `syscall` mnemonic.)
.macro SYS nr
    mov eax, \nr
    syscall
.endm

# ---------------------------------------------------------------- pg.s: pgbuf {ptr, len, cap}
.equ PGB_PTR, 0
.equ PGB_LEN, 8
.equ PGB_CAP, 16
.equ PGB_SIZE, 24
# pg_url_parse output (strings point into the url buffer or into the cfg's own decode area)
.equ PGC_USER, 0             # ptr
.equ PGC_USER_LEN, 8
.equ PGC_PASS, 16
.equ PGC_PASS_LEN, 24
.equ PGC_HOST, 32
.equ PGC_HOST_LEN, 40
.equ PGC_DB, 48
.equ PGC_DB_LEN, 56
.equ PGC_PORT, 64            # u16 in a qword
.equ PGC_ADDR, 72            # IPv4 address, network byte order (filled by pg_url_parse), dword
.equ PGC_BUF, 80             # 512-byte scratch for percent-decoded fields
.equ PGC_SIZE, 592
.equ OID_INT8, 20
.equ OID_TEXT, 25
.equ OID_BOOL, 16
.equ OID_INT4, 23

# ---------------------------------------------------------------- http.s: parsed request
.equ M_OTHER, 0
.equ M_GET, 1
.equ M_POST, 2
.equ M_PUT, 3
.equ M_DELETE, 4
.equ REQ_METHOD, 0           # qword method id
.equ REQ_PATH, 8             # ptr
.equ REQ_PATH_LEN, 16
.equ REQ_QUERY, 24           # ptr (0 if no '?')
.equ REQ_QUERY_LEN, 32
.equ REQ_AUTH, 40            # ptr to Authorization header value (0 if absent)
.equ REQ_AUTH_LEN, 48
.equ REQ_BODY, 56            # ptr
.equ REQ_BODY_LEN, 64
.equ REQ_FLAGS, 72
.equ REQ_SIZE, 80
.equ REQF_CLOSE, 1           # client asked for Connection: close (or HTTP/1.0 without keep-alive)
.equ HW_CLOSE, 1             # http_write_head flag: add Connection: close

# ---------------------------------------------------------------- json.s: value types
.equ JT_NONE, 0
.equ JT_STRING, 1
.equ JT_NUMBER, 2
.equ JT_TRUE, 3
.equ JT_FALSE, 4
.equ JT_NULL, 5
.equ JT_OBJECT, 6
.equ JT_ARRAY, 7
.equ JIT_SIZE, 32            # json_arr_* iterator size

# ---------------------------------------------------------------- pg.s array iterator
.equ PAIT_SIZE, 32

# ---------------------------------------------------------------- bcrypt.s: batch job (64 B)
.equ BCJ_PW, 0               # ptr
.equ BCJ_PW_LEN, 8
.equ BCJ_HASH, 16            # verify: ptr to stored hash; hash: ptr to 16-byte raw salt
.equ BCJ_HASH_LEN, 24        # verify: stored hash length; hash: cost
.equ BCJ_OUT, 32             # hash: ptr to 60-byte output
.equ BCJ_RESULT, 40          # verify: 1 match / 0 no
.equ BCJ_SIZE, 64
.equ BCRYPT_LANES, 8         # max n for the *_batch functions

# ---------------------------------------------------------------- (append module sections below)

# ---------------------------------------------------------------- crypto.s
.equ HMAC_CTX_SIZE, 64       # crypto_hmac_init ctx: inner state (32 B) | outer state (32 B)
.equ JWT_SIGN_MAX, 200       # crypto_jwt_sign writes at most this many bytes (193 worst case)
.equ JWT_MAX_TOKEN, 8192     # crypto_jwt_verify rejects longer tokens; it needs ~8.5 KB of stack

# ---------------------------------------------------------------- pg.s
# pgd_array_* iterator fields (PAIT_SIZE above)
.equ PAIT_CUR, 0             # next element header
.equ PAIT_END, 8             # end of the array value
.equ PAIT_LEFT, 16           # elements not yet returned
.equ PAIT_COUNT, 24          # total element count (product of dims)
# pg_connect error codes (negated in rax)
.equ PG_ERR_AUTH, 13         # EACCES: ErrorResponse during startup, or SCRAM verification failed
.equ PG_ERR_PROTO, 71        # EPROTO: unexpected message / unsupported auth method
.equ PG_ERR_EOF, 104         # ECONNRESET: server closed the connection
# pgr_error_sqlstate values (5 ASCII bytes, little-endian)
.equ SQLSTATE_UNIQUE_VIOLATION, 0x3530353332      # 23505
.equ SQLSTATE_FK_VIOLATION, 0x3330353332          # 23503
.equ SQLSTATE_NOT_NULL_VIOLATION, 0x3230353332    # 23502
.equ SQLSTATE_CHECK_VIOLATION, 0x3431353332       # 23514
.equ SQLSTATE_SERIALIZATION_FAILURE, 0x3130303034 # 40001
.equ SQLSTATE_DEADLOCK, 0x3130503034              # 40P01
.equ SQLSTATE_IN_FAILED_TX, 0x3230503532          # 25P02 ("current transaction is aborted")

# ---------------------------------------------------------------- http.s
.equ HTTP_MAX_HEAD, 65536    # request head limit, as the Rust server (larger -> http_parse returns -2)
.equ HTTP_MAX_BODY, 16777216 # body limit (Content-Length or decoded chunked size; larger -> -2)
.equ HTTP_MAX_HEADERS, 64    # httparse's limit in the Rust server; the 65th header line -> -1
.equ HTTP_HEAD_SPACE, 160    # http_write_head needs this many writable bytes at dst (writes <= 127)
.equ REQF_EXPECT, 2          # Expect: 100-continue (send http_write_continue before the response)
.equ REQF_CHUNKED, 4         # body was Transfer-Encoding: chunked (decoded in place at REQ_BODY)
.equ REQF_HAS_CL, 8          # a Content-Length header was present
.equ REQF_HEAD_DONE, 16      # with return 0: the head parsed fine, only body bytes are missing
.equ REQF_HTTP10, 32         # request line said HTTP/1.0
.equ PCT_PLUS, 1             # http_pct_decode flags: '+' -> ' '
.equ PCT_LENIENT, 2          #   a '%' without two hex digits is kept literally (else -1)
.equ PCT_UTF8, 4             #   result must be valid UTF-8 (else -1)
.equ PCT_LOSSY, 8            #   invalid UTF-8 -> U+FFFD (dst needs 3 * len bytes)
.equ PCT_PATH, 6             #   = LENIENT | UTF8: Rust's path segments (invalid UTF-8 -> 404 there)
.equ PCT_QUERY, 11           #   = PLUS | LENIENT | LOSSY: Rust's query values (form_urlencoded)

# ---------------------------------------------------------------- bcrypt.s
# Per-lane Eksblowfish context (also used standalone for single-lane hashes).
.equ BCX_S,    0          # S-boxes S[4][256], 4096 bytes (flat 1024 words)
.equ BCX_P,    4096       # P-array P[18], 72 bytes
.equ BCX_EK,   4168       # expanded_key[18], 72 bytes
.equ BCX_SALT, 4240       # salt words [4] (big-endian), 16 bytes
.equ BCX_OUT,  4256       # output words [6], 24 bytes
.equ BCX_SIZE, 4352       # stride between lanes (multiple of 64)
# bcrypt subtype flags (BF_set_key): bit0 = sign-extension bug, bit1 = anti-collision safety
.equ BCF_2A,   2          # $2a$: safety on
.equ BCF_2B,   4          # $2b$: no bug/safety (nonzero marker)
.equ BCF_2Y,   4          # $2y$: no bug/safety

# ---------------------------------------------------------------- http.s / egress.s, part 2
# (HTTP_HEAD_SPACE above still holds with HW_GZIP: the longest head is now 151 bytes, writes stay within 160.)
.equ REQF_GZIP, 64           # Accept-Encoding allows gzip (Rust's accepts_gzip, any of the headers)
.equ HW_GZIP, 2              # http_write_head flag: add Content-Encoding: gzip after Content-Type
.equ HTTP_GZIP_MIN, 1024     # bodies this large may be compressed (Rust's GZIP_MIN)
.equ EG_OFF, 0               # egress_init modes: HTTP_GZIP=0
.equ EG_ALWAYS, 1            #   HTTP_GZIP=1
.equ EG_ABOVE, 2             #   anything else: adaptive (egress_sent counts bytes)
.equ SYS_open, 2
.equ SYS_pread64, 17
.equ O_RDONLY, 0
.equ O_CLOEXEC, 0x80000
.equ AT_SYSINFO_EHDR, 33

# ---------------------------------------------------------------- gzip.s
.equ GZ_CTX_SIZE, 334848     # gzip_compress per-thread state (gzip_init it once; 64-byte aligned)
