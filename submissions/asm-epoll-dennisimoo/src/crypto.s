# crypto.s: SHA-256 (SHA-NI + scalar), HMAC-SHA256, PBKDF2, base64 / base64url, JWT HS256 sign + verify,
# getrandom. No mutable globals: every function is reentrant.
#
# SHA-NI vs scalar: crypto_sha256_blocks tests `cpu_features & CPU_SHA` (cpu.s) on every call, so cpu_detect must
# run before the first hash (otherwise the scalar path is used, which is correct, only slower). crypto_init keeps
# no state of its own: it returns 1 if the SHA-NI path is selected, 0 if scalar.
#
# A SHA-256 state (state8x32) is H0..H7 as eight native (little-endian) uint32 words.
#
# crypto_jwt_verify follows the Rust reference (auth.rs), which serde_json drives:
#   * tokens longer than JWT_MAX_TOKEN are rejected; the call uses ~6.5 KB of stack (decode buffer) plus up to
#     ~2 KB more for deeply nested ignored JSON values (nesting is capped at 128 levels);
#   * exactly three '.'-separated parts, strict unpadded base64url (no '=', zero trailing bits);
#   * the signature (exactly 43 chars = 32 bytes) is checked in full before any JSON is looked at;
#   * header: the standard eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 is accepted without decoding; any other header must
#     be a JSON object with exactly one "alg" key whose value is the string "HS256" (escapes allowed, other keys
#     ignored, duplicate "alg" rejected as serde does);
#   * payload: a JSON object; "sub" a string (escapes decoded) of decimal digits, value 1..2^63-1 (leading zeros
#     are accepted, as Rust's parse::<i64> does); "exp" a JSON number > now; "nbf", if present and not null, a
#     number <= now; duplicate sub/exp/nbf rejected; every other key/value is syntax-checked and ignored;
#   * numbers follow RFC 8259 exactly and are compared to `now` exactly (fractions and exponents work: 1.5e9 is
#     1500000000); `now` is a non-negative unix time in seconds. Deviation from serde: numbers beyond the f64
#     range count as huge instead of being an error. Strings: control characters and bad escapes are errors, lone
#     surrogates are errors everywhere (serde only checks them in keys/sub/alg), bytes >= 0x80 are not UTF-8
#     checked.

.include "defs.inc"

# ---------------------------------------------------------------- jwt_verify frame
.equ JV_SIG,    0           # 32: decoded signature
.equ JV_MAC,    32          # 32: computed HMAC
.equ JV_KEY,    64          # 16: decoded object key (cap 8) / alg value
.equ JV_HLEN,   80          # header length, later the decoded sub length
.equ JV_PPTR,   88          # payload part ptr
.equ JV_PLEN,   96          # payload part len
.equ JV_STR,    112         # 64: decoded sub value
.equ JV_STRCAP, 64
.equ JV_BUF,    176         # decoded header / payload (+ NUL sentinel); 8192-byte token -> < 6112 bytes
.equ JV_FRAME,  6328        # JV_BUF + 6144 + 8 (keeps rsp 16-aligned after the 6 pushes)

.text

# ================================================================ crypto_init() -> 1 (SHA-NI) | 0 (scalar)
.globl crypto_init
crypto_init:
    mov rax, [rip + cpu_features]
    and eax, CPU_SHA
    ret

# ================================================================ crypto_sha256_blocks(state8x32, blocks, n)
.globl crypto_sha256_blocks
crypto_sha256_blocks:
    test byte ptr [rip + cpu_features], CPU_SHA
    jz .Lsha256_scalar

# ---------------------------------------------------------------- SHA-NI (as in Linux's sha256_ni_asm.S)
# xmm0 = msg + K, xmm1 = ABEF, xmm2 = CDGH, xmm3..6 = message schedule, xmm7 = tmp, xmm8 = byte-flip mask,
# xmm9/xmm10 = state at block start. rax = K256 + 128 so every constant is a disp8.
.macro NI_4ROUNDS i, m0, m1, m2, m3
.if (\i) < 16
    movdqu \m0, [rsi + (\i)*4]
    pshufb \m0, xmm8
.endif
    movdqa xmm0, [rax + ((\i) - 32)*4]
    paddd xmm0, \m0
    sha256rnds2 xmm2, xmm1
.if (\i) >= 12 && (\i) < 60
    movdqa xmm7, \m0
    palignr xmm7, \m3, 4
    paddd \m1, xmm7
    sha256msg2 \m1, \m0
.endif
    punpckhqdq xmm0, xmm0
    sha256rnds2 xmm1, xmm2
.if (\i) >= 4 && (\i) < 52
    sha256msg1 \m3, \m0
.endif
.endm

    shl rdx, 6
    jz .Lni_ret
    add rdx, rsi                        # end of data
    movdqu xmm1, [rdi]                  # DCBA
    movdqu xmm2, [rdi + 16]             # HGFE
    movdqa xmm7, xmm1
    punpcklqdq xmm1, xmm2               # FEBA
    punpckhqdq xmm2, xmm7               # DCHG
    pshufd xmm1, xmm1, 0x1b             # ABEF
    pshufd xmm2, xmm2, 0xb1             # CDGH
    movdqa xmm8, [rip + .Lbswap32]
    lea rax, [rip + .Lk256 + 128]
.Lni_loop:
    movdqa xmm9, xmm1
    movdqa xmm10, xmm2
.irp i, 0, 16, 32, 48
    NI_4ROUNDS (\i + 0), xmm3, xmm4, xmm5, xmm6
    NI_4ROUNDS (\i + 4), xmm4, xmm5, xmm6, xmm3
    NI_4ROUNDS (\i + 8), xmm5, xmm6, xmm3, xmm4
    NI_4ROUNDS (\i + 12), xmm6, xmm3, xmm4, xmm5
.endr
    paddd xmm1, xmm9
    paddd xmm2, xmm10
    add rsi, 64
    cmp rsi, rdx
    jne .Lni_loop
    movdqa xmm7, xmm1
    punpcklqdq xmm1, xmm2               # GHEF
    punpckhqdq xmm2, xmm7               # ABCD
    pshufd xmm1, xmm1, 0xb1             # HGFE
    pshufd xmm2, xmm2, 0x1b             # DCBA
    movdqu [rdi], xmm2
    movdqu [rdi + 16], xmm1
