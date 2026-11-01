# rt.s: app runtime helpers: memory copy/compare, number formatting and parsing, UTF-8 check, logging, the
# per-worker size-class allocator and thread creation.
.include "defs.inc"
.include "app.inc"

.section .rodata
DEFSTR .Lmsg_oom, "fatal: mmap failed\n"
DEFSTR .Lmsg_clone, "fatal: clone failed\n"


.text

# ---------------------------------------------------------------- memory

# rt_memcpy(dst, src, n) -> rax = dst + n. Forward copy, so it is also safe for overlapping moves with dst < src.
.globl rt_memcpy
rt_memcpy:
    mov rax, rdi
    mov rcx, rdx
    rep movsb
    mov rax, rdi
    ret

# rt_memeq(a, alen, b, blen) -> 1 if the two byte strings are equal, else 0.
.globl rt_memeq
rt_memeq:
    xor eax, eax
    cmp rsi, rcx
    jne .Lme_ret
    mov rcx, rsi
    mov rsi, rdx
    repe cmpsb
    sete al
.Lme_ret:
    ret

# rt_memchr(p, n, byte) -> rax = pointer to the first `byte` in p[0..n), or 0.
.globl rt_memchr
rt_memchr:
    mov rax, rdi
    lea rcx, [rdi + rsi]
.Lmc_loop:
    cmp rax, rcx
    jae .Lmc_none
    cmp byte ptr [rax], dl
    je .Lmc_ret
    inc rax
    jmp .Lmc_loop
.Lmc_none:
    xor eax, eax
.Lmc_ret:
    ret

# ---------------------------------------------------------------- numbers

# rt_utoa(dst, v) -> rax = dst + digits. Unsigned decimal.
.globl rt_utoa
rt_utoa:
    sub rsp, 40                          # 24 bytes of digits, aligned
    mov rax, rsi
    lea r8, [rsp + 32]                   # write digits backwards from here
    mov r9, r8
    mov ecx, 10
.Lut_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .Lut_loop
.Lut_copy:
    mov dl, [r8]
    mov [rdi], dl
    inc rdi
    inc r8
    cmp r8, r9
    jb .Lut_copy
    mov rax, rdi
    add rsp, 40
    ret

# rt_itoa(dst, v) -> rax = end. Signed decimal.
.globl rt_itoa
rt_itoa:
    test rsi, rsi
    jns rt_utoa
    mov byte ptr [rdi], '-'
    inc rdi
    neg rsi
    jmp rt_utoa

# rt_parse_u64(ptr, len) -> rax = value, rdx = 1 ok / 0 bad.
# Rust parse_uint: non-empty, ASCII digits only (leading zeros fine), value <= i64::MAX.
.globl rt_parse_u64
rt_parse_u64:
    xor eax, eax
    xor edx, edx
    test rsi, rsi
    jz .Lpu_ret
    lea r8, [rdi + rsi]
    mov r9, 0x7fffffffffffffff
.Lpu_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpu_bad
    mov r10, rax
    imul r10, r10, 10
    jo .Lpu_bad
    add r10, rcx
    jo .Lpu_bad                          # signed overflow == above i64::MAX
    mov rax, r10
    inc rdi
    cmp rdi, r8
    jb .Lpu_loop
    mov edx, 1
    ret
.Lpu_bad:
    xor eax, eax
    xor edx, edx
.Lpu_ret:
    ret

# rt_utf8_valid(ptr, len) -> 1 if valid UTF-8 (no overlongs, no surrogates, <= U+10FFFF), else 0.
.globl rt_utf8_valid
rt_utf8_valid:
    lea r8, [rdi + rsi]
.Luv_loop:
    cmp rdi, r8
    jae .Luv_ok
    movzx eax, byte ptr [rdi]
    cmp eax, 0x80
    jb .Luv_ascii
    cmp eax, 0xc2
    jb .Luv_bad
    cmp eax, 0xe0
    jb .Luv_2
    cmp eax, 0xf0
    jb .Luv_3
    cmp eax, 0xf4
    ja .Luv_bad
    # 4-byte: F0 needs 90..BF, F4 needs 80..8F
    lea rcx, [rdi + 4]
    cmp rcx, r8
    ja .Luv_bad
    movzx ecx, byte ptr [rdi + 1]
    cmp eax, 0xf0
    jne 1f
    cmp ecx, 0x90
    jb .Luv_bad
1:  cmp eax, 0xf4
    jne 2f
    cmp ecx, 0x8f
    ja .Luv_bad
2:  and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    movzx ecx, byte ptr [rdi + 2]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    movzx ecx, byte ptr [rdi + 3]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    add rdi, 4
    jmp .Luv_loop
.Luv_3:
    lea rcx, [rdi + 3]
    cmp rcx, r8
    ja .Luv_bad
    movzx ecx, byte ptr [rdi + 1]
    cmp eax, 0xe0
    jne 1f
    cmp ecx, 0xa0                        # E0 needs A0..BF (no overlong)
    jb .Luv_bad
