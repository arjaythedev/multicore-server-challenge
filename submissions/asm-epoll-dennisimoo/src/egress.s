# egress.s: adaptive gzip controller, a port of the Rust server's `egress` module (http.rs).
#
# HTTP_GZIP=0 never compresses, HTTP_GZIP=1 compresses every eligible response, anything else (or unset) is
# the adaptive mode: every 50 ms window the share of eligible responses that get compressed moves up by 1/16
# while the bytes sent in the last window were over HTTP_GZIP_ABOVE_MBS (default 100 MB/s) and TCP
# retransmitted at least HTTP_GZIP_RETRANS per mille (default 5) of its segments (/proc/net/snmp), and down
# by 1/16 otherwise. The share is out of 256 and dithered by a per-worker turn counter.
#
# egress_init(envp) -> rax = mode (EG_OFF / EG_ALWAYS / EG_ABOVE); once, before any worker starts
# egress_compress(turn) -> eax = 1 if this eligible response should be compressed; turn = worker-local qword
# egress_sent(n): record n bytes written (head + payload) for one response; a no-op unless EG_ABOVE
# Test hooks: egress_init_path(envp, path), egress_sent_at(n, now_ns), egress_lossy(), egress_next_share,
# egress_state(dst).
#
# Lock-free: WINDOW/START move by lock cmpxchg, BYTES by lock add / xchg. Only the thread that wins the
# window's cmpxchg reads the counters and stores SHARE. The clock is the vDSO's clock_gettime (found through
# AT_SYSINFO_EHDR), falling back to the syscall.
.include "defs.inc"

.set WINDOW_NS, 50000000
.set FULL, 256
.set STEP, 16
.set SNMP_BUF, 4096

.data
.balign 64
eg_mode:     .quad 0                     # EG_OFF until egress_init
eg_limit:    .quad 0                     # bytes per window (Above mode)
eg_permille: .quad 5
eg_fd:       .quad -1                    # /proc/net/snmp, -1 = not open (counts as lossy, as Rust's None)
eg_cgt:      .quad 0                     # vDSO clock_gettime, 0 = use the syscall
eg_start:    .quad 0                     # monotonic ns of the first egress_sent (Rust's START), 0 = unset
eg_window:   .quad 0                     # last window number seen
eg_share:    .quad 0                     # 0..256
eg_out:      .quad 0                     # OutSegs at the last read
eg_retrans:  .quad 0                     # RetransSegs at the last read
.balign 64
eg_bytes:    .quad 0                     # bytes sent in the current window (own cache line: every response adds)
.balign 64

.section .rodata
.Lsnmp_path: .asciz "/proc/net/snmp"
.Lenv_gzip:  .ascii "HTTP_GZIP="
.Lenv_mbs:   .ascii "HTTP_GZIP_ABOVE_MBS="
.Lenv_rtx:   .ascii "HTTP_GZIP_RETRANS="
.Ltcp:       .ascii "Tcp:"
.Lout_segs:  .ascii "OutSegs"
.Lrtx_segs:  .ascii "RetransSegs"
.Lvdso_cgt:  .asciz "__vdso_clock_gettime"

.text

# ------------------------------------------------------------------------------------------------ init
.globl egress_init
.type egress_init, @function
egress_init:
    lea rsi, [rip + .Lsnmp_path]
    jmp egress_init_path
.size egress_init, .-egress_init

# egress_init_path(envp, path) -> rax = mode. Resets every counter (so tests can call it again).
.globl egress_init_path
.type egress_init_path, @function
egress_init_path:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rbx, rdi                        # envp
    mov rbp, rsi                        # path
    mov rdi, [rip + eg_fd]
    test rdi, rdi
    js 1f
    SYS SYS_close
1:  xor eax, eax
    mov qword ptr [rip + eg_fd], -1
    mov [rip + eg_start], rax
    mov [rip + eg_window], rax
    mov [rip + eg_share], rax
    mov [rip + eg_out], rax
    mov [rip + eg_retrans], rax
    mov [rip + eg_bytes], rax
    mov [rip + eg_cgt], rax
    mov [rip + eg_limit], rax
    # first match of each variable, as getenv
    xor r12d, r12d                      # HTTP_GZIP value
    xor r13d, r13d                      # HTTP_GZIP_ABOVE_MBS value
    xor r14d, r14d                      # HTTP_GZIP_RETRANS value
    mov r15, rbx
.Lenv:
    mov rdi, [r15]
    test rdi, rdi
    jz .Lenv_done
    add r15, 8
    test r12, r12
    jnz 2f
    lea rsi, [rip + .Lenv_gzip]
    mov edx, 10
    call .Lprefix
    jz 2f
    mov r12, rax
    jmp .Lenv