.Lni_ret:
    ret

# ---------------------------------------------------------------- scalar
# a..h live in r8d..r15d (renamed per round), W[0..15] is a ring at [rsp], temps eax/ebx/ecx/edx.
.macro SC_ROUND va, vb, vc, vd, ve, vf, vg, vh, i
.if (\i) >= 16
    mov eax, [rsp + ((((\i) + 1) & 15) * 4)]
    mov ecx, eax
    mov edx, eax
    ror eax, 7
    ror ecx, 18
    shr edx, 3
    xor eax, ecx
    xor eax, edx                        # s0(W[i-15])
    mov ecx, [rsp + ((((\i) + 14) & 15) * 4)]
    mov edx, ecx
    mov ebx, ecx
    ror ecx, 17
    ror edx, 19
    shr ebx, 10
    xor ecx, edx
    xor ecx, ebx                        # s1(W[i-2])
    add eax, ecx
    add eax, [rsp + ((((\i) + 9) & 15) * 4)]
    add eax, [rsp + (((\i) & 15) * 4)]
    mov [rsp + (((\i) & 15) * 4)], eax
.else
    mov eax, [rsp + (\i) * 4]
.endif
    add eax, [rip + .Lk256 + (\i) * 4]
    add \vh, eax                        # h + K + W
    mov eax, \ve
    mov ecx, \ve
    mov edx, \ve
    ror eax, 6
    ror ecx, 11
    ror edx, 25
    xor eax, ecx
    xor eax, edx
    add \vh, eax                        # + S1(e)
    mov eax, \vf
    xor eax, \vg
    and eax, \ve
    xor eax, \vg
    add \vh, eax                        # + Ch(e,f,g) = T1
    add \vd, \vh                        # d += T1
    mov eax, \va
    mov ecx, \va
    mov edx, \va
    ror eax, 2
    ror ecx, 13
    ror edx, 22
    xor eax, ecx
    xor eax, edx
    add \vh, eax                        # + S0(a)
    mov eax, \va
    mov ecx, \va
    or eax, \vc
    and ecx, \vc
    and eax, \vb
    or eax, ecx
    add \vh, eax                        # + Maj(a,b,c)
.endm

.Lsha256_scalar:
    test rdx, rdx
    jz .Lsc_ret
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88                         # W[16] | state ptr @64 | data ptr @72 | end @80
    mov [rsp + 64], rdi
    shl rdx, 6
    add rdx, rsi
    mov [rsp + 80], rdx
    mov r8d, [rdi]
    mov r9d, [rdi + 4]
    mov r10d, [rdi + 8]
    mov r11d, [rdi + 12]
    mov r12d, [rdi + 16]
    mov r13d, [rdi + 20]
    mov r14d, [rdi + 24]
    mov r15d, [rdi + 28]
.Lsc_block:
    mov [rsp + 72], rsi
.irp i, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    mov eax, [rsi + \i * 4]
    bswap eax
    mov [rsp + \i * 4], eax
.endr
.irp i, 0, 8, 16, 24, 32, 40, 48, 56
    SC_ROUND r8d, r9d, r10d, r11d, r12d, r13d, r14d, r15d, (\i + 0)
    SC_ROUND r15d, r8d, r9d, r10d, r11d, r12d, r13d, r14d, (\i + 1)
    SC_ROUND r14d, r15d, r8d, r9d, r10d, r11d, r12d, r13d, (\i + 2)
    SC_ROUND r13d, r14d, r15d, r8d, r9d, r10d, r11d, r12d, (\i + 3)
    SC_ROUND r12d, r13d, r14d, r15d, r8d, r9d, r10d, r11d, (\i + 4)
    SC_ROUND r11d, r12d, r13d, r14d, r15d, r8d, r9d, r10d, (\i + 5)
    SC_ROUND r10d, r11d, r12d, r13d, r14d, r15d, r8d, r9d, (\i + 6)
    SC_ROUND r9d, r10d, r11d, r12d, r13d, r14d, r15d, r8d, (\i + 7)
.endr
    mov rdi, [rsp + 64]
    add r8d, [rdi]
    mov [rdi], r8d
    add r9d, [rdi + 4]
    mov [rdi + 4], r9d
    add r10d, [rdi + 8]
    mov [rdi + 8], r10d
    add r11d, [rdi + 12]
    mov [rdi + 12], r11d
    add r12d, [rdi + 16]
    mov [rdi + 16], r12d
    add r13d, [rdi + 20]
    mov [rdi + 20], r13d
    add r14d, [rdi + 24]
    mov [rdi + 24], r14d
    add r15d, [rdi + 28]
    mov [rdi + 28], r15d
    mov rsi, [rsp + 72]
    add rsi, 64
    cmp rsi, [rsp + 80]
    jne .Lsc_block
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Lsc_ret:
    ret

# ---------------------------------------------------------------- .Lsha_finish (internal, SysV)
# rdi = state (updated), rsi = tail, rdx = tail length (<= 119), rcx = total bytes hashed, r8 = out32 (may alias
# the tail). Pads, compresses the last 1-2 blocks and writes the big-endian digest.
.Lsha_finish:
    push rbx
    push r12
    push r13
    sub rsp, 128
    mov r12, rdi
    mov r13, r8
    mov rbx, rcx
    pxor xmm0, xmm0
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm0
    movdqu [rsp + 32], xmm0
    movdqu [rsp + 48], xmm0
    movdqu [rsp + 64], xmm0
    movdqu [rsp + 80], xmm0
    movdqu [rsp + 96], xmm0
    movdqu [rsp + 112], xmm0
    mov rdi, rsp
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0x80
    add rdx, 9 + 63
    shr rdx, 6                          # 1 or 2 blocks
    shl rbx, 3
    bswap rbx
    mov rax, rdx
    shl rax, 6
    mov [rsp + rax - 8], rbx            # bit length, big-endian
    mov rdi, r12
    mov rsi, rsp
    call crypto_sha256_blocks
    movdqa xmm2, [rip + .Lbswap32]
    movdqu xmm0, [r12]
    movdqu xmm1, [r12 + 16]
    pshufb xmm0, xmm2
    pshufb xmm1, xmm2
    movdqu [r13], xmm0
    movdqu [r13 + 16], xmm1
    add rsp, 128
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ crypto_sha256(msg, len, out32)
.globl crypto_sha256
crypto_sha256:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    movdqa xmm0, [rip + .Liv]
    movdqa xmm1, [rip + .Liv + 16]
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm1
    mov rdx, r12
    shr rdx, 6
    jz 1f
    mov rdi, rsp
    mov rsi, rbx
    call crypto_sha256_blocks
