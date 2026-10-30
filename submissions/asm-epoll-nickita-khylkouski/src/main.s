# main.s: process entry. Reads the environment, sets process-wide state (read-only once threads start),
# then starts the bcrypt thread(s) and the worker threads and parks the main thread.
#
# Environment: DATABASE_URL, JWT_SECRET (required); HOST (127.0.0.1), PORT (3000); tuning: APP_THREADS
# (min(ceil(cores/4), 8)), DB_READ_CONNS (read connections per worker, 3), BCRYPT_THREADS (min(ceil(cores/4), 2); one main + helpers),
# WRITE_BATCH_US (group-commit wait for a lone write, 1000; 0 = none), BCRYPT_BATCH_MS (bcrypt lane-fill wait,
# 150; 0 = none), READ_BATCH_MS (read gather wait, 0 = none), READ_SHARE_PCT (article-by-slug share rule, 100),
# SCHED_BATCH (every thread under the SCHED_BATCH policy, 1; 0 = the default policy).
.include "defs.inc"
.include "app.inc"

.bss
.balign 64
.globl g_pgcfg
g_pgcfg:     .skip PGC_SIZE              # parsed DATABASE_URL
.globl g_jwt
g_jwt:       .skip HMAC_CTX_SIZE         # HMAC context for JWT_SECRET
.globl g_addr
g_addr:      .quad 0                     # listen IPv4 address, network byte order (low dword)
.globl g_port
g_port:      .quad 0                     # listen port (host order)
.globl g_nworkers
g_nworkers:  .quad 0
.globl g_nread
g_nread:     .quad 0                     # read connections per worker
.globl g_nbcrypt
g_nbcrypt:   .quad 0
.globl g_cores
g_cores:     .quad 0
g_envp:      .quad 0
.globl g_egmode
g_egmode:    .quad 0                     # egress_init mode (EG_OFF: no gzip contexts)
g_park:      .long 0
.balign 8
.globl g_workers
g_workers:   .skip 8 * MAX_WORKERS

.section .rodata
.Lenv_db:      .ascii "DATABASE_URL"
.Lenv_jwt:     .ascii "JWT_SECRET"
.Lenv_host:    .ascii "HOST"
.Lenv_port:    .ascii "PORT"
.Lenv_threads: .ascii "APP_THREADS"
.Lenv_nread:   .ascii "DB_READ_CONNS"
.Lenv_bcrypt:  .ascii "BCRYPT_THREADS"
.Lenv_wbatch:  .ascii "WRITE_BATCH_US"
.Lenv_bfill:   .ascii "BCRYPT_BATCH_MS"
.Lenv_rwait:   .ascii "READ_BATCH_MS"
.Lenv_rshare:  .ascii "READ_SHARE_PCT"
.Lenv_sbatch:  .ascii "SCHED_BATCH"
    .skip 53, 0                     # padding: keeps what follows at its previous 64-byte alignment
.Lstr_localhost: .ascii "localhost"
DEFSTR .Lmsg_nodb, "DATABASE_URL must be set\n"
DEFSTR .Lmsg_nojwt, "JWT_SECRET must be set\n"
DEFSTR .Lmsg_badurl, "DATABASE_URL is invalid\n"
DEFSTR .Lmsg_badhost, "HOST must be an IPv4 address\n"
DEFSTR .Lmsg_badnum, "invalid numeric environment variable\n"
DEFSTR .Lmsg_toomany, "1..=95 total database connections (APP_THREADS * (DB_READ_CONNS + 1))\n"


.text
.globl _start
_start:
    mov rax, [rsp]                       # argc
    lea rcx, [rsp + 8 + rax*8 + 8]       # envp = argv + argc + 1
    mov [rip + g_envp], rcx
    and rsp, -16
    call main
    mov edi, eax
    SYS SYS_exit_group

# getenv(name, namelen) -> rax = value ptr (0 if unset), rdx = value length.
getenv:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + g_envp]
.Lge_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lge_none
    add rbx, 8
    # compare name then '='
    xor ecx, ecx
.Lge_cmp:
    cmp rcx, r13
    je .Lge_eq
    mov al, [rdi + rcx]
    cmp al, [r12 + rcx]
    jne .Lge_loop
    inc rcx
    jmp .Lge_cmp
.Lge_eq:
    cmp byte ptr [rdi + rcx], '='
    jne .Lge_loop
    lea rax, [rdi + rcx + 1]
    mov rdx, rax
.Lge_len:
    cmp byte ptr [rdx], 0
    je .Lge_found
    inc rdx
    jmp .Lge_len
.Lge_found:
    sub rdx, rax
    jmp .Lge_ret
.Lge_none:
    xor eax, eax
    xor edx, edx
.Lge_ret:
    pop r13
    pop r12
    pop rbx
    ret

# env_uint(name, namelen, default) -> rax: a positive integer variable, or default if unset/empty.
env_uint:
    push rbx
    mov rbx, rdx
    call getenv
    test rax, rax
    jz 1f
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jz 2f
    test rax, rax
    jz 2f
    pop rbx
    ret