2:  test r13, r13
    jnz 3f
    lea rsi, [rip + .Lenv_mbs]
    mov edx, 20
    call .Lprefix
    jz 3f
    mov r13, rax
    jmp .Lenv
3:  test r14, r14
    jnz .Lenv
    lea rsi, [rip + .Lenv_rtx]
    mov edx, 18
    call .Lprefix
    jz .Lenv
    mov r14, rax
    jmp .Lenv
.Lenv_done:                             # r15 -> the NULL that ends envp; auxv follows
    lea rdi, [r15 + 8]
    call .Lvdso_find
    mov [rip + eg_cgt], rax
    mov eax, 5                          # HTTP_GZIP_RETRANS, default 5
    test r14, r14
    jz 4f
    mov rdi, r14
    call .Lstrlen
    mov rsi, rax
    mov rdi, r14
    call .Lparse_u64
    test edx, edx
    mov edx, 5
    cmovz rax, rdx
4:  mov [rip + eg_permille], rax
    # mode: exactly "0" -> off, exactly "1" -> always, else above
    test r12, r12
    jz .Labove
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 1
    ja .Labove
    cmp byte ptr [r12 + 1], 0
    jne .Labove
    mov [rip + eg_mode], rax            # EG_OFF / EG_ALWAYS
    jmp .Linit_ret
.Labove:
    mov eax, 100                        # HTTP_GZIP_ABOVE_MBS, default 100
    test r13, r13
    jz 5f
    mov rdi, r13
    call .Lstrlen
    mov rsi, rax
    mov rdi, r13
    call .Lparse_u64
    test edx, edx
    mov edx, 100
    cmovz rax, rdx
5:  imul rax, rax, 1000000              # mbs * 1_000_000 * WINDOW_MS / 1000, wrapping as Rust's release build
    imul rax, rax, 50
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rip + eg_limit], rax
    mov rdi, rbp                        # open the counters once, before connections take descriptors
    mov esi, O_RDONLY | O_CLOEXEC
    SYS SYS_open
    test rax, rax
    jns 6f
    mov rax, -1
6:  mov [rip + eg_fd], rax
    mov qword ptr [rip + eg_mode], EG_ABOVE
.Linit_ret:
    mov rax, [rip + eg_mode]
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.size egress_init_path, .-egress_init_path

# .Lprefix: rdi = "NAME=value" C string, rsi = prefix, rdx = prefix length -> ZF clear and rax = value on a
# match, ZF set otherwise. Clobbers rcx, r8.
.Lprefix:
    xor ecx, ecx
1:  cmp rcx, rdx
    je 2f
    movzx r8d, byte ptr [rdi + rcx]
    cmp r8b, [rsi + rcx]
    jne 3f
    inc rcx
    jmp 1b
2:  lea rax, [rdi + rcx]
    test rax, rax                       # nonzero: ZF clear
    ret
3:  xor eax, eax                        # ZF set
    ret

.Lstrlen:                               # rdi -> rax
    mov rax, rdi
1:  cmp byte ptr [rax], 0
    je 2f
    inc rax
    jmp 1b
2:  sub rax, rdi
    ret

# .Lparse_u64(ptr, len) -> rax = value, edx = 1 ok / 0 bad: Rust's u64::from_str (optional '+', then at
# least one ASCII digit, no overflow). Clobbers rcx, rsi, rdi, r8.
.Lparse_u64:
    test rsi, rsi
    jz 9f
    cmp byte ptr [rdi], '+'
    jne 1f
    inc rdi
    dec rsi
    jz 9f
1:  xor eax, eax
    mov r8d, 10
2:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 9f
    mul r8
    jc 9f
    add rax, rcx
    jc 9f
    inc rdi
    dec rsi
    jnz 2b
    mov edx, 1
    ret
9:  xor eax, eax
    xor edx, edx
    ret

# .Lvdso_find(auxv) -> rax = address of the vDSO's __vdso_clock_gettime, or 0.
.Lvdso_find:
1:  mov rax, [rdi]
    test rax, rax                       # AT_NULL
    jz 9f
    cmp rax, AT_SYSINFO_EHDR
    je 2f
    add rdi, 16
    jmp 1b
2:  mov r8, [rdi + 8]                   # ELF header
    test r8, r8
    jz 9f
    cmp dword ptr [r8], 0x464c457f      # "\x7fELF"
    jne 9f
    mov rcx, [r8 + 0x20]                # e_phoff
    add rcx, r8
    movzx edx, word ptr [r8 + 0x38]     # e_phnum
    movzx esi, word ptr [r8 + 0x36]     # e_phentsize
    mov r9, -1                          # load bias
    xor r10d, r10d                      # PT_DYNAMIC vaddr