1:  mov rsi, r12
    and rsi, -64
    add rsi, rbx
    mov rdx, r12
    and edx, 63
    mov rcx, r12
    mov r8, r13
    mov rdi, rsp
    call .Lsha_finish
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ crypto_hmac_init(key, keylen, ctx64)
.globl crypto_hmac_init
crypto_hmac_init:
    push rbx
    sub rsp, 96                         # key block @0 | hashed long key @64
    mov rbx, rdx
    cmp rsi, 64
    jbe 1f
    lea rdx, [rsp + 64]
    call crypto_sha256
    lea rdi, [rsp + 64]
    mov esi, 32
1:  pxor xmm0, xmm0
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm0
    movdqu [rsp + 32], xmm0
    movdqu [rsp + 48], xmm0
    mov rcx, rsi
    mov rsi, rdi
    mov rdi, rsp
    rep movsb
    movdqa xmm4, [rip + .Lipad]
    call .Lxor_block
    movdqa xmm0, [rip + .Liv]
    movdqa xmm1, [rip + .Liv + 16]
    movdqu [rbx], xmm0
    movdqu [rbx + 16], xmm1
    mov rdi, rbx
    lea rsi, [rsp]
    mov edx, 1
    call crypto_sha256_blocks
    movdqa xmm4, [rip + .Lipad_opad]
    call .Lxor_block
    movdqa xmm0, [rip + .Liv]
    movdqa xmm1, [rip + .Liv + 16]
    movdqu [rbx + 32], xmm0
    movdqu [rbx + 48], xmm1
    lea rdi, [rbx + 32]
    mov rsi, rsp
    mov edx, 1
    call crypto_sha256_blocks
    add rsp, 96
    pop rbx
    ret

# xor the 64-byte block at the caller's rsp (our rsp + 8) with xmm4
.Lxor_block:
.irp o, 8, 24, 40, 56
    movdqu xmm0, [rsp + \o]
    pxor xmm0, xmm4
    movdqu [rsp + \o], xmm0
.endr
    ret

# ================================================================ crypto_hmac_ctx(ctx64, msg, len, out32)
.globl crypto_hmac_ctx
crypto_hmac_ctx:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 72                         # state @0 | inner digest @32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, rcx
    movdqu xmm0, [rdi]
    movdqu xmm1, [rdi + 16]
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm1
    mov rdx, r14
    shr rdx, 6
    jz 1f
    mov rdi, rsp
    mov rsi, r13
    call crypto_sha256_blocks
1:  mov rsi, r14
    and rsi, -64
    add rsi, r13
    mov rdx, r14
    and edx, 63
    lea rcx, [r14 + 64]
    lea r8, [rsp + 32]
    mov rdi, rsp
    call .Lsha_finish
    movdqu xmm0, [r12 + 32]
    movdqu xmm1, [r12 + 48]
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm1
    mov rdi, rsp
    lea rsi, [rsp + 32]
    mov edx, 32
    mov ecx, 96
    mov r8, rbx
    call .Lsha_finish
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ crypto_hmac(key, keylen, msg, len, out32)
.globl crypto_hmac
crypto_hmac:
    push rbx
    push r12
    push r13
    sub rsp, 64
    mov rbx, rdx
    mov r12, rcx
    mov r13, r8
    mov rdx, rsp
    call crypto_hmac_init
    mov rdi, rsp
    mov rsi, rbx
    mov rdx, r12
    mov rcx, r13
    call crypto_hmac_ctx
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ crypto_pbkdf2(pw, pwlen, salt, saltlen, iters, out32)
# dkLen = 32 (one block). iters <= 1 computes U1 only.
.equ PB_CTX, 0
.equ PB_ST, 64
.equ PB_U, 96
.equ PB_T, 128
.equ PB_TAIL, 160                       # 80: salt tail (< 64) + INT(1)
.equ PB_BLK, 240                        # 64: U | 0x80 | 0 | bitlen(96 bytes) for the 2..iters loop
.globl crypto_pbkdf2
crypto_pbkdf2:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 312
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov r15, r9
    mov rdx, rsp
    call crypto_hmac_init
    # U1 = HMAC(pw, salt || INT(1))
    movdqu xmm0, [rsp + PB_CTX]
    movdqu xmm1, [rsp + PB_CTX + 16]
    movdqu [rsp + PB_ST], xmm0
    movdqu [rsp + PB_ST + 16], xmm1
    mov rdx, r13
    shr rdx, 6
    jz 1f
    lea rdi, [rsp + PB_ST]
    mov rsi, r12
    call crypto_sha256_blocks
1:  mov rbx, r13
    and ebx, 63
    mov rsi, r13
    and rsi, -64
    add rsi, r12
    lea rdi, [rsp + PB_TAIL]
    mov rcx, rbx
    rep movsb
    mov dword ptr [rdi], 0x01000000
    lea rdi, [rsp + PB_ST]
    lea rsi, [rsp + PB_TAIL]
    lea rdx, [rbx + 4]
    lea rcx, [r13 + 68]
    lea r8, [rsp + PB_U]
    call .Lsha_finish
    movdqu xmm0, [rsp + PB_CTX + 32]
    movdqu xmm1, [rsp + PB_CTX + 48]
    movdqu [rsp + PB_ST], xmm0
    movdqu [rsp + PB_ST + 16], xmm1
    lea rdi, [rsp + PB_ST]
    lea rsi, [rsp + PB_U]
    mov edx, 32
    mov ecx, 96
    lea r8, [rsp + PB_U]
    call .Lsha_finish
    movdqu xmm0, [rsp + PB_U]
    movdqu xmm1, [rsp + PB_U + 16]
    movdqu [rsp + PB_T], xmm0
    movdqu [rsp + PB_T + 16], xmm1
    movdqu [rsp + PB_BLK], xmm0
    movdqu [rsp + PB_BLK + 16], xmm1
    pxor xmm2, xmm2
    movdqu [rsp + PB_BLK + 32], xmm2
    movdqu [rsp + PB_BLK + 48], xmm2
    mov byte ptr [rsp + PB_BLK + 32], 0x80
    mov word ptr [rsp + PB_BLK + 62], 0x0003    # 768 bits, big-endian
    mov rbp, r14
    sub rbp, 1
    jle .Lpb_done