1:  mov rax, rbx
    pop rbx
    ret
2:  lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die

# parse_ipv4(ptr, len) -> rax = address in network byte order, rdx = 1 ok / 0 bad. "localhost" = 127.0.0.1.
parse_ipv4:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lstr_localhost]
    mov ecx, 9
    call rt_memeq
    test eax, eax
    jz 1f
    mov eax, 0x0100007f
    mov edx, 1
    jmp .Lip_ret
1:  xor r8d, r8d                         # result (bytes in memory order)
    xor r9d, r9d                         # octet index
    xor r10d, r10d                       # current octet value
    xor r11d, r11d                       # digits in current octet
    lea rsi, [rbx + r12]
.Lip_loop:
    cmp rbx, rsi
    je .Lip_end
    movzx eax, byte ptr [rbx]
    inc rbx
    cmp al, '.'
    je .Lip_dot
    sub eax, '0'
    cmp eax, 9
    ja .Lip_bad
    imul r10d, r10d, 10
    add r10d, eax
    inc r11d
    cmp r10d, 255
    ja .Lip_bad
    cmp r11d, 3
    ja .Lip_bad
    jmp .Lip_loop
.Lip_dot:
    test r11d, r11d
    jz .Lip_bad
    cmp r9d, 3
    jae .Lip_bad
    lea ecx, [r9*8]
    shl r10d, cl
    or r8d, r10d
    inc r9d
    xor r10d, r10d
    xor r11d, r11d
    jmp .Lip_loop
.Lip_end:
    test r11d, r11d
    jz .Lip_bad
    cmp r9d, 3
    jne .Lip_bad
    shl r10d, 24
    or r8d, r10d
    mov eax, r8d
    mov edx, 1
    jmp .Lip_ret
.Lip_bad:
    xor eax, eax
    xor edx, edx
.Lip_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# count_cpus() -> rax = CPUs in this process's affinity mask (>= 1).
count_cpus:
    sub rsp, 136                         # 128-byte mask (1024 CPUs)
    xor edi, edi
    mov esi, 128
    mov rdx, rsp
    SYS SYS_sched_getaffinity
    test rax, rax
    jle 2f
    mov rcx, rax                         # bytes written
    xor eax, eax
    xor edx, edx
1:  cmp rdx, rcx
    jae 3f
    popcnt r8, qword ptr [rsp + rdx]
    add rax, r8
    add rdx, 8
    jmp 1b
3:  test rax, rax
    jnz 4f
2:  mov eax, 1
4:  add rsp, 136
    ret

# Mandatory env var: rax = ptr, rdx = len, or die with "<NAME> must be set".
.macro REQUIRE_ENV name, namelen, msg, msglen
    lea rdi, [rip + \name]
    mov esi, \namelen
    call getenv
    test rax, rax
    jnz 9f
    lea rdi, [rip + \msg]
    mov esi, \msglen
    call rt_die
9:
.endm

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                          # 8 + 5*8 + 32 = 80: aligned
    call cpu_detect
    call crypto_init

    # SIGPIPE: ignore (a peer that closed early must not kill the process). struct k_sigaction = 32 bytes.
    mov qword ptr [rsp], SIG_IGN
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    mov edi, SIGPIPE
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    SYS SYS_rt_sigaction

    # RLIMIT_NOFILE: soft = hard (250k connections)
    xor edi, edi
    mov esi, RLIMIT_NOFILE
    xor edx, edx
    mov r10, rsp                         # old -> [rsp] = soft, [rsp+8] = hard
    SYS SYS_prlimit64
    test rax, rax
    jnz 1f
    mov rax, [rsp + 8]
    mov [rsp], rax
    xor edi, edi
    mov esi, RLIMIT_NOFILE
    mov rdx, rsp
    xor r10d, r10d
    SYS SYS_prlimit64
1:
    REQUIRE_ENV .Lenv_db, 12, .Lmsg_nodb, .Lmsg_nodb_len
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + g_pgcfg]
    call pg_url_parse
    test rax, rax
    jz 2f
    lea rdi, [rip + .Lmsg_badurl]
    mov esi, .Lmsg_badurl_len
    call rt_die
2:
    REQUIRE_ENV .Lenv_jwt, 10, .Lmsg_nojwt, .Lmsg_nojwt_len
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + g_jwt]
    call crypto_hmac_init

    # HOST / PORT
    mov dword ptr [rip + g_addr], 0x0100007f
    lea rdi, [rip + .Lenv_host]
    mov esi, 4
    call getenv
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call parse_ipv4
    test edx, edx
    jnz 4f
    lea rdi, [rip + .Lmsg_badhost]
    mov esi, .Lmsg_badhost_len
    call rt_die
4:  mov [rip + g_addr], eax
3:  lea rdi, [rip + .Lenv_port]
    mov esi, 4
    mov edx, 3000
    call env_uint
    cmp rax, 65535
    jbe 5f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