3:  test edx, edx
    jz 5f
    mov eax, [rcx]
    cmp eax, 1                          # PT_LOAD: bias from the first one
    jne 4f
    cmp r9, -1
    jne 4f
    mov r9, r8
    add r9, [rcx + 8]                   # + p_offset
    sub r9, [rcx + 0x10]                # - p_vaddr
4:  cmp eax, 2                          # PT_DYNAMIC
    jne 4f
    mov r10, [rcx + 0x10]
    inc r10                             # +1 so that vaddr 0 still counts as found
4:  add rcx, rsi
    dec edx
    jmp 3b
5:  cmp r9, -1
    je 9f
    test r10, r10
    jz 9f
    lea rcx, [r9 + r10 - 1]             # dynamic section
    xor esi, esi                        # DT_STRTAB
    xor edi, edi                        # DT_SYMTAB
    xor r11d, r11d                      # DT_HASH
6:  mov rax, [rcx]
    test rax, rax
    jz 7f
    mov rdx, [rcx + 8]
    add rdx, r9
    cmp rax, 5
    cmove rsi, rdx
    cmp rax, 6
    cmove rdi, rdx
    cmp rax, 4
    cmove r11, rdx
    add rcx, 16
    jmp 6b
7:  test rsi, rsi
    jz 9f
    test rdi, rdi
    jz 9f
    test r11, r11
    jz 9f
    mov r10d, [r11 + 4]                 # nchain = number of symbols
8:  test r10d, r10d
    jz 9f
    dec r10d
    imul rax, r10, 24
    add rax, rdi                        # Elf64_Sym
    cmp word ptr [rax + 6], 0           # st_shndx: defined
    je 8b
    cmp qword ptr [rax + 8], 0
    je 8b
    mov ecx, [rax]                      # st_name
    add rcx, rsi
    lea rdx, [rip + .Lvdso_cgt]
10: movzx r8d, byte ptr [rcx]
    cmp r8b, [rdx]
    jne 8b
    test r8b, r8b
    jz 11f
    inc rcx
    inc rdx
    jmp 10b
11: mov rax, [rax + 8]
    add rax, r9
    ret
9:  xor eax, eax
    ret

# egress_clock_gettime(clockid, ts) -> rax = 0 or -errno: clock_gettime through the vDSO found by egress_init
# (the syscall before egress_init or without a vDSO). Clobbers the caller-saved registers. Aligns the stack
# itself.
.globl egress_clock_gettime
.type egress_clock_gettime, @function
egress_clock_gettime:
    mov rax, [rip + eg_cgt]
    test rax, rax
    jz 1f
    push rbp
    mov rbp, rsp
    and rsp, -16
    call rax
    leave
    ret
1:  SYS SYS_clock_gettime
    ret
.size egress_clock_gettime, .-egress_clock_gettime

# .Lnow_ns -> rax = CLOCK_MONOTONIC in ns. Clobbers the caller-saved registers. Aligns the stack itself, so
# callers that do not keep the ABI alignment are fine.
.Lnow_ns:
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 16
    mov rax, [rip + eg_cgt]
    test rax, rax
    jz 1f
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    call rax
    test eax, eax
    jz 2f
1:  mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    SYS SYS_clock_gettime
2:  imul rax, [rsp], 1000000000
    add rax, [rsp + 8]
    leave
    ret
    .skip 32, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# ------------------------------------------------------------------------------------------------ hot path
# egress_compress(turn) -> eax: Off 0, Always 1, Above: share != 0 && ++*turn % 256 < share.
.globl egress_compress
.type egress_compress, @function
egress_compress:
    mov rax, [rip + eg_mode]
    cmp eax, EG_ABOVE
    jne 1f
    mov rcx, [rip + eg_share]
    test rcx, rcx
    jz 2f
    mov rax, [rdi]
    inc rax
    mov [rdi], rax
    movzx eax, al
    cmp rax, rcx
    setb al
    ret
1:  ret                                 # EG_OFF = 0, EG_ALWAYS = 1
2:  xor eax, eax
    ret
.size egress_compress, .-egress_compress

# egress_sent(n): count n bytes for this window (Above mode only).
.globl egress_sent
.type egress_sent, @function
egress_sent:
    cmp qword ptr [rip + eg_mode], EG_ABOVE
    jne 1f
    push rdi
    call .Lnow_ns
    pop rdi
    mov rsi, rax
    jmp egress_sent_at