.Lpb_loop:
    xor ebx, ebx
.Lpb_half:                              # ebx = 0: inner, 32: outer
    movdqu xmm0, [rsp + rbx + PB_CTX]
    movdqu xmm1, [rsp + rbx + PB_CTX + 16]
    movdqu [rsp + PB_ST], xmm0
    movdqu [rsp + PB_ST + 16], xmm1
    lea rdi, [rsp + PB_ST]
    lea rsi, [rsp + PB_BLK]
    mov edx, 1
    call crypto_sha256_blocks
    movdqa xmm2, [rip + .Lbswap32]
    movdqu xmm0, [rsp + PB_ST]
    movdqu xmm1, [rsp + PB_ST + 16]
    pshufb xmm0, xmm2
    pshufb xmm1, xmm2
    movdqu [rsp + PB_BLK], xmm0
    movdqu [rsp + PB_BLK + 16], xmm1
    add ebx, 32
    cmp ebx, 64
    jne .Lpb_half
    movdqu xmm2, [rsp + PB_T]
    movdqu xmm3, [rsp + PB_T + 16]
    pxor xmm2, xmm0
    pxor xmm3, xmm1
    movdqu [rsp + PB_T], xmm2
    movdqu [rsp + PB_T + 16], xmm3
    dec rbp
    jnz .Lpb_loop
.Lpb_done:
    movdqu xmm0, [rsp + PB_T]
    movdqu xmm1, [rsp + PB_T + 16]
    movdqu [r15], xmm0
    movdqu [r15 + 16], xmm1
    add rsp, 312
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ================================================================ base64 encode
# crypto_b64_encode(src, len, dst) -> outlen      standard alphabet, '=' padding
# crypto_b64url_encode(src, len, dst) -> outlen   URL alphabet, no padding
.globl crypto_b64_encode
crypto_b64_encode:
    lea r8, [rip + .Lb64_alpha]
    mov ecx, 1
    jmp .Lb64_enc
.globl crypto_b64url_encode
crypto_b64url_encode:
    lea r8, [rip + .Lb64url_alpha]
    xor ecx, ecx
.Lb64_enc:                              # r8 = alphabet, ecx = pad
    mov r9, rdx
.Le_loop:
    cmp rsi, 3
    jb .Le_tail
    movzx eax, byte ptr [rdi]
    movzx r10d, byte ptr [rdi + 1]
    movzx r11d, byte ptr [rdi + 2]
    shl eax, 16
    shl r10d, 8
    or eax, r10d
    or eax, r11d
    mov r10d, eax
    shr r10d, 18
    movzx r10d, byte ptr [r8 + r10]
    mov [rdx], r10b
    mov r10d, eax
    shr r10d, 12
    and r10d, 63
    movzx r10d, byte ptr [r8 + r10]
    mov [rdx + 1], r10b
    mov r10d, eax
    shr r10d, 6
    and r10d, 63
    movzx r10d, byte ptr [r8 + r10]
    mov [rdx + 2], r10b
    and eax, 63
    movzx eax, byte ptr [r8 + rax]
    mov [rdx + 3], al
    add rdi, 3
    add rdx, 4
    sub rsi, 3
    jmp .Le_loop
.Le_tail:
    test rsi, rsi
    jz .Le_done
    movzx eax, byte ptr [rdi]
    shl eax, 16
    cmp rsi, 2
    jb 1f
    movzx r10d, byte ptr [rdi + 1]
    shl r10d, 8
    or eax, r10d
1:  mov r10d, eax
    shr r10d, 18
    movzx r10d, byte ptr [r8 + r10]
    mov [rdx], r10b
    mov r10d, eax
    shr r10d, 12
    and r10d, 63
    movzx r10d, byte ptr [r8 + r10]
    mov [rdx + 1], r10b
    cmp rsi, 2
    jb .Le_one
    shr eax, 6
    and eax, 63
    movzx eax, byte ptr [r8 + rax]
    mov [rdx + 2], al
    add rdx, 3
    test ecx, ecx
    jz .Le_done
    mov byte ptr [rdx], '='
    inc rdx
    jmp .Le_done
.Le_one:
    add rdx, 2
    test ecx, ecx
    jz .Le_done
    mov word ptr [rdx], 0x3d3d
    add rdx, 2
.Le_done:
    mov rax, rdx
    sub rax, r9
    ret

# ================================================================ base64 decode
# crypto_b64_decode(src, len, dst) -> outlen | -1     standard alphabet, len % 4 == 0, '=' only as 1-2 final pad
# crypto_b64url_decode(src, len, dst) -> outlen | -1  URL alphabet, unpadded (len % 4 != 1, no '=')
# Both reject non-zero trailing bits (non-canonical encodings). dst needs len / 4 * 3 + 2 bytes.
.globl crypto_b64_decode
crypto_b64_decode:
    test sil, 3
    jnz .Ld_bad
    test rsi, rsi
    jz .Ld_zero
    cmp byte ptr [rdi + rsi - 1], '='
    jne 1f
    dec rsi
    cmp byte ptr [rdi + rsi - 1], '='
    jne 1f
    dec rsi
1:  lea r8, [rip + .Lb64_dec]
    jmp .Lb64_dec_core
.globl crypto_b64url_decode
crypto_b64url_decode:
    lea r8, [rip + .Lb64url_dec]
.Lb64_dec_core:                         # r8 = decode table (0xff = invalid)
    mov r9, rdx
    mov rcx, rsi
    and esi, 3
    cmp esi, 1
    je .Ld_bad
    shr rcx, 2
    jz .Ld_tail