5:  mov [rip + g_port], rax

    # thread counts
    call count_cpus
    mov [rip + g_cores], rax
    lea rdx, [rax + 3]
    shr rdx, 2                           # ceil(cores/4), at most 8
    cmp rdx, 8
    jbe 6f
    mov edx, 8
6:  lea rdi, [rip + .Lenv_threads]
    mov esi, 11
    call env_uint
    cmp rax, MAX_WORKERS
    jbe 7f
    mov eax, MAX_WORKERS
7:  mov [rip + g_nworkers], rax
    lea rdi, [rip + .Lenv_nread]
    mov esi, 13
    mov edx, 3
    call env_uint
    cmp rax, MAX_RCONNS
    jbe 8f
    mov eax, MAX_RCONNS
8:  mov [rip + g_nread], rax
    lea rcx, [rax + 1]                   # each worker: g_nread read connections + 1 write connection
    imul rcx, [rip + g_nworkers]
    cmp rcx, 95
    jbe 9f
    lea rdi, [rip + .Lmsg_toomany]
    mov esi, .Lmsg_toomany_len
    call rt_die
9:
    mov rdx, [rip + g_cores]
    add rdx, 3
    shr rdx, 2                           # ceil(cores/4), at most 2: one hand-off is pending at a time
    cmp rdx, 2
    jbe 1f
    mov edx, 2
1:
    lea rdi, [rip + .Lenv_bcrypt]
    mov esi, 14
    call env_uint
    mov [rip + g_nbcrypt], rax
    # WRITE_BATCH_US: group-commit wait when one write is pending (default 1000 in writer.s; 0 = none)
    lea rdi, [rip + .Lenv_wbatch]
    mov esi, 14
    call getenv
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jnz 10f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
10: mov [rip + g_wdelay_us], rax
9:
    # BCRYPT_BATCH_MS: how long a lone login may wait for others to share its bcrypt run (bcq.s; 0 = none)
    lea rdi, [rip + .Lenv_bfill]
    mov esi, 15
    call getenv
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jnz 10f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
10: mov [rip + g_bc_fill_ms], rax
9:
    # READ_BATCH_MS: how long the oldest queued read may wait for others to share its batch (readb.s; 0 = none)
    lea rdi, [rip + .Lenv_rwait]
    mov esi, 13
    call getenv
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jnz 10f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
10: mov [rip + g_rd_wait_ms], rax
9:
    # READ_SHARE_PCT: an article-by-slug take uses its shared statement when distinct slugs <= n * pct / 100
    lea rdi, [rip + .Lenv_rshare]
    mov esi, 14
    call getenv
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jnz 10f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
10: mov [rip + g_share_pct], rax
9:
    # gzip negotiation / adaptive egress (HTTP_GZIP, HTTP_GZIP_ABOVE_MBS; egress.s)
    mov rdi, [rip + g_envp]
    call egress_init
    mov [rip + g_egmode], rax

    # SCHED_BATCH (1; 0 = off): run every thread under SCHED_BATCH. Set before any thread starts, so they all
    # inherit it. A thread woken by epoll or a futex then waits for the running thread's slice instead of
    # preempting it, so workers and Postgres backends switch less. An error leaves the default policy.
    mov qword ptr [rsp], 1
    lea rdi, [rip + .Lenv_sbatch]
    mov esi, 11
    call getenv
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call rt_parse_u64
    test rdx, rdx
    jnz 10f
    lea rdi, [rip + .Lmsg_badnum]
    mov esi, .Lmsg_badnum_len
    call rt_die
10: mov [rsp], rax
9:  cmp qword ptr [rsp], 0
    je 8f
    mov qword ptr [rsp], 0               # struct sched_param: sched_priority 0
    xor edi, edi                         # this thread
    mov esi, SCHED_BATCH
    mov rdx, rsp
    SYS SYS_sched_setscheduler
8:
    # bcrypt threads
    xor ebx, ebx
.Lm_bc:
    cmp rbx, [rip + g_nbcrypt]
    jae .Lm_bc_done
    lea rdi, [rip + bcq_thread]
    mov rsi, rbx
    call rt_spawn
    inc rbx
    jmp .Lm_bc
.Lm_bc_done:

    # workers: struct W_SIZE each, zeroed by mmap
    xor ebx, ebx
.Lm_w:
    cmp rbx, [rip + g_nworkers]
    jae .Lm_w_done
    mov edi, W_SIZE
    call rt_mmap
    mov [rax + W_ID], rbx
    lea rcx, [rip + g_workers]
    mov [rcx + rbx*8], rax
    lea rdi, [rip + worker_main]
    mov rsi, rax
    call rt_spawn
    inc rbx
    jmp .Lm_w
.Lm_w_done:

    # park forever (threads exit the process with exit_group on fatal errors)
.Lm_park:
    lea rdi, [rip + g_park]
    mov esi, FUTEX_WAIT_PRIVATE
    xor edx, edx
    xor r10d, r10d
    SYS SYS_futex
    jmp .Lm_park
    .skip 24, 0xcc                     # padding: keeps what follows at its previous 64-byte alignment

.section .note.GNU-stack,"",@progbits