1:  ret
.size egress_sent, .-egress_sent

# egress_sent_at(n, now_ns): Rust's egress::sent with the clock passed in.
.globl egress_sent_at
.type egress_sent_at, @function
egress_sent_at:
    mov rax, [rip + eg_start]           # START: the first caller's time
    test rax, rax
    jnz 1f
    lock cmpxchg [rip + eg_start], rsi  # rax = 0: set it, or load the winner's
    jnz 1f
    mov rax, rsi
1:  mov rcx, rsi
    sub rcx, rax
    jae 2f
    xor ecx, ecx                        # elapsed() saturates at 0
2:  mov r8, rdi                         # n
    mov rax, rcx
    xor edx, edx
    mov ecx, WINDOW_NS
    div rcx
    lea rsi, [rax + 1]                  # w = elapsed_ms / 50 + 1
    mov rax, [rip + eg_window]          # last
    cmp rax, rsi
    je .Lsa_add
    mov rdx, rax
    lock cmpxchg [rip + eg_window], rsi
    jnz .Lsa_add
    # this thread opened the window: read the counters, then move the share
    push r8
    push rdx                            # last
    push rsi                            # w
    call egress_lossy
    pop rsi
    pop rdx
    xor ecx, ecx
    xchg [rip + eg_bytes], rcx          # BYTES.swap(0)
    cmp rcx, [rip + eg_limit]
    seta cl
    and eax, ecx                        # over = bytes > limit && lossy
    inc rdx
    cmp rdx, rsi
    sete dl                             # consecutive = w == last + 1
    and edx, eax
    movzx esi, dl
    mov rdi, [rip + eg_share]
    call egress_next_share
    mov [rip + eg_share], rax
    pop r8
.Lsa_add:
    lock add [rip + eg_bytes], r8
    ret
.size egress_sent_at, .-egress_sent_at

# egress_next_share(share, up) -> rax: up (consecutive && over) ? min(share + 16, 256) : share -| 16.
.globl egress_next_share
.type egress_next_share, @function
egress_next_share:
    test esi, esi
    jz 1f
    lea rax, [rdi + STEP]
    mov ecx, FULL
    cmp rax, rcx
    cmova rax, rcx
    ret
1:  xor eax, eax
    sub rdi, STEP
    cmovae rax, rdi
    ret
.size egress_next_share, .-egress_next_share

# egress_lossy() -> eax: Rust's lossy(): retrans * 1000 >= max(out, 1) * permille over the deltas since the
# last call. permille 0 or no counters file -> 1; a failed read or unparsable file -> 0.
.globl egress_lossy
.type egress_lossy, @function
egress_lossy:
    cmp qword ptr [rip + eg_permille], 0
    je .Llo_true
    cmp qword ptr [rip + eg_fd], 0
    jl .Llo_true
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, SNMP_BUF                   # 5 pushes + 4096: rsp stays 16-byte aligned
    xor ebx, ebx                        # bytes read
.Llo_read:                              # pread from 0 to EOF (read_to_string retries EINTR)
    mov rdi, [rip + eg_fd]
    lea rsi, [rsp + rbx]
    mov edx, SNMP_BUF
    sub edx, ebx
    jz .Llo_parse
    mov r10, rbx
    SYS SYS_pread64
    cmp rax, -EINTR
    je .Llo_read
    test rax, rax
    js .Llo_false
    jz .Llo_parse
    add rbx, rax
    jmp .Llo_read
.Llo_parse:
    mov rbp, rsp                        # cursor
    lea r12, [rsp + rbx]                # end
    call .Lnext_tcp                     # names line
    jz .Llo_false
    mov r13, rax
    mov r14, rdx
    call .Lnext_tcp                     # values line
    jz .Llo_false
    push rax
    push rdx                            # rsp + 0 = values end, rsp + 8 = values start
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lout_segs]
    mov ecx, 7
    call .Ltok_index
    test rax, rax
    js .Llo_false2
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    mov rdx, rax
    call .Ltok_nth
    test rax, rax
    jz .Llo_false2
    mov rdi, rax
    mov rsi, rdx
    call .Lparse_u64
    test edx, edx
    jz .Llo_false2
    mov rbx, rax                        # OutSegs
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lrtx_segs]
    mov ecx, 11
    call .Ltok_index
    test rax, rax
    js .Llo_false2
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    mov rdx, rax
    call .Ltok_nth
    test rax, rax
    jz .Llo_false2
    mov rdi, rax
    mov rsi, rdx
    call .Lparse_u64
    test edx, edx
    jz .Llo_false2
    add rsp, 16
    mov rcx, rbx                        # out = out -| OUT.swap(out)
    xchg [rip + eg_out], rcx
    xor edx, edx
    sub rbx, rcx
    cmovb rbx, rdx
    mov rcx, rax                        # retrans = retrans -| RETRANS.swap(retrans)
    xchg [rip + eg_retrans], rcx
    sub rax, rcx
    cmovb rax, rdx
    imul rax, rax, 1000                 # wrapping, as the release build
    mov ecx, 1
    test rbx, rbx
    cmovz rbx, rcx
    imul rbx, [rip + eg_permille]
    cmp rax, rbx
    setae al
    movzx eax, al
    jmp .Llo_ret