.Ld_quad:
    movzx eax, byte ptr [rdi]
    movzx eax, byte ptr [r8 + rax]
    movzx r10d, byte ptr [rdi + 1]
    movzx r10d, byte ptr [r8 + r10]
    mov r11d, eax
    or r11d, r10d
    shl eax, 6
    or eax, r10d
    movzx r10d, byte ptr [rdi + 2]
    movzx r10d, byte ptr [r8 + r10]
    or r11d, r10d
    shl eax, 6
    or eax, r10d
    movzx r10d, byte ptr [rdi + 3]
    movzx r10d, byte ptr [r8 + r10]
    or r11d, r10d
    shl eax, 6
    or eax, r10d
    test r11b, 0x80
    jnz .Ld_bad
    bswap eax
    shr eax, 8                          # B0 | B1 << 8 | B2 << 16
    mov [rdx], ax
    shr eax, 16
    mov [rdx + 2], al
    add rdi, 4
    add rdx, 3
    dec rcx
    jnz .Ld_quad
.Ld_tail:
    test esi, esi
    jz .Ld_done
    movzx eax, byte ptr [rdi]
    movzx eax, byte ptr [r8 + rax]
    movzx r10d, byte ptr [rdi + 1]
    movzx r10d, byte ptr [r8 + r10]
    mov r11d, eax
    or r11d, r10d
    shl eax, 6
    or eax, r10d                        # 12 bits
    cmp esi, 3
    je .Ld_three
    test r11b, 0x80
    jnz .Ld_bad
    test r10b, 15
    jnz .Ld_bad
    shr eax, 4
    mov [rdx], al
    inc rdx
    jmp .Ld_done
.Ld_three:
    movzx r10d, byte ptr [rdi + 2]
    movzx r10d, byte ptr [r8 + r10]
    or r11d, r10d
    test r11b, 0x80
    jnz .Ld_bad
    test r10b, 3
    jnz .Ld_bad
    shl eax, 6
    or eax, r10d
    shr eax, 2                          # 16 bits
    mov [rdx + 1], al
    shr eax, 8
    mov [rdx], al
    add rdx, 2
.Ld_done:
    mov rax, rdx
    sub rax, r9
    ret
.Ld_zero:
    xor eax, eax
    ret
.Ld_bad:
    mov rax, -1
    ret

# ================================================================ crypto_random(dst, len) -> 0 | -errno
.globl crypto_random
crypto_random:
    mov r8, rdi
    mov r9, rsi
.Lrnd_loop:
    test r9, r9
    jz .Lrnd_ok
    mov rdi, r8
    mov rsi, r9
    xor edx, edx
    mov eax, SYS_getrandom
    syscall
    cmp rax, -EINTR
    je .Lrnd_loop
    test rax, rax
    js .Lrnd_ret
    add r8, rax
    sub r9, rax
    jmp .Lrnd_loop
.Lrnd_ok:
    xor eax, eax
.Lrnd_ret:
    ret

# ================================================================ crypto_jwt_sign(ctx64, user_id, now, dst) -> len
# header.payload.signature with payload {"sub":"<id>","iat":<now>,"exp":<now+2592000>}; dst needs JWT_SIGN_MAX.
.globl crypto_jwt_sign
crypto_jwt_sign:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 168                        # payload JSON @0 | signature @128
    mov r12, rdi
    mov r14, rsi
    mov r15, rdx
    mov r13, rcx
    lea rsi, [rip + .Ljwt_hdr]
    mov rdi, r13
    mov ecx, 37                         # header + '.'
    rep movsb
    mov rdi, rsp
    mov rax, [rip + .Ljs_sub]
    mov [rdi], rax
    add rdi, 8
    mov rsi, r14
    call .Litoa
    mov rdi, rax
    mov rax, [rip + .Ljs_iat]
    mov [rdi], rax
    add rdi, 8
    mov rsi, r15
    call .Litoa
    mov rdi, rax
    mov rax, [rip + .Ljs_exp]
    mov [rdi], rax
    add rdi, 7
    lea rsi, [r15 + 2592000]
    call .Litoa
    mov byte ptr [rax], '}'
    lea rsi, [rax + 1]
    sub rsi, rsp
    mov rdi, rsp
    lea rdx, [r13 + 37]
    call crypto_b64url_encode
    lea rbx, [rax + 37]                 # signed part length
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    lea rcx, [rsp + 128]
    call crypto_hmac_ctx
    mov byte ptr [r13 + rbx], '.'
    lea rdi, [rsp + 128]
    mov esi, 32
    lea rdx, [r13 + rbx + 1]
    call crypto_b64url_encode
    lea rax, [rbx + 44]
    add rsp, 168
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# .Litoa: rdi = dst, rsi = signed value -> rax = dst past the decimal digits. Clobbers rcx, rdx, r8, r10.
.Litoa:
    mov rax, rsi
    test rax, rax
    jns 1f
    mov byte ptr [rdi], '-'
    inc rdi
    neg rax
1:  sub rsp, 24
    lea r8, [rsp + 24]
    mov r10, r8
    mov ecx, 10
2:  xor edx, edx
    div rcx
    add dl, '0'
    dec r10
    mov [r10], dl
    test rax, rax
    jnz 2b
3:  mov al, [r10]
    mov [rdi], al
    inc r10
    inc rdi
    cmp r10, r8
    jne 3b
    add rsp, 24
    mov rax, rdi
    ret

# ================================================================ crypto_jwt_verify(ctx64, tok, len, now) -> id | 0
# Register use while scanning JSON: rsi = cursor, r12 = end (a NUL sentinel sits there, so no other bounds checks
# are needed: NUL is invalid wherever it can appear), r13 = frame base (any error: rsp = r13, return 0),
# r15d = nesting budget, rbp = now, r14d = flags, ebx = key class.

# skip JSON whitespace (space, \t, \n, \r); clobbers eax, rcx
.macro JWS
.Lws\@:
    movzx eax, byte ptr [rsi]
    cmp eax, 0x20
    ja .Lwsd\@
    mov rcx, 0x100002600
    bt rcx, rax
    jnc .Lwsd\@
    inc rsi
    jmp .Lws\@
.Lwsd\@:
.endm