1:  cmp eax, 0xed
    jne 2f
    cmp ecx, 0x9f                        # ED needs 80..9F (no surrogates)
    ja .Luv_bad
2:  and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    movzx ecx, byte ptr [rdi + 2]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    add rdi, 3
    jmp .Luv_loop
.Luv_2:
    lea rcx, [rdi + 2]
    cmp rcx, r8
    ja .Luv_bad
    movzx ecx, byte ptr [rdi + 1]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Luv_bad
    add rdi, 2
    jmp .Luv_loop
.Luv_ascii:
    inc rdi
    jmp .Luv_loop
.Luv_ok:
    mov eax, 1
    ret
.Luv_bad:
    xor eax, eax
    ret

# rt_hexval(byte in dil) -> rax = 0..15, or -1 if not a hex digit.
.globl rt_hexval
rt_hexval:
    movzx eax, dil
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe 1f
    or eax, 0x20
    lea ecx, [rax - 'a']
    cmp ecx, 5
    ja 2f
    add ecx, 10
1:  mov eax, ecx
    ret
2:  mov rax, -1
    ret

# ---------------------------------------------------------------- logging

# rt_write_all(fd, ptr, len): blocking write loop (stderr logging, startup only).
.globl rt_write_all
rt_write_all:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
.Lwa_loop:
    test r13, r13
    jle .Lwa_done
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je .Lwa_loop
    test rax, rax
    jle .Lwa_done
    add r12, rax
    sub r13, rax
    jmp .Lwa_loop
.Lwa_done:
    pop r13
    pop r12
    pop rbx
    ret

# rt_log(ptr, len): write a message to stderr.
.globl rt_log
rt_log:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp rt_write_all

# rt_log_num(ptr, len, v): "<msg><v>\n" to stderr.
.globl rt_log_num
rt_log_num:
    push rbx
    sub rsp, 160
    mov rbx, rdx
    cmp rsi, 120
    jbe 1f
    mov esi, 120
1:  mov rdx, rsi
    mov rsi, rdi
    mov rdi, rsp
    call rt_memcpy
    mov rdi, rax
    mov rsi, rbx
    call rt_itoa
    mov byte ptr [rax], 10
    inc rax
    mov rsi, rax
    sub rsi, rsp
    mov rdi, rsp
    call rt_log
    add rsp, 160
    pop rbx
    ret

# rt_die(ptr, len): log and exit the whole process with status 1.
.globl rt_die
rt_die:
    and rsp, -16
    call rt_log
    mov edi, 1
    SYS SYS_exit_group

# ---------------------------------------------------------------- time

# rt_now_sec() -> rax = unix seconds (CLOCK_REALTIME), from the vDSO (no syscall). Clobbers the caller-saved
# registers.
.globl rt_now_sec
rt_now_sec:
    sub rsp, 24
    mov edi, CLOCK_REALTIME
    mov rsi, rsp
    call egress_clock_gettime
    mov rax, [rsp]
    add rsp, 24
    ret
    .skip 2, 0xcc                      # padding: keeps the code after this at its previous 64-byte alignment

# rt_mono_ms_v() -> rax = CLOCK_MONOTONIC in milliseconds, from the vDSO. Clobbers the caller-saved registers.
.globl rt_mono_ms_v
rt_mono_ms_v:
    sub rsp, 24
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    call egress_clock_gettime
    imul rcx, [rsp], 1000
    mov rax, [rsp + 8]
    xor edx, edx
    mov r8d, 1000000
    div r8
    add rax, rcx
    add rsp, 24
    ret

# rt_mono_ms() -> rax = CLOCK_MONOTONIC in milliseconds.
.globl rt_mono_ms
rt_mono_ms:
    sub rsp, 24
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    SYS SYS_clock_gettime
    imul rcx, [rsp], 1000
    mov rax, [rsp + 8]
    xor edx, edx
    mov r8d, 1000000
    div r8
    add rax, rcx
    add rsp, 24
    ret

# ---------------------------------------------------------------- memory mapping and the allocator

# rt_mmap(size) -> rax = zeroed anonymous mapping (dies on failure).
.globl rt_mmap
rt_mmap:
    mov rsi, rdi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja 1f
    ret
1:  lea rdi, [rip + .Lmsg_oom]
    mov esi, .Lmsg_oom_len
    jmp rt_die

# Size classes: class k holds blocks of 2^k bytes (k >= 6). Free lists live in the worker (r15 + W_CLS + 8k);
# a free block's first qword links to the next. Classes up to 64 KB are carved from 1 MB chunks; bigger
# blocks are mapped one by one. Freed blocks up to 1 MB go back on their free list (a list response's output
# buffer is 128 KB+, and a map + unmap + page faults per request is the cost otherwise), at most KEEP_MAX_BLOCKS
# per class above 64 KB (counted in W_KEEPN) so a peak's blocks do not stay mapped forever; the rest, and
# anything bigger, are unmapped.
.equ CHUNK, 1048576
.equ CARVE_MAX_CLASS, 16
.equ KEEP_MAX_CLASS, 20
.equ KEEP_MAX_BLOCKS, 64
.equ KEEPN_BASE, W_KEEPN - 4 * (CARVE_MAX_CLASS + 1)   # W_KEEPN dword for class k is at KEEPN_BASE + 4k