.Llo_false2:
    add rsp, 16
.Llo_false:
    xor eax, eax
.Llo_ret:
    add rsp, SNMP_BUF
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Llo_true:
    mov eax, 1
    ret
.size egress_lossy, .-egress_lossy

# .Lnext_tcp: rbp = cursor, r12 = end -> the next line starting with "Tcp:" in rax..rdx (without its '\n'),
# ZF clear; ZF set if none. Advances rbp past it. Clobbers rcx.
.Lnext_tcp:
1:  cmp rbp, r12
    jae 9f
    mov rax, rbp                        # line start
2:  cmp rbp, r12                        # line end
    jae 3f
    cmp byte ptr [rbp], 10
    je 3f
    inc rbp
    jmp 2b
3:  mov rdx, rbp
    cmp rbp, r12
    jae 4f
    inc rbp                             # past '\n'
4:  mov rcx, rdx
    sub rcx, rax
    cmp rcx, 4
    jb 1b
    cmp dword ptr [rax], 0x3a706354     # "Tcp:"
    jne 1b
    test rax, rax                       # ZF clear
    ret
9:  xor eax, eax                        # ZF set
    ret

# .Lws: ZF set if cl is ASCII whitespace as Rust's split_ascii_whitespace (SP, HT, LF, FF, CR).
.macro WSCHECK reg
    cmp \reg, ' '
    je 99f
    cmp \reg, 9
    je 99f
    cmp \reg, 10
    je 99f
    cmp \reg, 12
    je 99f
    cmp \reg, 13
99:
.endm

# .Ltok_next: rdi = cursor, rsi = end -> rax..rdx = next whitespace-separated token (rax = 0 if none);
# rdi advanced past it. Clobbers r8.
.Ltok_next:
1:  cmp rdi, rsi
    jae 8f
    movzx r8d, byte ptr [rdi]
    WSCHECK r8b
    jne 2f
    inc rdi
    jmp 1b
2:  mov rax, rdi
3:  inc rdi
    cmp rdi, rsi
    jae 4f
    movzx r8d, byte ptr [rdi]
    WSCHECK r8b
    jne 3b
4:  mov rdx, rdi
    ret
8:  xor eax, eax
    ret

# .Ltok_index(start, end, name, nlen) -> rax = position of the first token equal to name, or -1.
.Ltok_index:
    push rbx
    push r12
    push r13
    mov r12, rdx
    mov r13, rcx
    xor ebx, ebx
1:  call .Ltok_next
    test rax, rax
    jz 8f
    mov rcx, rdx
    sub rcx, rax
    cmp rcx, r13
    jne 3f
    xor ecx, ecx
2:  cmp rcx, r13
    je 7f
    movzx r8d, byte ptr [rax + rcx]
    cmp r8b, [r12 + rcx]
    jne 3f
    inc rcx
    jmp 2b
3:  inc rbx
    jmp 1b
7:  mov rax, rbx
    jmp 9f
8:  mov rax, -1
9:  pop r13
    pop r12
    pop rbx
    ret

# .Ltok_nth(start, end, i) -> rax = ptr of token i (0 if there are fewer), rdx = its length.
.Ltok_nth:
    mov r9, rdx
1:  call .Ltok_next
    test rax, rax
    jz 9f
    test r9, r9
    jz 2f
    dec r9
    jmp 1b
2:  sub rdx, rax
    ret
9:  xor eax, eax
    ret

# ------------------------------------------------------------------------------------------------ test hooks
# egress_state(dst): copies mode, limit, permille, fd, cgt, start, window, share, out, retrans, bytes.
.globl egress_state
egress_state:
    lea rsi, [rip + eg_mode]
    mov ecx, 10
    rep movsq
    mov rax, [rip + eg_bytes]
    mov [rdi], rax
    ret

.section .note.GNU-stack,"",@progbits