.globl crypto_jwt_verify
crypto_jwt_verify:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, JV_FRAME
    cmp rdx, JWT_MAX_TOKEN
    ja .Lv0
    cmp rdx, 47                         # "h.p." + 43 signature chars
    jb .Lv0
    mov rbx, rsi
    mov rbp, rcx
    mov r15, rdi
    lea r12, [rdx - 44]                 # index of the last '.'
    cmp byte ptr [rsi + r12], '.'
    jne .Lv0
    lea rdi, [rsi + r12 + 1]
    mov esi, 43
    mov rdx, rsp
    call crypto_b64url_decode
    cmp rax, 32
    jne .Lv0
    # first '.': the standard header is recognised directly
    xor r14d, r14d
    cmp r12, 38
    jb .Lv_scan
    movdqu xmm0, [rbx]
    movdqu xmm1, [rbx + 16]
    pcmpeqb xmm0, [rip + .Ljwt_hdr]
    pcmpeqb xmm1, [rip + .Ljwt_hdr + 16]
    pand xmm0, xmm1
    pmovmskb eax, xmm0
    cmp eax, 0xffff
    jne .Lv_scan
    mov eax, [rbx + 32]
    cmp eax, [rip + .Ljwt_hdr + 32]
    jne .Lv_scan
    cmp byte ptr [rbx + 36], '.'
    jne .Lv_scan
    mov r13d, 36
    mov r14d, 1
    jmp .Lv_mac
.Lv_scan:
    xor r13d, r13d
1:  cmp r13, r12
    jae .Lv0
    cmp byte ptr [rbx + r13], '.'
    je .Lv_mac
    inc r13
    jmp 1b
.Lv_mac:
    mov [rsp + JV_HLEN], r13
    lea rax, [rbx + r13 + 1]
    mov [rsp + JV_PPTR], rax
    mov rax, r12
    sub rax, r13
    dec rax
    mov [rsp + JV_PLEN], rax
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r12
    lea rcx, [rsp + JV_MAC]
    call crypto_hmac_ctx
    movdqu xmm0, [rsp + JV_SIG]
    movdqu xmm1, [rsp + JV_SIG + 16]
    movdqu xmm2, [rsp + JV_MAC]
    movdqu xmm3, [rsp + JV_MAC + 16]
    pxor xmm0, xmm2
    pxor xmm1, xmm3
    por xmm0, xmm1
    ptest xmm0, xmm0
    jnz .Lv0
    mov r13, rsp
    mov r15d, 128
    test r14d, r14d
    jnz .Lv_payload

    # ---- non-standard header: {"alg":"HS256", ...}
    mov rdi, rbx
    mov rsi, [r13 + JV_HLEN]
    lea rdx, [r13 + JV_BUF]
    call crypto_b64url_decode
    test rax, rax
    js .Lv0
    lea rsi, [r13 + JV_BUF]
    lea r12, [rsi + rax]
    mov byte ptr [r12], 0
    JWS
    cmp byte ptr [rsi], '{'
    jne .Lj_fail
    inc rsi
    JWS
    cmp byte ptr [rsi], '}'
    je .Lh_close
.Lh_key:
    cmp byte ptr [rsi], '"'
    jne .Lj_fail
    lea rdi, [r13 + JV_KEY]
    mov ecx, 8
    call .Lj_str
    xor ebx, ebx
    cmp eax, 3
    jne 1f
    mov eax, [r13 + JV_KEY]
    and eax, 0xffffff
    cmp eax, 0x676c61                   # "alg"
    sete bl
1:  JWS
    cmp byte ptr [rsi], ':'
    jne .Lj_fail
    inc rsi
    JWS
    test ebx, ebx
    jz .Lh_skip
    bts r14d, 1
    jc .Lj_fail                         # duplicate alg
    cmp byte ptr [rsi], '"'
    jne .Lj_fail
    lea rdi, [r13 + JV_KEY]
    mov ecx, 8
    call .Lj_str
    cmp eax, 5
    jne .Lj_fail
    cmp dword ptr [r13 + JV_KEY], 0x35325348    # "HS25"
    jne .Lj_fail
    cmp byte ptr [r13 + JV_KEY + 4], '6'
    jne .Lj_fail
    jmp .Lh_next
.Lh_skip:
    call .Lj_skip
.Lh_next:
    JWS
    cmp byte ptr [rsi], ','
    jne 2f
    inc rsi
    JWS
    jmp .Lh_key
2:  cmp byte ptr [rsi], '}'
    jne .Lj_fail
.Lh_close:
    inc rsi
    JWS
    cmp rsi, r12
    jne .Lj_fail
    test r14d, 2
    jz .Lj_fail

    # ---- payload; r14d bits: 0 sub seen, 1 exp seen, 2 nbf seen, 3 exp > now, 4 nbf > now
.Lv_payload:
    mov rdi, [r13 + JV_PPTR]
    mov rsi, [r13 + JV_PLEN]
    lea rdx, [r13 + JV_BUF]
    call crypto_b64url_decode
    test rax, rax
    js .Lv0
    lea rsi, [r13 + JV_BUF]
    lea r12, [rsi + rax]
    mov byte ptr [r12], 0
    xor r14d, r14d
    JWS
    cmp byte ptr [rsi], '{'
    jne .Lj_fail
    inc rsi
    JWS
    cmp byte ptr [rsi], '}'
    je .Lp_close
.Lp_key:
    cmp byte ptr [rsi], '"'
    jne .Lj_fail
    lea rdi, [r13 + JV_KEY]
    mov ecx, 8
    call .Lj_str
    xor ebx, ebx
    cmp eax, 3
    jne 1f
    mov eax, [r13 + JV_KEY]
    and eax, 0xffffff
    mov ebx, 1
    cmp eax, 0x627573                   # "sub"
    je 1f
    mov ebx, 2
    cmp eax, 0x707865                   # "exp"
    je 1f
    mov ebx, 3
    cmp eax, 0x66626e                   # "nbf"
    je 1f
    xor ebx, ebx
1:  JWS
    cmp byte ptr [rsi], ':'
    jne .Lj_fail
    inc rsi
    JWS
    cmp ebx, 1
    je .Lp_sub
    cmp ebx, 2
    je .Lp_exp
    cmp ebx, 3
    je .Lp_nbf
    call .Lj_skip
    jmp .Lp_next
.Lp_sub:
    bts r14d, 0
    jc .Lj_fail
    cmp byte ptr [rsi], '"'
    jne .Lj_fail
    lea rdi, [r13 + JV_STR]
    mov ecx, JV_STRCAP
    call .Lj_str
    mov [r13 + JV_HLEN], rax
    jmp .Lp_next