# rt_alloc(size) -> rax = block, rdx = its capacity (2^k >= size). Uses r15 (worker). Not zeroed.
.globl rt_alloc
rt_alloc:
    cmp rdi, 64
    jae 1f
    mov edi, 64
1:  lea rcx, [rdi - 1]
    bsr rcx, rcx
    inc ecx                              # k = ceil(log2(size))
    mov rax, [r15 + W_CLS + rcx*8]
    test rax, rax
    jz .Lal_refill
    mov rdx, [rax]
    mov [r15 + W_CLS + rcx*8], rdx
    cmp ecx, CARVE_MAX_CLASS
    jbe 2f
    dec dword ptr [r15 + KEEPN_BASE + rcx*4]
2:  mov edx, 1
    shl rdx, cl
    ret
.Lal_refill:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, ecx                         # k
    mov r12d, 1
    shl r12, cl                          # block size
    cmp ebx, CARVE_MAX_CLASS
    ja .Lal_big
    mov edi, CHUNK
    call rt_mmap
    # push blocks 1..n-1 onto the free list, return block 0
    lea rcx, [rax + CHUNK]
    mov rdx, [r15 + W_CLS + rbx*8]       # (empty, 0)
    lea rsi, [rax + r12]
.Lal_carve:
    cmp rsi, rcx
    jae .Lal_carved
    mov [rsi], rdx
    mov rdx, rsi
    add rsi, r12
    jmp .Lal_carve
.Lal_carved:
    mov [r15 + W_CLS + rbx*8], rdx
    mov rdx, r12
    add rsp, 8
    pop r12
    pop rbx
    ret
.Lal_big:
    mov rdi, r12
    call rt_mmap
    mov rdx, r12
    add rsp, 8
    pop r12
    pop rbx
    ret
    .skip 51, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# rt_free(ptr, cap): return a block from rt_alloc (cap = the capacity it returned). ptr 0 is ignored.
.globl rt_free
rt_free:
    test rdi, rdi
    jz 2f
    bsr rcx, rsi
    cmp ecx, CARVE_MAX_CLASS
    jbe 3f
    cmp ecx, KEEP_MAX_CLASS
    ja 1f
    cmp dword ptr [r15 + KEEPN_BASE + rcx*4], KEEP_MAX_BLOCKS
    jae 1f
    inc dword ptr [r15 + KEEPN_BASE + rcx*4]
3:  mov rax, [r15 + W_CLS + rcx*8]
    mov [rdi], rax
    mov [r15 + W_CLS + rcx*8], rdi
2:  ret
1:  SYS SYS_munmap                       # rdi = ptr, rsi = len
    ret
    .skip 40, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# rt_grow(ptr, len, cap, need) -> rax = new ptr, rdx = new cap. Keeps the first `len` bytes; frees the old
# block. If cap >= need, returns the block unchanged.
.globl rt_grow
rt_grow:
    cmp rdx, rcx
    jb 1f
    mov rax, rdi
    ret
1:  push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rdx + rdx]
    cmp rdi, rcx
    jae 2f
    mov rdi, rcx
2:  call rt_alloc
    mov r14, rdx
    mov [rsp], rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call rt_memcpy
    mov rdi, rbx
    mov rsi, r13
    call rt_free
    mov rax, [rsp]
    mov rdx, r14
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- threads

# rt_spawn(fn, arg): start a thread running fn(arg) on a fresh 1 MB stack (plus guard-free mapping).
# fn must never return (it ends with SYS_exit or loops forever).
.globl rt_spawn
rt_spawn:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov edi, 1 << 20
    call rt_mmap
    lea rsi, [rax + (1 << 20) - 16]      # child stack top, 16-aligned
    mov [rsi], rbx                       # fn
    mov [rsi + 8], r12                   # arg
    mov edi, CLONE_THREAD_FLAGS
    xor edx, edx                         # parent_tid
    xor r10d, r10d                       # child_tid
    xor r8d, r8d                         # tls
    SYS SYS_clone
    test rax, rax
    jz .Lsp_child
    js .Lsp_fail
    add rsp, 8
    pop r12
    pop rbx
    ret
.Lsp_child:
    # new stack: [rsp] = fn, [rsp + 8] = arg; rsp is 16-aligned here
    mov rax, [rsp]
    mov rdi, [rsp + 8]
    call rax
    xor edi, edi
    SYS SYS_exit
.Lsp_fail:
    lea rdi, [rip + .Lmsg_clone]
    mov esi, .Lmsg_clone_len
    jmp rt_die

.section .note.GNU-stack,"",@progbits