.Lp_exp:
    bts r14d, 1
    jc .Lj_fail
    call .Lj_num
    shl eax, 3
    or r14d, eax
    jmp .Lp_next
.Lp_nbf:
    bts r14d, 2
    jc .Lj_fail
    cmp byte ptr [rsi], 'n'
    jne 3f
    cmp dword ptr [rsi], 0x6c6c756e     # null = absent
    jne .Lj_fail
    add rsi, 4
    jmp .Lp_next
3:  call .Lj_num
    shl eax, 4
    or r14d, eax
.Lp_next:
    JWS
    cmp byte ptr [rsi], ','
    jne 2f
    inc rsi
    JWS
    jmp .Lp_key
2:  cmp byte ptr [rsi], '}'
    jne .Lj_fail
.Lp_close:
    inc rsi
    JWS
    cmp rsi, r12
    jne .Lj_fail
    mov eax, r14d
    and eax, 0x1b
    cmp eax, 0x0b                       # sub, exp, exp > now, not nbf > now
    jne .Lv0
    mov rcx, [r13 + JV_HLEN]
    test rcx, rcx
    jz .Lv0
    cmp rcx, JV_STRCAP
    ja .Lv0
    lea rdi, [r13 + JV_STR]
    xor eax, eax
4:  movzx edx, byte ptr [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .Lv0
    imul rax, rax, 10
    jo .Lv0
    add rax, rdx
    jo .Lv0
    inc rdi
    dec rcx
    jnz 4b
    test rax, rax
    jz .Lv0
    jmp .Lvret
.Lj_fail:
    mov rsp, r13
.Lv0:
    xor eax, eax
.Lvret:
    add rsp, JV_FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ---------------------------------------------------------------- .Lj_str
# rsi -> opening quote; rdi = dst, ecx = cap (0 = validate only). Returns eax = decoded length (bytes past cap are
# counted, not stored; each non-ASCII \u escape decodes to one 0x80 placeholder byte), rsi past the closing quote.
# Clobbers edx, r8-r10.
.Lj_str:
    inc rsi
    xor eax, eax
.Ls_loop:
    movzx edx, byte ptr [rsi]
    inc rsi
    cmp edx, '"'
    je .Ls_done
    cmp edx, '\\'
    je .Ls_esc
    cmp edx, 0x20
    jb .Lj_fail
.Ls_put:
    cmp eax, ecx
    jae 1f
    mov [rdi + rax], dl
1:  inc eax
    jmp .Ls_loop
.Ls_done:
    ret
.Ls_esc:
    movzx edx, byte ptr [rsi]
    inc rsi
    cmp edx, 'u'
    je .Ls_u
    lea r8, [rip + .Lesc_tab]
    movzx edx, byte ptr [r8 + rdx]
    cmp edx, 0xff
    je .Lj_fail
    jmp .Ls_put
.Ls_u:
    call .Lj_hex4
    cmp edx, 0x80
    jb .Ls_put
    mov r8d, edx
    and r8d, 0xfc00
    cmp r8d, 0xdc00
    je .Lj_fail                         # lone low surrogate
    cmp r8d, 0xd800
    jne 2f
    cmp word ptr [rsi], 0x755c          # high surrogate needs "\u" + low surrogate
    jne .Lj_fail
    add rsi, 2
    call .Lj_hex4
    and edx, 0xfc00
    cmp edx, 0xdc00
    jne .Lj_fail
2:  mov edx, 0x80
    jmp .Ls_put

# rsi -> 4 hex digits; edx = value, rsi += 4. Clobbers r9d, r10d.
.Lj_hex4:
    xor edx, edx
.rept 4
    movzx r9d, byte ptr [rsi]
    inc rsi
    lea r10d, [r9 - '0']
    cmp r10d, 9
    jbe 1f
    or r9d, 0x20
    lea r10d, [r9 - 'a']
    cmp r10d, 5
    ja .Lj_fail
    add r10d, 10
1:  shl edx, 4
    or edx, r10d
.endr
    ret

# ---------------------------------------------------------------- .Lj_num
# rsi -> number (RFC 8259 grammar, anything else fails). Returns eax = 1 if value > now (rbp, signed; a negative
# value is never > now), else 0; rsi past the number. Exact: value = digits * 10^(exp - nfrac); the integer part is
# accumulated (saturating to "big" above 2^63-1) and any non-zero fractional digit is remembered.
# Clobbers rcx, rdx, rdi, r8-r11.
.macro NUM_DIGIT
    test rdx, rdx
    jle .Lnf\@
    dec rdx
    test r8d, 2
    jnz .Lnd\@
    imul rax, rax, 10
    jo .Lnb\@
    add rax, rcx
    jno .Lnd\@
.Lnb\@:
    or r8d, 2
    jmp .Lnd\@
.Lnf\@:
    test ecx, ecx
    jz .Lnd\@
    or r8d, 4
.Lnd\@:
.endm

.Lj_num:
    xor r8d, r8d                        # bit 0 negative, bit 1 big, bit 2 non-zero fraction
    cmp byte ptr [rsi], '-'
    jne 1f
    inc rsi
    mov r8d, 1
1:  mov r9, rsi                         # integer digits
    movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .Lj_fail
    inc rsi
    test eax, eax
    jz 3f                               # a leading 0 stands alone ("01" leaves '1' for the caller to reject)
2:  movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    ja 3f
    inc rsi
    jmp 2b
3:  mov r10, rsi
    sub r10, r9                         # integer digit count
    xor r11d, r11d                      # fraction digit count
    cmp byte ptr [rsi], '.'
    jne 5f
    inc rsi
    mov rdi, rsi                        # fraction digits
4:  movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    ja 41f
    inc rsi
    jmp 4b
41: mov r11, rsi
    sub r11, rdi
    jz .Lj_fail
5:  xor edx, edx                        # decimal exponent (saturates at 1e6)
    movzx eax, byte ptr [rsi]
    or eax, 0x20
    cmp eax, 'e'
    jne 8f
    inc rsi
    xor ecx, ecx
    movzx eax, byte ptr [rsi]
    cmp eax, '+'
    je 6f
    cmp eax, '-'
    jne 61f
    mov ecx, 1
6:  inc rsi
61: movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .Lj_fail
7:  cmp rdx, 1000000
    jae 71f
    imul rdx, rdx, 10
    add rdx, rax
71: inc rsi
    movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    jbe 7b
    test ecx, ecx
    jz 8f
    neg rdx
8:  add rdx, r10                        # rdx = digits before the decimal point
    xor eax, eax                        # floor(value)
.Ln_int:
    test r10, r10
    jz .Ln_frac
    movzx ecx, byte ptr [r9]
    sub ecx, '0'
    inc r9
    dec r10
    NUM_DIGIT
    jmp .Ln_int
.Ln_frac:
    test r11, r11
    jz .Ln_tail
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    inc rdi
    dec r11
    NUM_DIGIT
    jmp .Ln_frac
.Ln_tail:                               # remaining positive exponent: floor *= 10^rdx
    test rdx, rdx
    jle .Ln_cmp
    test rax, rax
    jz .Ln_cmp
    test r8d, 2
    jnz .Ln_cmp
    imul rax, rax, 10
    jo .Ln_big
    dec rdx
    jmp .Ln_tail
.Ln_big:
    or r8d, 2
.Ln_cmp:
    test r8d, 1
    jnz .Ln_false
    test r8d, 2
    jnz .Ln_true
    cmp rax, rbp
    jg .Ln_true
    jl .Ln_false
    mov eax, r8d                        # equal integer part: greater iff a fraction remains
    shr eax, 2
    and eax, 1
    ret
.Ln_true:
    mov eax, 1
    ret
.Ln_false:
    xor eax, eax
    ret

# ---------------------------------------------------------------- .Lj_skip
# rsi -> any JSON value (whitespace already skipped); validates and skips it. Nesting costs r15d.
.Lj_skip:
    movzx eax, byte ptr [rsi]
    cmp eax, '"'
    je .Lk_str
    cmp eax, '{'
    je .Lk_obj
    cmp eax, '['
    je .Lk_arr
    cmp eax, 't'
    je .Lk_true
    cmp eax, 'f'
    je .Lk_false
    cmp eax, 'n'
    je .Lk_null
    jmp .Lj_num
.Lk_str:
    xor ecx, ecx
    jmp .Lj_str
.Lk_true:
    cmp dword ptr [rsi], 0x65757274     # true
    jne .Lj_fail
    add rsi, 4
    ret
.Lk_null:
    cmp dword ptr [rsi], 0x6c6c756e     # null
    jne .Lj_fail
    add rsi, 4
    ret
.Lk_false:
    cmp dword ptr [rsi + 1], 0x65736c61 # (f)alse
    jne .Lj_fail
    add rsi, 5
    ret
.Lk_obj:
    dec r15d
    jz .Lj_fail
    inc rsi
    JWS
    cmp byte ptr [rsi], '}'
    je .Lk_obj_end
.Lk_obj_key:
    cmp byte ptr [rsi], '"'
    jne .Lj_fail
    xor ecx, ecx
    call .Lj_str
    JWS
    cmp byte ptr [rsi], ':'
    jne .Lj_fail
    inc rsi
    JWS
    call .Lj_skip
    JWS
    cmp byte ptr [rsi], ','
    jne 1f
    inc rsi
    JWS
    jmp .Lk_obj_key
1:  cmp byte ptr [rsi], '}'
    jne .Lj_fail
.Lk_obj_end:
    inc rsi
    inc r15d
    ret
.Lk_arr:
    dec r15d
    jz .Lj_fail
    inc rsi
    JWS
    cmp byte ptr [rsi], ']'
    je .Lk_arr_end
.Lk_arr_val:
    call .Lj_skip
    JWS
    cmp byte ptr [rsi], ','
    jne 1f
    inc rsi
    JWS
    jmp .Lk_arr_val
1:  cmp byte ptr [rsi], ']'
    jne .Lj_fail
.Lk_arr_end:
    inc rsi
    inc r15d
    ret

# ================================================================ read-only data
.section .rodata
.balign 16
.Liv:
    .long 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
.Lk256:
    .long 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    .long 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    .long 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    .long 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    .long 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    .long 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    .long 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    .long 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
.Lbswap32:                              # pshufb mask: byte-swap each dword
    .byte 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12
.Lipad:
    .fill 16, 1, 0x36
.Lipad_opad:                            # 0x36 ^ 0x5c
    .fill 16, 1, 0x6a
.Ljwt_hdr:                              # base64url('{"alg":"HS256","typ":"JWT"}') + '.'
    .ascii "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    .balign 8
.Ljs_sub:
    .ascii "{\"sub\":\""
.Ljs_iat:
    .ascii "\",\"iat\":"
.Ljs_exp:
    .ascii ",\"exp\":}"                 # 7 bytes used
.Lb64_alpha:
    .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
.Lb64url_alpha:
    .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
.Lb64_dec:
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3e, 0xff, 0xff, 0xff, 0x3f
    .byte 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e
    .byte 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28
    .byte 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0xff, 0xff, 0xff, 0xff, 0xff
    .fill 128, 1, 0xff
.Lb64url_dec:
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3e, 0xff, 0xff
    .byte 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    .byte 0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e
    .byte 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0xff, 0xff, 0xff, 0xff, 0x3f
    .byte 0xff, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28
    .byte 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0xff, 0xff, 0xff, 0xff, 0xff
    .fill 128, 1, 0xff
.Lesc_tab:                              # JSON escape letter -> byte (0xff = invalid; 'u' handled separately)
    .fill 34, 1, 0xff
    .byte 0x22                          # "
    .fill 12, 1, 0xff
    .byte 0x2f                          # /
    .fill 44, 1, 0xff
    .byte 0x5c                          # backslash (0x5c)
    .fill 5, 1, 0xff
    .byte 0x08                          # b (0x62)
    .fill 3, 1, 0xff
    .byte 0x0c                          # f (0x66)
    .fill 7, 1, 0xff
    .byte 0x0a                          # n (0x6e)
    .fill 3, 1, 0xff
    .byte 0x0d                          # r (0x72)
    .byte 0xff
    .byte 0x09                          # t (0x74)
    .fill 139, 1, 0xff

.section .note.GNU-stack,"",@progbits
