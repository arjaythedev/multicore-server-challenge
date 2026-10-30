# bcrypt.s: OpenBSD/Openwall bcrypt (Eksblowfish), $2a/$2b/$2y, cost 4..31.
# Exports: bcrypt_hash, bcrypt_verify, bcrypt_verify_batch, bcrypt_hash_batch.
# No libc, no globals (read-only tables only). All contexts live on the caller stack.
.intel_syntax noprefix
.include "defs.inc"

# ======================================================================= rodata
.section .rodata
.align 64
.include "bcrypt.inc"          # bf_init_S (1024 words), bf_init_P (18 words)

.align 16
bf_magic:                         # "OrpheanBeholderScryDoubt" as 6 big-endian words
    .long 0x4F727068, 0x65616E42, 0x65686F6C, 0x64657253, 0x63727944, 0x6F756274

bf_itoa64:                        # radix-64 alphabet ./A-Za-z0-9
    .ascii "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

.align 16
bf_atoi64:                        # indexed by (char - 0x20), 64 = invalid
    .byte 64,64,64,64,64,64,64,64,64,64,64,64,64,64, 0, 1
    .byte 54,55,56,57,58,59,60,61,62,63,64,64,64,64,64,64
    .byte 64, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,16
    .byte 17,18,19,20,21,22,23,24,25,26,27,64,64,64,64,64
    .byte 64,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42
    .byte 43,44,45,46,47,48,49,50,51,52,53,64,64,64,64,64

# ======================================================================= macros
# esi = low byte of a lane register (r8d..r15d, edi, ebp)
.macro LOB x
    .ifc \x,r8d
    movzx esi, r8b
    .endif
    .ifc \x,r9d
    movzx esi, r9b
    .endif
    .ifc \x,r10d
    movzx esi, r10b
    .endif
    .ifc \x,r11d
    movzx esi, r11b
    .endif
    .ifc \x,r12d
    movzx esi, r12b
    .endif
    .ifc \x,r13d
    movzx esi, r13b
    .endif
    .ifc \x,r14d
    movzx esi, r14b
    .endif
    .ifc \x,r15d
    movzx esi, r15b
    .endif
    .ifc \x,edi
    movzx esi, dil
    .endif
    .ifc \x,ebp
    movzx esi, bpl
    .endif
.endm

# edx = F(x) for a lane whose S-boxes start at [rbx + \d]:
#   ((S0[b3] + S1[b2]) ^ S2[b1]) + S3[b0]. One copy of x gives b1 (dh), b2 (dl after >> 16) and b3 (>> 8 more);
#   b0 is the lane's low byte. Clobbers eax, esi.
.macro FF x, d
    mov   edx, \x
    movzx esi, dh                           # b1
    shr   edx, 16
    movzx eax, dl                           # b2
    shr   edx, 8                            # b3
    mov   edx, [rbx + \d + 0 + rdx*4]       # S0[x>>24]
    add   edx, [rbx + \d + 1024 + rax*4]    # + S1[(x>>16)&255]
    xor   edx, [rbx + \d + 2048 + rsi*4]    # ^ S2[(x>>8)&255]
    LOB   \x
    add   edx, [rbx + \d + 3072 + rsi*4]    # + S3[x&255]
.endm

# dst ^= F(src) ^ P[p]    (P-array at [rbx + \d + BCX_P])
.macro RND dst, src, d, p
    FF    \src, \d
    xor   \dst, edx
    xor   \dst, [rbx + \d + BCX_P + \p*4]
.endm

# ======================================================================= text
.text

# -------- bf_enc1: single-lane Blowfish block encrypt. L=r8d R=r9d ctx=rbx.
# Clobbers eax,edx,esi. Preserves everything else (incl rcx,rbp,rdi,r10-r15).
bf_enc1:
    xor   r8d, [rbx + BCX_P + 0]
    RND   r9d, r8d, 0, 1
    RND   r8d, r9d, 0, 2
    RND   r9d, r8d, 0, 3
    RND   r8d, r9d, 0, 4
    RND   r9d, r8d, 0, 5
    RND   r8d, r9d, 0, 6
    RND   r9d, r8d, 0, 7
    RND   r8d, r9d, 0, 8
    RND   r9d, r8d, 0, 9
    RND   r8d, r9d, 0, 10
    RND   r9d, r8d, 0, 11
    RND   r8d, r9d, 0, 12
    RND   r9d, r8d, 0, 13
    RND   r8d, r9d, 0, 14
    RND   r9d, r8d, 0, 15
    RND   r8d, r9d, 0, 16
    mov   eax, r8d                 # t = L
    mov   r8d, r9d                 # L = R ^ P[17]
    xor   r8d, [rbx + BCX_P + 17*4]
    mov   r9d, eax                 # R = t
    ret

# -------- bf_expand_plain: key schedule with zero salt (BF_body). ctx=rbx, carries L=r8d R=r9d.
# Caller sets L,R (0 at start of each P^=key / P^=salt step). Clobbers eax,edx,esi,ecx.
bf_expand_plain:
    xor   ecx, ecx
.Lpp_plain:
    call  bf_enc1
    mov   [rbx + BCX_P + rcx], r8d
    mov   [rbx + BCX_P + rcx + 4], r9d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp_plain
    xor   ecx, ecx
.Lps_plain:
    call  bf_enc1
    mov   [rbx + rcx], r8d
    mov   [rbx + rcx + 4], r9d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps_plain
    ret

# -------- bf_expand_salted: initial salted expansion (BF_crypt mode 0). ctx=rbx, L=r8d=R=r9d=0 at entry.
# salt words at [rbx+BCX_SALT]. Clobbers eax,edx,esi,ecx,r10d,r11d.
bf_expand_salted:
    xor   ecx, ecx                 # pair index counter (bytes into P)
.Lpp_salt:
    # P-phase: pair p (p=ecx/8). even p -> salt word0,1; odd p -> salt word2,3
    mov   r10d, ecx
    and   r10d, 8                  # byte offset 0 (word0) or 8 (word2)
    xor   r8d, [rbx + BCX_SALT + r10]       # L ^= salt word0 or 2
    xor   r9d, [rbx + BCX_SALT + r10 + 4]   # R ^= salt word1 or 3
    call  bf_enc1
    mov   [rbx + BCX_P + rcx], r8d
    mov   [rbx + BCX_P + rcx + 4], r9d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp_salt
    xor   ecx, ecx
.Lps_salt:
    # S-phase: even pair -> salt word2,3; odd pair -> salt word0,1
    mov   r10d, ecx
    and   r10d, 8                  # 0 (even) or 8 (odd)
    xor   r10d, 8                  # even->8 (word2), odd->0 (word0)
    xor   r8d, [rbx + BCX_SALT + r10]
    xor   r9d, [rbx + BCX_SALT + r10 + 4]
    call  bf_enc1
    mov   [rbx + rcx], r8d
    mov   [rbx + rcx + 4], r9d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps_salt
    ret

# -------- bc_setkey(pw=rdi, len=rsi, flags=edx) -> writes ctx(rbx).EK and ctx.P = initP ^ ek (+safety)
# Clobbers rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14.  Preserves rbx,rbp,r15.
bc_setkey:
    push  rbx
    push  rbp
    push  r15
    # r12=pw r13=len r14=flags, r15=key index j, rbp=i
    mov   r12, rdi
    mov   r13, rsi
    mov   r14d, edx
    xor   r15d, r15d               # j = 0
    xor   ebp, ebp                 # i = 0 (word index)
    xor   r9d, r9d                 # sign = 0
    xor   r10d, r10d               # diff = 0
.Lsk_word:
    xor   r8d, r8d                 # tmp0
    xor   r11d, r11d               # tmp1
    xor   ecx, ecx                 # k = 0
.Lsk_byte:
    # fetch key byte into eax (0..255) and sign-extended into edx
    cmp   r15, r13
    jb    .Lsk_have                # j < len -> pw[j]
    xor   eax, eax                 # j == len -> NUL
    xor   r15d, r15d               # wrap j = 0
    jmp   .Lsk_got
.Lsk_have:
    movzx eax, byte ptr [r12 + r15]
    inc   r15
.Lsk_got:
    movsx edx, al                  # sign-extended byte
    shl   r8d, 8
    or    r8d, eax                 # tmp0 = (tmp0<<8)|b
    shl   r11d, 8
    or    r11d, edx                # tmp1 = (tmp1<<8)|(u32)(i32)(i8)b
    test  ecx, ecx
    jz    .Lsk_nosign
    mov   eax, r11d
    and   eax, 0x80
    or    r9d, eax                 # sign |= tmp1 & 0x80  (k != 0)
.Lsk_nosign:
    inc   ecx
    cmp   ecx, 4
    jb    .Lsk_byte
    # diff |= tmp0 ^ tmp1
    mov   eax, r8d
    xor   eax, r11d
    or    r10d, eax
    # ek[i] = bug ? tmp1 : tmp0
    mov   eax, r8d                 # tmp0
    test  r14d, 1                  # bug bit
    jz    .Lsk_store
    mov   eax, r11d                # tmp1
.Lsk_store:
    mov   [rbx + BCX_EK + rbp*4], eax
    lea   rcx, [rip + bf_init_P]
    mov   edx, [rcx + rbp*4]
    xor   edx, eax
    mov   [rbx + BCX_P + rbp*4], edx
    inc   ebp
    cmp   ebp, 18
    jb    .Lsk_word
    # finalize safety
    mov   eax, r10d                # diff
    mov   edx, eax
    shr   edx, 16
    or    eax, edx
    and   eax, 0xffff
    add   eax, 0xffff              # bit16 set iff diff nonzero
    not   eax                      # ~diff
    mov   edx, r14d
    and   edx, 2
    shl   edx, 15                  # safety = (flags&2)<<15  (0 or 0x10000)
    shl   r9d, 9                   # sign <<= 9
    and   r9d, eax                 # sign &= ~diff
    and   r9d, edx                 # sign &= safety
    xor   [rbx + BCX_P + 0], r9d   # P[0] ^= sign
    pop   r15
    pop   rbp
    pop   rbx
    ret

# -------- bc_crypt1: run full Eksblowfish on ctx(rbx). cost in r13d. Needs ctx.S=init, ctx.P=initial,
#          ctx.EK set, ctx.SALT set. Leaves 6 output words at ctx.OUT. Clobbers caller-saved + r8-r12.
#          Preserves rbx,r13.
bc_crypt1:
    push  rbp
    push  r12
    push  r14
    push  r15
    # initial salted expansion
    xor   r8d, r8d
    xor   r9d, r9d
    call  bf_expand_salted
    # main loop: 2^cost iterations
    mov   eax, 1
    mov   ecx, r13d                # cost -> cl
    shl   eax, cl
    mov   r15d, eax                # r15 = remaining count (2^cost), fits u32 for cost<=31
.Lmain:
    # P ^= ek  (18 words)
    xor   ecx, ecx
.Lxek:
    mov   eax, [rbx + BCX_EK + rcx]
    xor   [rbx + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek
    xor   r8d, r8d
    xor   r9d, r9d
    call  bf_expand_plain
    # P ^= salt (salt[i & 3])
    xor   ecx, ecx                 # word index i (0..17)
.Lxsalt:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rbx + BCX_SALT + rax*4]
    xor   [rbx + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt
    xor   r8d, r8d
    xor   r9d, r9d
    call  bf_expand_plain
    dec   r15d
    jnz   .Lmain
    # final: encrypt magic (6 words) 64 times each pair
    xor   ebp, ebp                 # i = 0,2,4
.Lfin:
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + rbp*4]
    mov   r9d, [rax + rbp*4 + 4]
    mov   r12d, 64
.Lfin64:
    call  bf_enc1
    dec   r12d
    jnz   .Lfin64
    mov   [rbx + BCX_OUT + rbp*4], r8d
    mov   [rbx + BCX_OUT + rbp*4 + 4], r9d
    add   ebp, 2
    cmp   ebp, 6
    jb    .Lfin
    pop   r15
    pop   r14
    pop   r12
    pop   rbp
    ret

# -------- bc_b64enc(src=rdi, nbytes=rsi, dst=rdx): Openwall BF_encode (base64, no pad). Returns nothing.
# Clobbers rax,rcx,r8,r9,r10,r11.
bc_b64enc:
    lea   r8, [rip + bf_itoa64]
    xor   rcx, rcx                 # src index
.Lbe_loop:
    movzx r9d, byte ptr [rdi + rcx]        # c1
    inc   rcx
    mov   eax, r9d
    shr   eax, 2
    movzx eax, byte ptr [r8 + rax]
    mov   [rdx], al
    inc   rdx
    mov   r10d, r9d
    and   r10d, 3
    shl   r10d, 4                  # c = (c1&3)<<4
    cmp   rcx, rsi
    jae   .Lbe_tail1
    movzx r9d, byte ptr [rdi + rcx]        # c2
    inc   rcx
    mov   eax, r9d
    shr   eax, 4
    or    eax, r10d
    movzx eax, byte ptr [r8 + rax]
    mov   [rdx], al
    inc   rdx
    mov   r10d, r9d
    and   r10d, 0x0f
    shl   r10d, 2                  # c = (c2&0x0f)<<2
    cmp   rcx, rsi
    jae   .Lbe_tail2
    movzx r9d, byte ptr [rdi + rcx]        # c2 (next)
    inc   rcx
    mov   eax, r9d
    shr   eax, 6
    or    eax, r10d
    movzx eax, byte ptr [r8 + rax]
    mov   [rdx], al
    inc   rdx
    mov   eax, r9d
    and   eax, 0x3f
    movzx eax, byte ptr [r8 + rax]
    mov   [rdx], al
    inc   rdx
    cmp   rcx, rsi
    jb    .Lbe_loop
    ret
.Lbe_tail1:
    movzx eax, byte ptr [r8 + r10]
    mov   [rdx], al
    inc   rdx
    ret
.Lbe_tail2:
    movzx eax, byte ptr [r8 + r10]
    mov   [rdx], al
    inc   rdx
    ret

# -------- bc_b64dec(src=rdi, nbytes=rsi, dst=rdx): BF_decode. Returns rax=0 ok / -1 bad char.
# Decodes exactly rsi output bytes from rdi. Clobbers rax,rcx,r8,r9,r10,r11,rdi,rdx.
# atoi64 of a char returns value 0..63 or 64 (invalid) via table bf_atoi64[char-0x20] (range-checked).
bc_b64dec:
    lea   r8, [rip + bf_atoi64]
    add   rsi, rdx                 # end = dst + nbytes
.Lbd_loop:
    # c1
    movzx eax, byte ptr [rdi]
    inc   rdi
    sub   eax, 0x20
    cmp   eax, 0x60
    jae   .Lbd_bad
    movzx r10d, byte ptr [r8 + rax]        # c1
    cmp   r10d, 63
    ja    .Lbd_bad
    # c2
    movzx eax, byte ptr [rdi]
    inc   rdi
    sub   eax, 0x20
    cmp   eax, 0x60
    jae   .Lbd_bad
    movzx r11d, byte ptr [r8 + rax]        # c2
    cmp   r11d, 63
    ja    .Lbd_bad
    mov   eax, r10d
    shl   eax, 2
    mov   ecx, r11d
    and   ecx, 0x30
    shr   ecx, 4
    or    eax, ecx                 # (c1<<2)|((c2&0x30)>>4)
    mov   [rdx], al
    inc   rdx
    cmp   rdx, rsi
    jae   .Lbd_done
    # c3
    movzx eax, byte ptr [rdi]
    inc   rdi
    sub   eax, 0x20
    cmp   eax, 0x60
    jae   .Lbd_bad
    movzx r9d, byte ptr [r8 + rax]         # c3
    cmp   r9d, 63
    ja    .Lbd_bad
    mov   eax, r11d
    and   eax, 0x0f
    shl   eax, 4
    mov   ecx, r9d
    and   ecx, 0x3c
    shr   ecx, 2
    or    eax, ecx                 # ((c2&0x0f)<<4)|((c3&0x3c)>>2)
    mov   [rdx], al
    inc   rdx
    cmp   rdx, rsi
    jae   .Lbd_done
    # c4
    movzx eax, byte ptr [rdi]
    inc   rdi
    sub   eax, 0x20
    cmp   eax, 0x60
    jae   .Lbd_bad
    movzx ecx, byte ptr [r8 + rax]         # c4
    cmp   ecx, 63
    ja    .Lbd_bad
    mov   eax, r9d
    and   eax, 3
    shl   eax, 6
    or    eax, ecx                 # ((c3&3)<<6)|c4
    mov   [rdx], al
    inc   rdx
    cmp   rdx, rsi
    jb    .Lbd_loop
.Lbd_done:
    xor   eax, eax
    ret
.Lbd_bad:
    mov   rax, -1
    ret

# ================================================================ 2/3-lane engines

# -------- bf_enc2: 2-lane Blowfish encrypt. L in r8d,r9d; R in r12d,r13d. ctx0=rbx.
bf_enc2:
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P]
    RND   r12d, r8d, 0*BCX_SIZE, 1
    RND   r13d, r9d, 1*BCX_SIZE, 1
    RND   r8d, r12d, 0*BCX_SIZE, 2
    RND   r9d, r13d, 1*BCX_SIZE, 2
    RND   r12d, r8d, 0*BCX_SIZE, 3
    RND   r13d, r9d, 1*BCX_SIZE, 3
    RND   r8d, r12d, 0*BCX_SIZE, 4
    RND   r9d, r13d, 1*BCX_SIZE, 4
    RND   r12d, r8d, 0*BCX_SIZE, 5
    RND   r13d, r9d, 1*BCX_SIZE, 5
    RND   r8d, r12d, 0*BCX_SIZE, 6
    RND   r9d, r13d, 1*BCX_SIZE, 6
    RND   r12d, r8d, 0*BCX_SIZE, 7
    RND   r13d, r9d, 1*BCX_SIZE, 7
    RND   r8d, r12d, 0*BCX_SIZE, 8
    RND   r9d, r13d, 1*BCX_SIZE, 8
    RND   r12d, r8d, 0*BCX_SIZE, 9
    RND   r13d, r9d, 1*BCX_SIZE, 9
    RND   r8d, r12d, 0*BCX_SIZE, 10
    RND   r9d, r13d, 1*BCX_SIZE, 10
    RND   r12d, r8d, 0*BCX_SIZE, 11
    RND   r13d, r9d, 1*BCX_SIZE, 11
    RND   r8d, r12d, 0*BCX_SIZE, 12
    RND   r9d, r13d, 1*BCX_SIZE, 12
    RND   r12d, r8d, 0*BCX_SIZE, 13
    RND   r13d, r9d, 1*BCX_SIZE, 13
    RND   r8d, r12d, 0*BCX_SIZE, 14
    RND   r9d, r13d, 1*BCX_SIZE, 14
    RND   r12d, r8d, 0*BCX_SIZE, 15
    RND   r13d, r9d, 1*BCX_SIZE, 15
    RND   r8d, r12d, 0*BCX_SIZE, 16
    RND   r9d, r13d, 1*BCX_SIZE, 16
    mov   eax, r8d
    mov   r8d, r12d
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P + 17*4]
    mov   r12d, eax
    mov   eax, r9d
    mov   r9d, r13d
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P + 17*4]
    mov   r13d, eax
    ret

# -------- bf_expand_plain2: 2-lane key schedule, zero salt.
bf_expand_plain2:
    xor   ecx, ecx
.Lpp2:
    call  bf_enc2
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp2
    xor   ecx, ecx
.Lps2:
    call  bf_enc2
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps2
    ret

# -------- bf_expand_salted2: 2-lane initial salted expansion.
bf_expand_salted2:
    xor   ecx, ecx
.Lpps2:
    mov   eax, ecx
    and   eax, 8
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc2
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpps2
    xor   ecx, ecx
.Lpss2:
    mov   eax, ecx
    and   eax, 8
    xor   eax, 8
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc2
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lpss2
    ret

# -------- bc_crypt2: full Eksblowfish on 2 contiguous ctxs (rbx=ctx0, edi=cost). Preserves callee-saved.
bc_crypt2:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    mov   ecx, edi
    mov   eax, 1
    shl   eax, cl
    mov   ebp, eax                 # remaining = 2^cost
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r12d, r12d
    xor   r13d, r13d
    call  bf_expand_salted2
.Lmain2:
    xor   ecx, ecx
.Lxek2:
    mov   eax, [rbx + 0*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 1*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek2
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r12d, r12d
    xor   r13d, r13d
    call  bf_expand_plain2
    xor   ecx, ecx
.Lxsalt2:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rbx + 0*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 1*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt2
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r12d, r12d
    xor   r13d, r13d
    call  bf_expand_plain2
    dec   ebp
    jnz   .Lmain2
    xor   edi, edi
.Lfin2:
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + rdi*4]
    mov   r12d, [rax + rdi*4 + 4]
    mov   r9d, [rax + rdi*4]
    mov   r13d, [rax + rdi*4 + 4]
    mov   ecx, 64
.Lfinb2:
    call  bf_enc2
    dec   ecx
    jnz   .Lfinb2
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4 + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4 + 4], r13d
    add   edi, 2
    cmp   edi, 6
    jb    .Lfin2
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# -------- bf_enc3: 3-lane Blowfish encrypt. L in r8d,r9d,r10d; R in r12d,r13d,r14d. ctx0=rbx.
bf_enc3:
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P]
    RND   r12d, r8d, 0*BCX_SIZE, 1
    RND   r13d, r9d, 1*BCX_SIZE, 1
    RND   r14d, r10d, 2*BCX_SIZE, 1
    RND   r8d, r12d, 0*BCX_SIZE, 2
    RND   r9d, r13d, 1*BCX_SIZE, 2
    RND   r10d, r14d, 2*BCX_SIZE, 2
    RND   r12d, r8d, 0*BCX_SIZE, 3
    RND   r13d, r9d, 1*BCX_SIZE, 3
    RND   r14d, r10d, 2*BCX_SIZE, 3
    RND   r8d, r12d, 0*BCX_SIZE, 4
    RND   r9d, r13d, 1*BCX_SIZE, 4
    RND   r10d, r14d, 2*BCX_SIZE, 4
    RND   r12d, r8d, 0*BCX_SIZE, 5
    RND   r13d, r9d, 1*BCX_SIZE, 5
    RND   r14d, r10d, 2*BCX_SIZE, 5
    RND   r8d, r12d, 0*BCX_SIZE, 6
    RND   r9d, r13d, 1*BCX_SIZE, 6
    RND   r10d, r14d, 2*BCX_SIZE, 6
    RND   r12d, r8d, 0*BCX_SIZE, 7
    RND   r13d, r9d, 1*BCX_SIZE, 7
    RND   r14d, r10d, 2*BCX_SIZE, 7
    RND   r8d, r12d, 0*BCX_SIZE, 8
    RND   r9d, r13d, 1*BCX_SIZE, 8
    RND   r10d, r14d, 2*BCX_SIZE, 8
    RND   r12d, r8d, 0*BCX_SIZE, 9
    RND   r13d, r9d, 1*BCX_SIZE, 9
    RND   r14d, r10d, 2*BCX_SIZE, 9
    RND   r8d, r12d, 0*BCX_SIZE, 10
    RND   r9d, r13d, 1*BCX_SIZE, 10
    RND   r10d, r14d, 2*BCX_SIZE, 10
    RND   r12d, r8d, 0*BCX_SIZE, 11
    RND   r13d, r9d, 1*BCX_SIZE, 11
    RND   r14d, r10d, 2*BCX_SIZE, 11
    RND   r8d, r12d, 0*BCX_SIZE, 12
    RND   r9d, r13d, 1*BCX_SIZE, 12
    RND   r10d, r14d, 2*BCX_SIZE, 12
    RND   r12d, r8d, 0*BCX_SIZE, 13
    RND   r13d, r9d, 1*BCX_SIZE, 13
    RND   r14d, r10d, 2*BCX_SIZE, 13
    RND   r8d, r12d, 0*BCX_SIZE, 14
    RND   r9d, r13d, 1*BCX_SIZE, 14
    RND   r10d, r14d, 2*BCX_SIZE, 14
    RND   r12d, r8d, 0*BCX_SIZE, 15
    RND   r13d, r9d, 1*BCX_SIZE, 15
    RND   r14d, r10d, 2*BCX_SIZE, 15
    RND   r8d, r12d, 0*BCX_SIZE, 16
    RND   r9d, r13d, 1*BCX_SIZE, 16
    RND   r10d, r14d, 2*BCX_SIZE, 16
    mov   eax, r8d
    mov   r8d, r12d
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P + 17*4]
    mov   r12d, eax
    mov   eax, r9d
    mov   r9d, r13d
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P + 17*4]
    mov   r13d, eax
    mov   eax, r10d
    mov   r10d, r14d
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P + 17*4]
    mov   r14d, eax
    ret

# -------- bf_expand_plain3: 3-lane key schedule, zero salt.
bf_expand_plain3:
    xor   ecx, ecx
.Lpp3:
    call  bf_enc3
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp3
    xor   ecx, ecx
.Lps3:
    call  bf_enc3
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps3
    ret

# -------- bf_expand_salted3: 3-lane initial salted expansion.
bf_expand_salted3:
    xor   ecx, ecx
.Lpps3:
    mov   eax, ecx
    and   eax, 8
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc3
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpps3
    xor   ecx, ecx
.Lpss3:
    mov   eax, ecx
    and   eax, 8
    xor   eax, 8
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc3
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lpss3
    ret

# -------- bc_crypt3: full Eksblowfish on 3 contiguous ctxs (rbx=ctx0, edi=cost). Preserves callee-saved.
bc_crypt3:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    mov   ecx, edi
    mov   eax, 1
    shl   eax, cl
    mov   ebp, eax                 # remaining = 2^cost
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    call  bf_expand_salted3
.Lmain3:
    xor   ecx, ecx
.Lxek3:
    mov   eax, [rbx + 0*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 1*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 2*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek3
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    call  bf_expand_plain3
    xor   ecx, ecx
.Lxsalt3:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rbx + 0*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 1*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 2*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt3
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    call  bf_expand_plain3
    dec   ebp
    jnz   .Lmain3
    xor   edi, edi
.Lfin3:
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + rdi*4]
    mov   r12d, [rax + rdi*4 + 4]
    mov   r9d, [rax + rdi*4]
    mov   r13d, [rax + rdi*4 + 4]
    mov   r10d, [rax + rdi*4]
    mov   r14d, [rax + rdi*4 + 4]
    mov   ecx, 64
.Lfinb3:
    call  bf_enc3
    dec   ecx
    jnz   .Lfinb3
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4 + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4 + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rdi*4], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rdi*4 + 4], r14d
    add   edi, 2
    cmp   edi, 6
    jb    .Lfin3
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# ======================================================================= 4-lane interleaved engine
# Lanes: L0..3 = r8d,r9d,r10d,r11d ; R0..3 = r12d,r13d,r14d,r15d ; ctx0 = rbx, stride BCX_SIZE.

# -------- bf_enc4: 4 independent Blowfish block encrypts, interleaved per round for ILP.
# Clobbers rax,rdx,rsi. Preserves rbx,rcx,rbp,rdi and uses r8-r15 as the lane state.
bf_enc4:
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_P]
    RND   r12d, r8d, 0*BCX_SIZE, 1
    RND   r13d, r9d, 1*BCX_SIZE, 1
    RND   r14d, r10d, 2*BCX_SIZE, 1
    RND   r15d, r11d, 3*BCX_SIZE, 1
    RND   r8d, r12d, 0*BCX_SIZE, 2
    RND   r9d, r13d, 1*BCX_SIZE, 2
    RND   r10d, r14d, 2*BCX_SIZE, 2
    RND   r11d, r15d, 3*BCX_SIZE, 2
    RND   r12d, r8d, 0*BCX_SIZE, 3
    RND   r13d, r9d, 1*BCX_SIZE, 3
    RND   r14d, r10d, 2*BCX_SIZE, 3
    RND   r15d, r11d, 3*BCX_SIZE, 3
    RND   r8d, r12d, 0*BCX_SIZE, 4
    RND   r9d, r13d, 1*BCX_SIZE, 4
    RND   r10d, r14d, 2*BCX_SIZE, 4
    RND   r11d, r15d, 3*BCX_SIZE, 4
    RND   r12d, r8d, 0*BCX_SIZE, 5
    RND   r13d, r9d, 1*BCX_SIZE, 5
    RND   r14d, r10d, 2*BCX_SIZE, 5
    RND   r15d, r11d, 3*BCX_SIZE, 5
    RND   r8d, r12d, 0*BCX_SIZE, 6
    RND   r9d, r13d, 1*BCX_SIZE, 6
    RND   r10d, r14d, 2*BCX_SIZE, 6
    RND   r11d, r15d, 3*BCX_SIZE, 6
    RND   r12d, r8d, 0*BCX_SIZE, 7
    RND   r13d, r9d, 1*BCX_SIZE, 7
    RND   r14d, r10d, 2*BCX_SIZE, 7
    RND   r15d, r11d, 3*BCX_SIZE, 7
    RND   r8d, r12d, 0*BCX_SIZE, 8
    RND   r9d, r13d, 1*BCX_SIZE, 8
    RND   r10d, r14d, 2*BCX_SIZE, 8
    RND   r11d, r15d, 3*BCX_SIZE, 8
    RND   r12d, r8d, 0*BCX_SIZE, 9
    RND   r13d, r9d, 1*BCX_SIZE, 9
    RND   r14d, r10d, 2*BCX_SIZE, 9
    RND   r15d, r11d, 3*BCX_SIZE, 9
    RND   r8d, r12d, 0*BCX_SIZE, 10
    RND   r9d, r13d, 1*BCX_SIZE, 10
    RND   r10d, r14d, 2*BCX_SIZE, 10
    RND   r11d, r15d, 3*BCX_SIZE, 10
    RND   r12d, r8d, 0*BCX_SIZE, 11
    RND   r13d, r9d, 1*BCX_SIZE, 11
    RND   r14d, r10d, 2*BCX_SIZE, 11
    RND   r15d, r11d, 3*BCX_SIZE, 11
    RND   r8d, r12d, 0*BCX_SIZE, 12
    RND   r9d, r13d, 1*BCX_SIZE, 12
    RND   r10d, r14d, 2*BCX_SIZE, 12
    RND   r11d, r15d, 3*BCX_SIZE, 12
    RND   r12d, r8d, 0*BCX_SIZE, 13
    RND   r13d, r9d, 1*BCX_SIZE, 13
    RND   r14d, r10d, 2*BCX_SIZE, 13
    RND   r15d, r11d, 3*BCX_SIZE, 13
    RND   r8d, r12d, 0*BCX_SIZE, 14
    RND   r9d, r13d, 1*BCX_SIZE, 14
    RND   r10d, r14d, 2*BCX_SIZE, 14
    RND   r11d, r15d, 3*BCX_SIZE, 14
    RND   r12d, r8d, 0*BCX_SIZE, 15
    RND   r13d, r9d, 1*BCX_SIZE, 15
    RND   r14d, r10d, 2*BCX_SIZE, 15
    RND   r15d, r11d, 3*BCX_SIZE, 15
    RND   r8d, r12d, 0*BCX_SIZE, 16
    RND   r9d, r13d, 1*BCX_SIZE, 16
    RND   r10d, r14d, 2*BCX_SIZE, 16
    RND   r11d, r15d, 3*BCX_SIZE, 16
    mov   eax, r8d
    mov   r8d, r12d
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P + 17*4]
    mov   r12d, eax
    mov   eax, r9d
    mov   r9d, r13d
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P + 17*4]
    mov   r13d, eax
    mov   eax, r10d
    mov   r10d, r14d
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P + 17*4]
    mov   r14d, eax
    mov   eax, r11d
    mov   r11d, r15d
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_P + 17*4]
    mov   r15d, eax
    ret

# -------- bf_expand_plain4: 4-lane key schedule, zero salt. L/R carried in r8-r15. Clobbers rax,rcx,rdx,rsi.
bf_expand_plain4:
    xor   ecx, ecx
.Lpp4:
    call  bf_enc4
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx + 4], r15d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp4
    xor   ecx, ecx
.Lps4:
    call  bf_enc4
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + rcx + 4], r15d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps4
    ret

# -------- bf_expand_salted4: 4-lane initial salted expansion. L/R = 0 at entry. Clobbers rax,rcx,rdx,rsi.
bf_expand_salted4:
    xor   ecx, ecx
.Lpps4:
    mov   eax, ecx
    and   eax, 8                   # P-phase salt word byte-offset (0 or 8)
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rbx + 3*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc4
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx + 4], r15d
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpps4
    xor   ecx, ecx
.Lpss4:
    mov   eax, ecx
    and   eax, 8
    xor   eax, 8                   # S-phase salt word byte-offset (8 or 0)
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rbx + 3*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc4
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + rcx + 4], r15d
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lpss4
    ret

# -------- bc_crypt4: full Eksblowfish on 4 contiguous ctxs (rbx=ctx0). cost in edi (shared, all lanes).
# ctx must have S=init, P=initial, EK, SALT set. Leaves 6 OUT words per lane. Preserves callee-saved.
bc_crypt4:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    mov   ecx, edi
    mov   eax, 1
    shl   eax, cl
    mov   ebp, eax                 # remaining count = 2^cost
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    call  bf_expand_salted4
.Lmain4:
    # P ^= ek (18 words per lane)
    xor   ecx, ecx
.Lxek4:
    mov   eax, [rbx + 0*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 1*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 2*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 3*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 3*BCX_SIZE + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek4
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    call  bf_expand_plain4
    # P ^= salt[i & 3] (18 words per lane)
    xor   ecx, ecx
.Lxsalt4:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rbx + 0*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 1*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 2*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 3*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 3*BCX_SIZE + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt4
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    call  bf_expand_plain4
    dec   ebp
    jnz   .Lmain4
    # final: encrypt magic (6 words) 64x per pair, all lanes share the magic IV
    xor   edi, edi                 # word index 0,2,4
.Lfin4:
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + rdi*4]
    mov   r12d, [rax + rdi*4 + 4]
    mov   r9d, r8d
    mov   r13d, r12d
    mov   r10d, r8d
    mov   r14d, r12d
    mov   r11d, r8d
    mov   r15d, r12d
    mov   ecx, 64
.Lfin4b:
    call  bf_enc4
    dec   ecx
    jnz   .Lfin4b
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rdi*4 + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rdi*4 + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rdi*4], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rdi*4 + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_OUT + rdi*4], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_OUT + rdi*4 + 4], r15d
    add   edi, 2
    cmp   edi, 6
    jb    .Lfin4
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret


# ======================================================================= public API

# -------- bcrypt_hash(pw=rdi, pwlen=rsi, salt16=rdx, cost=ecx, out60=r8) -> rax=60
.globl bcrypt_hash
bcrypt_hash:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 4416                # ctx (4352) + 64 scratch
    mov   r12, rdi                 # pw
    mov   r13, rsi                 # pwlen
    mov   r14, rdx                 # salt16
    mov   r15, r8                  # out60
    mov   ebp, ecx                 # cost
    mov   rbx, rsp                 # ctx base
    # prefix "$2b$CC$"
    mov   byte ptr [r15+0], '$'
    mov   byte ptr [r15+1], '2'
    mov   byte ptr [r15+2], 'b'
    mov   byte ptr [r15+3], '$'
    mov   eax, ebp
    mov   dl, 10
    div   dl                       # al=cost/10, ah=cost%10
    add   al, '0'
    mov   [r15+4], al
    mov   al, ah
    add   al, '0'
    mov   [r15+5], al
    mov   byte ptr [r15+6], '$'
    # salt chars: b64enc(salt16,16,out+7)
    mov   rdi, r14
    mov   rsi, 16
    lea   rdx, [r15+7]
    call  bc_b64enc
    # copy init S-boxes
    lea   rsi, [rip + bf_init_S]
    mov   rdi, rbx
    mov   ecx, 512
    rep   movsq
    # salt words (BE32 of each 4 bytes)
    mov   eax, [r14+0]
    bswap eax
    mov   [rbx + BCX_SALT + 0], eax
    mov   eax, [r14+4]
    bswap eax
    mov   [rbx + BCX_SALT + 4], eax
    mov   eax, [r14+8]
    bswap eax
    mov   [rbx + BCX_SALT + 8], eax
    mov   eax, [r14+12]
    bswap eax
    mov   [rbx + BCX_SALT + 12], eax
    # truncate len to 72
    cmp   r13, 72
    jbe   1f
    mov   r13d, 72
1:
    # setkey
    mov   rdi, r12
    mov   rsi, r13
    mov   edx, BCF_2B
    call  bc_setkey
    # crypt
    mov   r13d, ebp                # cost
    call  bc_crypt1
    # finalize: bswap 6 output words into scratch, encode 23 bytes -> out+29
    lea   rdi, [rsp + 4352]        # scratch buf
    mov   eax, [rbx + BCX_OUT + 0]
    bswap eax
    mov   [rdi+0], eax
    mov   eax, [rbx + BCX_OUT + 4]
    bswap eax
    mov   [rdi+4], eax
    mov   eax, [rbx + BCX_OUT + 8]
    bswap eax
    mov   [rdi+8], eax
    mov   eax, [rbx + BCX_OUT + 12]
    bswap eax
    mov   [rdi+12], eax
    mov   eax, [rbx + BCX_OUT + 16]
    bswap eax
    mov   [rdi+16], eax
    mov   eax, [rbx + BCX_OUT + 20]
    bswap eax
    mov   [rdi+20], eax
    mov   rsi, 23
    lea   rdx, [r15+29]
    call  bc_b64enc
    mov   eax, 60
    add   rsp, 4416
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# -------- bcrypt_verify(pw=rdi, pwlen=rsi, hash=rdx, hashlen=rcx) -> rax=1 match / 0
.globl bcrypt_verify
bcrypt_verify:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 4480                # ctx(4352) + out60 + salt16 scratch
    mov   r12, rdi                 # pw
    mov   r13, rsi                 # pwlen
    mov   r14, rdx                 # hash
    mov   r15, rcx                 # hashlen
    mov   rbx, rsp                 # ctx
    # length must be 60
    cmp   r15, 60
    jne   .Lv_no
    # prefix $2[aby]$
    cmp   byte ptr [r14+0], '$'
    jne   .Lv_no
    cmp   byte ptr [r14+1], '2'
    jne   .Lv_no
    movzx eax, byte ptr [r14+2]
    mov   ebp, BCF_2A              # default flags for 'a'
    cmp   al, 'a'
    je    .Lv_sub_ok
    mov   ebp, BCF_2B
    cmp   al, 'b'
    je    .Lv_sub_ok
    cmp   al, 'y'
    je    .Lv_sub_ok
    jmp   .Lv_no
.Lv_sub_ok:
    cmp   byte ptr [r14+3], '$'
    jne   .Lv_no
    movzx eax, byte ptr [r14+4]
    sub   eax, '0'
    cmp   eax, 3
    ja    .Lv_no                   # tens digit 0..3
    movzx ecx, byte ptr [r14+5]
    sub   ecx, '0'
    cmp   ecx, 9
    ja    .Lv_no                   # ones digit 0..9
    lea   eax, [eax + eax*4]       # tens*5
    lea   eax, [ecx + eax*2]       # cost = tens*10 + ones
    cmp   eax, 4
    jb    .Lv_no
    cmp   eax, 31
    ja    .Lv_no
    mov   r9d, eax                 # cost (stash in r9d; survives? not across calls) -> move to stack
    mov   [rsp + 4472], r9d        # save cost
    cmp   byte ptr [r14+6], '$'
    jne   .Lv_no
    # decode salt hash[7..28] -> 16 bytes at rsp+4416
    lea   rdi, [r14+7]
    mov   rsi, 16
    lea   rdx, [rsp + 4416]        # salt16 scratch
    call  bc_b64dec
    test  rax, rax
    js    .Lv_no
    # copy init S
    lea   rsi, [rip + bf_init_S]
    mov   rdi, rbx
    mov   ecx, 512
    rep   movsq
    # salt words from decoded 16 bytes
    lea   r8, [rsp + 4416]
    mov   eax, [r8+0]
    bswap eax
    mov   [rbx + BCX_SALT + 0], eax
    mov   eax, [r8+4]
    bswap eax
    mov   [rbx + BCX_SALT + 4], eax
    mov   eax, [r8+8]
    bswap eax
    mov   [rbx + BCX_SALT + 8], eax
    mov   eax, [r8+12]
    bswap eax
    mov   [rbx + BCX_SALT + 12], eax
    # truncate len to 72
    cmp   r13, 72
    jbe   1f
    mov   r13d, 72
1:
    # setkey (clobbers r12,r13,r14 -> save hash ptr across it)
    mov   [rsp + 4432], r14        # save hash ptr
    mov   rdi, r12
    mov   rsi, r13
    mov   edx, ebp                 # flags
    call  bc_setkey
    mov   r13d, [rsp + 4472]       # cost
    call  bc_crypt1
    mov   r14, [rsp + 4432]        # restore hash ptr
    # build computed 60-char string at rsp+4352
    lea   r10, [rsp + 4352]        # out buf
    # copy hash[0..27] (prefix + 21 salt chars)
    mov   rax, [r14+0]
    mov   [r10+0], rax
    mov   rax, [r14+8]
    mov   [r10+8], rax
    mov   rax, [r14+16]
    mov   [r10+16], rax
    mov   eax, [r14+24]
    mov   [r10+24], eax            # bytes 24..27
    # canonicalize char 28: itoa64[ atoi64[hash[28]-0x20] & 0x30 ]
    movzx eax, byte ptr [r14+28]
    sub   eax, 0x20
    lea   r8, [rip + bf_atoi64]
    movzx eax, byte ptr [r8 + rax]
    and   eax, 0x30
    lea   r8, [rip + bf_itoa64]
    movzx eax, byte ptr [r8 + rax]
    mov   [r10+28], al
    # encode 23 output bytes -> out[29..59]; first bswap into salt16 scratch (reuse)
    lea   rdi, [rsp + 4416]
    mov   eax, [rbx + BCX_OUT + 0]
    bswap eax
    mov   [rdi+0], eax
    mov   eax, [rbx + BCX_OUT + 4]
    bswap eax
    mov   [rdi+4], eax
    mov   eax, [rbx + BCX_OUT + 8]
    bswap eax
    mov   [rdi+8], eax
    mov   eax, [rbx + BCX_OUT + 12]
    bswap eax
    mov   [rdi+12], eax
    mov   eax, [rbx + BCX_OUT + 16]
    bswap eax
    mov   [rdi+16], eax
    mov   eax, [rbx + BCX_OUT + 20]
    bswap eax
    mov   [rdi+20], eax
    mov   rsi, 23
    lea   rdx, [r10+29]
    call  bc_b64enc
    # constant-time-ish compare out[0..59] vs hash[0..59]
    lea   r10, [rsp + 4352]
    xor   eax, eax                 # accumulator
    xor   ecx, ecx
.Lv_cmp:
    mov   dl, [r10 + rcx]
    xor   dl, [r14 + rcx]
    or    al, dl
    inc   ecx
    cmp   ecx, 60
    jb    .Lv_cmp
    test  al, al
    jnz   .Lv_no
    mov   eax, 1
    jmp   .Lv_ret
.Lv_no:
    xor   eax, eax
.Lv_ret:
    add   rsp, 4480
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# ================================================================ batch helpers
# -------- bc_out31(dst=rdi, ctx=rsi): write the 31-char hash portion from ctx.OUT. Clobbers caller-saved.
bc_out31:
    push  rbx
    sub   rsp, 32
    mov   eax, [rsi + BCX_OUT + 0]
    bswap eax
    mov   [rsp + 0], eax
    mov   eax, [rsi + BCX_OUT + 4]
    bswap eax
    mov   [rsp + 4], eax
    mov   eax, [rsi + BCX_OUT + 8]
    bswap eax
    mov   [rsp + 8], eax
    mov   eax, [rsi + BCX_OUT + 12]
    bswap eax
    mov   [rsp + 12], eax
    mov   eax, [rsi + BCX_OUT + 16]
    bswap eax
    mov   [rsp + 16], eax
    mov   eax, [rsi + BCX_OUT + 20]
    bswap eax
    mov   [rsp + 20], eax
    mov   rbx, rdi
    mov   rdi, rsp
    mov   esi, 23
    mov   rdx, rbx
    call  bc_b64enc
    add   rsp, 32
    pop   rbx
    ret

# -------- bc_emit_hash(out=rdi, ctx=rsi, cost=edx, salt16=rcx): emit a $2b$ hash string (60 chars).
bc_emit_hash:
    push  rbx
    push  r12
    push  r13
    push  r14
    mov   r12, rdi                 # out
    mov   r13, rsi                 # ctx
    mov   r14, rcx                 # salt16
    mov   byte ptr [r12+0], '$'
    mov   byte ptr [r12+1], '2'
    mov   byte ptr [r12+2], 'b'
    mov   byte ptr [r12+3], '$'
    mov   byte ptr [r12+6], '$'
    mov   eax, edx                 # cost
    mov   cl, 10
    div   cl                       # al=cost/10 ah=cost%10
    add   al, '0'
    mov   [r12+4], al
    mov   al, ah
    add   al, '0'
    mov   [r12+5], al
    mov   rdi, r14
    mov   esi, 16
    lea   rdx, [r12+7]
    call  bc_b64enc
    lea   rdi, [r12+29]
    mov   rsi, r13
    call  bc_out31
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret

# -------- bc_build(out=rdi, ctx=rsi, setting=rdx): computed 60-char hash reusing the setting's prefix/salt.
bc_build:
    push  rbx
    push  r12
    push  r13
    mov   r12, rdi                 # out
    mov   r13, rsi                 # ctx
    mov   rax, [rdx+0]
    mov   [r12+0], rax
    mov   rax, [rdx+8]
    mov   [r12+8], rax
    mov   rax, [rdx+16]
    mov   [r12+16], rax
    mov   eax, [rdx+24]
    mov   [r12+24], eax
    movzx eax, byte ptr [rdx+28]
    sub   eax, 0x20
    lea   rcx, [rip + bf_atoi64]
    movzx eax, byte ptr [rcx + rax]
    and   eax, 0x30
    lea   rcx, [rip + bf_itoa64]
    movzx eax, byte ptr [rcx + rax]
    mov   [r12+28], al
    lea   rdi, [r12+29]
    mov   rsi, r13
    call  bc_out31
    pop   r13
    pop   r12
    pop   rbx
    ret

# -------- bc_prep(ctx=rdi, pw=rsi, pwlen=rdx, flags=ecx, salt16=r8): init S, salt words, set key for one lane.
bc_prep:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    mov   rbx, rdi                 # ctx
    mov   r12, rsi                 # pw
    mov   r13, rdx                 # pwlen
    mov   ebp, ecx                 # flags
    mov   r14, r8                  # salt16
    lea   rsi, [rip + bf_init_S]
    mov   rdi, rbx
    mov   ecx, 512
    rep   movsq
    mov   eax, [r14+0]
    bswap eax
    mov   [rbx + BCX_SALT + 0], eax
    mov   eax, [r14+4]
    bswap eax
    mov   [rbx + BCX_SALT + 4], eax
    mov   eax, [r14+8]
    bswap eax
    mov   [rbx + BCX_SALT + 8], eax
    mov   eax, [r14+12]
    bswap eax
    mov   [rbx + BCX_SALT + 12], eax
    cmp   r13, 72
    jbe   1f
    mov   r13d, 72
1:
    mov   rdi, r12
    mov   rsi, r13
    mov   edx, ebp
    call  bc_setkey
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# -------- bc_parse(hash=rdi, hashlen=rsi, saltbuf=rdx) -> eax = cost (0 if malformed), r8d = subtype flags.
#          Decodes the 16-byte salt into saltbuf. Preserves r12,r13,r14,r15.
bc_parse:
    push  rbx
    push  r12
    push  r13
    mov   r12, rdi                 # hash
    mov   r13, rdx                 # saltbuf
    cmp   rsi, 60
    jne   .Lpar_bad
    cmp   byte ptr [r12+0], '$'
    jne   .Lpar_bad
    cmp   byte ptr [r12+1], '2'
    jne   .Lpar_bad
    movzx eax, byte ptr [r12+2]
    mov   r8d, BCF_2A
    cmp   al, 'a'
    je    .Lpar_sub
    mov   r8d, BCF_2B
    cmp   al, 'b'
    je    .Lpar_sub
    cmp   al, 'y'
    je    .Lpar_sub
    jmp   .Lpar_bad
.Lpar_sub:
    cmp   byte ptr [r12+3], '$'
    jne   .Lpar_bad
    movzx eax, byte ptr [r12+4]
    sub   eax, '0'
    cmp   eax, 3
    ja    .Lpar_bad
    movzx ecx, byte ptr [r12+5]
    sub   ecx, '0'
    cmp   ecx, 9
    ja    .Lpar_bad
    lea   eax, [eax + eax*4]
    lea   eax, [ecx + eax*2]       # cost
    cmp   eax, 4
    jb    .Lpar_bad
    cmp   eax, 31
    ja    .Lpar_bad
    cmp   byte ptr [r12+6], '$'
    jne   .Lpar_bad
    mov   ebx, eax                 # save cost
    push  r8                       # save flags across decode
    lea   rdi, [r12+7]
    mov   esi, 16
    mov   rdx, r13
    call  bc_b64dec
    pop   r8
    test  rax, rax
    js    .Lpar_bad2
    mov   eax, ebx                 # cost
    jmp   .Lpar_done
.Lpar_bad:
    xor   r8d, r8d
.Lpar_bad2:
    xor   eax, eax
.Lpar_done:
    pop   r13
    pop   r12
    pop   rbx
    ret

# ======================================================================= 5-lane interleaved engine
# Lanes: L0..4 = r8d,r9d,r10d,r11d,edi ; R0..4 = r12d,r13d,r14d,r15d,ebp ; ctx0 = rbx, stride BCX_SIZE.

# -------- bf_enc5: 5 independent Blowfish block encrypts, interleaved per round.
# Clobbers rax,rdx,rsi. Preserves rbx,rcx and uses r8-r15,rdi,rbp as the lane state.
bf_enc5:
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_P]
    xor   edi, [rbx + 4*BCX_SIZE + BCX_P]
    RND   r12d, r8d, 0*BCX_SIZE, 1
    RND   r13d, r9d, 1*BCX_SIZE, 1
    RND   r14d, r10d, 2*BCX_SIZE, 1
    RND   r15d, r11d, 3*BCX_SIZE, 1
    RND   ebp, edi, 4*BCX_SIZE, 1
    RND   r8d, r12d, 0*BCX_SIZE, 2
    RND   r9d, r13d, 1*BCX_SIZE, 2
    RND   r10d, r14d, 2*BCX_SIZE, 2
    RND   r11d, r15d, 3*BCX_SIZE, 2
    RND   edi, ebp, 4*BCX_SIZE, 2
    RND   r12d, r8d, 0*BCX_SIZE, 3
    RND   r13d, r9d, 1*BCX_SIZE, 3
    RND   r14d, r10d, 2*BCX_SIZE, 3
    RND   r15d, r11d, 3*BCX_SIZE, 3
    RND   ebp, edi, 4*BCX_SIZE, 3
    RND   r8d, r12d, 0*BCX_SIZE, 4
    RND   r9d, r13d, 1*BCX_SIZE, 4
    RND   r10d, r14d, 2*BCX_SIZE, 4
    RND   r11d, r15d, 3*BCX_SIZE, 4
    RND   edi, ebp, 4*BCX_SIZE, 4
    RND   r12d, r8d, 0*BCX_SIZE, 5
    RND   r13d, r9d, 1*BCX_SIZE, 5
    RND   r14d, r10d, 2*BCX_SIZE, 5
    RND   r15d, r11d, 3*BCX_SIZE, 5
    RND   ebp, edi, 4*BCX_SIZE, 5
    RND   r8d, r12d, 0*BCX_SIZE, 6
    RND   r9d, r13d, 1*BCX_SIZE, 6
    RND   r10d, r14d, 2*BCX_SIZE, 6
    RND   r11d, r15d, 3*BCX_SIZE, 6
    RND   edi, ebp, 4*BCX_SIZE, 6
    RND   r12d, r8d, 0*BCX_SIZE, 7
    RND   r13d, r9d, 1*BCX_SIZE, 7
    RND   r14d, r10d, 2*BCX_SIZE, 7
    RND   r15d, r11d, 3*BCX_SIZE, 7
    RND   ebp, edi, 4*BCX_SIZE, 7
    RND   r8d, r12d, 0*BCX_SIZE, 8
    RND   r9d, r13d, 1*BCX_SIZE, 8
    RND   r10d, r14d, 2*BCX_SIZE, 8
    RND   r11d, r15d, 3*BCX_SIZE, 8
    RND   edi, ebp, 4*BCX_SIZE, 8
    RND   r12d, r8d, 0*BCX_SIZE, 9
    RND   r13d, r9d, 1*BCX_SIZE, 9
    RND   r14d, r10d, 2*BCX_SIZE, 9
    RND   r15d, r11d, 3*BCX_SIZE, 9
    RND   ebp, edi, 4*BCX_SIZE, 9
    RND   r8d, r12d, 0*BCX_SIZE, 10
    RND   r9d, r13d, 1*BCX_SIZE, 10
    RND   r10d, r14d, 2*BCX_SIZE, 10
    RND   r11d, r15d, 3*BCX_SIZE, 10
    RND   edi, ebp, 4*BCX_SIZE, 10
    RND   r12d, r8d, 0*BCX_SIZE, 11
    RND   r13d, r9d, 1*BCX_SIZE, 11
    RND   r14d, r10d, 2*BCX_SIZE, 11
    RND   r15d, r11d, 3*BCX_SIZE, 11
    RND   ebp, edi, 4*BCX_SIZE, 11
    RND   r8d, r12d, 0*BCX_SIZE, 12
    RND   r9d, r13d, 1*BCX_SIZE, 12
    RND   r10d, r14d, 2*BCX_SIZE, 12
    RND   r11d, r15d, 3*BCX_SIZE, 12
    RND   edi, ebp, 4*BCX_SIZE, 12
    RND   r12d, r8d, 0*BCX_SIZE, 13
    RND   r13d, r9d, 1*BCX_SIZE, 13
    RND   r14d, r10d, 2*BCX_SIZE, 13
    RND   r15d, r11d, 3*BCX_SIZE, 13
    RND   ebp, edi, 4*BCX_SIZE, 13
    RND   r8d, r12d, 0*BCX_SIZE, 14
    RND   r9d, r13d, 1*BCX_SIZE, 14
    RND   r10d, r14d, 2*BCX_SIZE, 14
    RND   r11d, r15d, 3*BCX_SIZE, 14
    RND   edi, ebp, 4*BCX_SIZE, 14
    RND   r12d, r8d, 0*BCX_SIZE, 15
    RND   r13d, r9d, 1*BCX_SIZE, 15
    RND   r14d, r10d, 2*BCX_SIZE, 15
    RND   r15d, r11d, 3*BCX_SIZE, 15
    RND   ebp, edi, 4*BCX_SIZE, 15
    RND   r8d, r12d, 0*BCX_SIZE, 16
    RND   r9d, r13d, 1*BCX_SIZE, 16
    RND   r10d, r14d, 2*BCX_SIZE, 16
    RND   r11d, r15d, 3*BCX_SIZE, 16
    RND   edi, ebp, 4*BCX_SIZE, 16
    mov   eax, r8d
    mov   r8d, r12d
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_P + 17*4]
    mov   r12d, eax
    mov   eax, r9d
    mov   r9d, r13d
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_P + 17*4]
    mov   r13d, eax
    mov   eax, r10d
    mov   r10d, r14d
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_P + 17*4]
    mov   r14d, eax
    mov   eax, r11d
    mov   r11d, r15d
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_P + 17*4]
    mov   r15d, eax
    mov   eax, edi
    mov   edi, ebp
    xor   edi, [rbx + 4*BCX_SIZE + BCX_P + 17*4]
    mov   ebp, eax
    ret

# -------- bf_expand_plain5: 5-lane key schedule, zero salt. Clobbers rax,rcx,rdx,rsi.
bf_expand_plain5:
    xor   ecx, ecx
.Lpp5:
    call  bf_enc5
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx + 4], r15d
    mov   [rbx + 4*BCX_SIZE + BCX_P + rcx], edi
    mov   [rbx + 4*BCX_SIZE + BCX_P + rcx + 4], ebp
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpp5
    xor   ecx, ecx
.Lps5:
    call  bf_enc5
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + rcx + 4], r15d
    mov   [rbx + 4*BCX_SIZE + rcx], edi
    mov   [rbx + 4*BCX_SIZE + rcx + 4], ebp
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lps5
    ret

# -------- bf_expand_salted5: 5-lane initial salted expansion. L/R = 0 at entry. Clobbers rax,rcx,rdx,rsi.
bf_expand_salted5:
    xor   ecx, ecx
.Lpps5:
    mov   eax, ecx
    and   eax, 8                   # P-phase salt word byte-offset (0 or 8)
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rbx + 3*BCX_SIZE + BCX_SALT + rax + 4]
    xor   edi, [rbx + 4*BCX_SIZE + BCX_SALT + rax]
    xor   ebp, [rbx + 4*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc5
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_P + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_P + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_P + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_P + rcx + 4], r15d
    mov   [rbx + 4*BCX_SIZE + BCX_P + rcx], edi
    mov   [rbx + 4*BCX_SIZE + BCX_P + rcx + 4], ebp
    add   ecx, 8
    cmp   ecx, 72
    jb    .Lpps5
    xor   ecx, ecx
.Lpss5:
    mov   eax, ecx
    and   eax, 8
    xor   eax, 8                   # S-phase salt word byte-offset (8 or 0)
    xor   r8d, [rbx + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rbx + 0*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r9d, [rbx + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rbx + 1*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r10d, [rbx + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rbx + 2*BCX_SIZE + BCX_SALT + rax + 4]
    xor   r11d, [rbx + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rbx + 3*BCX_SIZE + BCX_SALT + rax + 4]
    xor   edi, [rbx + 4*BCX_SIZE + BCX_SALT + rax]
    xor   ebp, [rbx + 4*BCX_SIZE + BCX_SALT + rax + 4]
    call  bf_enc5
    mov   [rbx + 0*BCX_SIZE + rcx], r8d
    mov   [rbx + 0*BCX_SIZE + rcx + 4], r12d
    mov   [rbx + 1*BCX_SIZE + rcx], r9d
    mov   [rbx + 1*BCX_SIZE + rcx + 4], r13d
    mov   [rbx + 2*BCX_SIZE + rcx], r10d
    mov   [rbx + 2*BCX_SIZE + rcx + 4], r14d
    mov   [rbx + 3*BCX_SIZE + rcx], r11d
    mov   [rbx + 3*BCX_SIZE + rcx + 4], r15d
    mov   [rbx + 4*BCX_SIZE + rcx], edi
    mov   [rbx + 4*BCX_SIZE + rcx + 4], ebp
    add   ecx, 8
    cmp   ecx, 4096
    jb    .Lpss5
    ret

# -------- bc_crypt5: full Eksblowfish on 5 contiguous ctxs (rbx=ctx0, edi=cost). Preserves callee-saved.
# [rsp] = remaining count, [rsp+8] = output word index (edi and ebp hold lane state).
bc_crypt5:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 16
    mov   ecx, edi
    mov   eax, 1
    shl   eax, cl
    mov   [rsp], eax               # remaining = 2^cost
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    call  bf_expand_salted5
.Lmain5:
    xor   ecx, ecx
.Lxek5:
    mov   eax, [rbx + 0*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 1*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 2*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 3*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 3*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rbx + 4*BCX_SIZE + BCX_EK + rcx]
    xor   [rbx + 4*BCX_SIZE + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek5
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    call  bf_expand_plain5
    xor   ecx, ecx
.Lxsalt5:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rbx + 0*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 0*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 1*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 1*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 2*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 2*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 3*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 3*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rbx + 4*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rbx + 4*BCX_SIZE + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt5
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    call  bf_expand_plain5
    dec   dword ptr [rsp]
    jnz   .Lmain5
    mov   dword ptr [rsp + 8], 0
.Lfin5:
    mov   ecx, [rsp + 8]
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + rcx*4]
    mov   r12d, [rax + rcx*4 + 4]
    mov   r9d, [rax + rcx*4]
    mov   r13d, [rax + rcx*4 + 4]
    mov   r10d, [rax + rcx*4]
    mov   r14d, [rax + rcx*4 + 4]
    mov   r11d, [rax + rcx*4]
    mov   r15d, [rax + rcx*4 + 4]
    mov   edi, [rax + rcx*4]
    mov   ebp, [rax + rcx*4 + 4]
    mov   ecx, 64
.Lfinb5:
    call  bf_enc5
    dec   ecx
    jnz   .Lfinb5
    mov   ecx, [rsp + 8]
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rcx*4], r8d
    mov   [rbx + 0*BCX_SIZE + BCX_OUT + rcx*4 + 4], r12d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rcx*4], r9d
    mov   [rbx + 1*BCX_SIZE + BCX_OUT + rcx*4 + 4], r13d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rcx*4], r10d
    mov   [rbx + 2*BCX_SIZE + BCX_OUT + rcx*4 + 4], r14d
    mov   [rbx + 3*BCX_SIZE + BCX_OUT + rcx*4], r11d
    mov   [rbx + 3*BCX_SIZE + BCX_OUT + rcx*4 + 4], r15d
    mov   [rbx + 4*BCX_SIZE + BCX_OUT + rcx*4], edi
    mov   [rbx + 4*BCX_SIZE + BCX_OUT + rcx*4 + 4], ebp
    add   ecx, 2
    mov   [rsp + 8], ecx
    cmp   ecx, 6
    jb    .Lfin5
    add   rsp, 16
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# -------- bc_crypt1w: bc_crypt1 with the batch-engine interface (rbx=ctx, edi=cost).
bc_crypt1w:
    push  r13
    mov   r13d, edi
    call  bc_crypt1
    pop   r13
    ret

# ======================================================================= 6-lane interleaved engine
# The 6 ctxs are copied into bc_crypt6's frame and addressed off rsp, so rbx, rsi and rdi are free for lane state:
# L0..5 = r8d,r9d,r10d,r11d,ebx,edi ; R0..5 = r12d,r13d,r14d,r15d,ebp,esi. Scratch eax, ecx, edx; loop counters
# live in the frame. Offsets assume the call depth: body 0, bf_expand_*6 / bf_final6 1, bf_enc6 2.

# -------- bf_enc6: 6 Blowfish block encrypts interleaved per round (called at depth 2). Clobbers eax, ecx, edx.
bf_enc6:
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P]
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P]
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P]
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P]
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P]
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 4]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 4]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 4]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 4]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 4]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 4]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 8]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 8]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 8]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 8]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 8]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 8]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 12]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 12]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 12]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 12]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 12]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 12]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 16]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 16]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 16]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 16]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 16]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 16]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 20]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 20]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 20]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 20]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 20]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 20]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 24]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 24]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 24]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 24]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 24]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 24]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 28]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 28]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 28]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 28]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 28]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 28]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 32]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 32]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 32]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 32]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 32]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 32]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 36]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 36]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 36]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 36]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 36]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 36]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 40]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 40]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 40]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 40]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 40]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 40]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 44]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 44]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 44]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 44]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 44]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 44]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 48]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 48]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 48]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 48]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 48]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 48]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 52]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 52]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 52]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 52]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 52]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 52]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 56]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 56]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 56]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 56]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 56]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 56]
    mov   edx, r8d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r8b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r12d, edx
    xor   r12d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 60]
    mov   edx, r9d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r9b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r13d, edx
    xor   r13d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 60]
    mov   edx, r10d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r10b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r14d, edx
    xor   r14d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 60]
    mov   edx, r11d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r11b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r15d, edx
    xor   r15d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 60]
    mov   edx, ebx
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebp, edx
    xor   ebp, [rsp + 80 + 4*BCX_SIZE + BCX_P + 60]
    mov   edx, edi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, dil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   esi, edx
    xor   esi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 60]
    mov   edx, r12d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 0*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 0*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 0*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r12b
    add   edx, [rsp + 80 + 0*BCX_SIZE + 3072 + rcx*4]
    xor   r8d, edx
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 64]
    mov   edx, r13d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 1*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 1*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 1*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r13b
    add   edx, [rsp + 80 + 1*BCX_SIZE + 3072 + rcx*4]
    xor   r9d, edx
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 64]
    mov   edx, r14d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 2*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 2*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 2*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r14b
    add   edx, [rsp + 80 + 2*BCX_SIZE + 3072 + rcx*4]
    xor   r10d, edx
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 64]
    mov   edx, r15d
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 3*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 3*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 3*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, r15b
    add   edx, [rsp + 80 + 3*BCX_SIZE + 3072 + rcx*4]
    xor   r11d, edx
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 64]
    mov   edx, ebp
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 4*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 4*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 4*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, bpl
    add   edx, [rsp + 80 + 4*BCX_SIZE + 3072 + rcx*4]
    xor   ebx, edx
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 64]
    mov   edx, esi
    movzx ecx, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rsp + 80 + 5*BCX_SIZE + 0 + rdx*4]
    add   edx, [rsp + 80 + 5*BCX_SIZE + 1024 + rax*4]
    xor   edx, [rsp + 80 + 5*BCX_SIZE + 2048 + rcx*4]
    movzx ecx, sil
    add   edx, [rsp + 80 + 5*BCX_SIZE + 3072 + rcx*4]
    xor   edi, edx
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 64]
    mov   eax, r8d
    mov   r8d, r12d
    xor   r8d, [rsp + 80 + 0*BCX_SIZE + BCX_P + 17*4]
    mov   r12d, eax
    mov   eax, r9d
    mov   r9d, r13d
    xor   r9d, [rsp + 80 + 1*BCX_SIZE + BCX_P + 17*4]
    mov   r13d, eax
    mov   eax, r10d
    mov   r10d, r14d
    xor   r10d, [rsp + 80 + 2*BCX_SIZE + BCX_P + 17*4]
    mov   r14d, eax
    mov   eax, r11d
    mov   r11d, r15d
    xor   r11d, [rsp + 80 + 3*BCX_SIZE + BCX_P + 17*4]
    mov   r15d, eax
    mov   eax, ebx
    mov   ebx, ebp
    xor   ebx, [rsp + 80 + 4*BCX_SIZE + BCX_P + 17*4]
    mov   ebp, eax
    mov   eax, edi
    mov   edi, esi
    xor   edi, [rsp + 80 + 5*BCX_SIZE + BCX_P + 17*4]
    mov   esi, eax
    ret

# -------- bf_expand_plain6: 6-lane key schedule, zero salt (depth 1).
bf_expand_plain6:
    mov   dword ptr [rsp + 16], 0
.Lpp6:
    call  bf_enc6
    mov   eax, [rsp + 16]
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_P + rax], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_P + 4 + rax], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_P + rax], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_P + 4 + rax], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_P + rax], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_P + 4 + rax], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_P + rax], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_P + 4 + rax], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_P + rax], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_P + 4 + rax], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_P + rax], edi
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_P + 4 + rax], esi
    add   eax, 8
    mov   [rsp + 16], eax
    cmp   eax, 72
    jb    .Lpp6
    mov   dword ptr [rsp + 16], 0
.Lps6:
    call  bf_enc6
    mov   eax, [rsp + 16]
    mov   [rsp + 72 + 0*BCX_SIZE + 0 + rax], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + 0 + 4 + rax], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + 0 + rax], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + 0 + 4 + rax], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + 0 + rax], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + 0 + 4 + rax], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + 0 + rax], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + 0 + 4 + rax], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + 0 + rax], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + 0 + 4 + rax], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + 0 + rax], edi
    mov   [rsp + 72 + 5*BCX_SIZE + 0 + 4 + rax], esi
    add   eax, 8
    mov   [rsp + 16], eax
    cmp   eax, 4096
    jb    .Lps6
    ret

# -------- bf_expand_salted6: 6-lane initial salted expansion, L/R = 0 at entry (depth 1).
bf_expand_salted6:
    mov   dword ptr [rsp + 16], 0
.Lpps6:
    mov   eax, [rsp + 16]
    and   eax, 8
    xor   r8d, [rsp + 72 + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rsp + 72 + 0*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r9d, [rsp + 72 + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rsp + 72 + 1*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r10d, [rsp + 72 + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rsp + 72 + 2*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r11d, [rsp + 72 + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rsp + 72 + 3*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   ebx, [rsp + 72 + 4*BCX_SIZE + BCX_SALT + rax]
    xor   ebp, [rsp + 72 + 4*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   edi, [rsp + 72 + 5*BCX_SIZE + BCX_SALT + rax]
    xor   esi, [rsp + 72 + 5*BCX_SIZE + BCX_SALT + 4 + rax]
    call  bf_enc6
    mov   eax, [rsp + 16]
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_P + rax], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_P + 4 + rax], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_P + rax], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_P + 4 + rax], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_P + rax], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_P + 4 + rax], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_P + rax], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_P + 4 + rax], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_P + rax], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_P + 4 + rax], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_P + rax], edi
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_P + 4 + rax], esi
    add   eax, 8
    mov   [rsp + 16], eax
    cmp   eax, 72
    jb    .Lpps6
    mov   dword ptr [rsp + 16], 0
.Lpss6:
    mov   eax, [rsp + 16]
    and   eax, 8
    xor   eax, 8
    xor   r8d, [rsp + 72 + 0*BCX_SIZE + BCX_SALT + rax]
    xor   r12d, [rsp + 72 + 0*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r9d, [rsp + 72 + 1*BCX_SIZE + BCX_SALT + rax]
    xor   r13d, [rsp + 72 + 1*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r10d, [rsp + 72 + 2*BCX_SIZE + BCX_SALT + rax]
    xor   r14d, [rsp + 72 + 2*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   r11d, [rsp + 72 + 3*BCX_SIZE + BCX_SALT + rax]
    xor   r15d, [rsp + 72 + 3*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   ebx, [rsp + 72 + 4*BCX_SIZE + BCX_SALT + rax]
    xor   ebp, [rsp + 72 + 4*BCX_SIZE + BCX_SALT + 4 + rax]
    xor   edi, [rsp + 72 + 5*BCX_SIZE + BCX_SALT + rax]
    xor   esi, [rsp + 72 + 5*BCX_SIZE + BCX_SALT + 4 + rax]
    call  bf_enc6
    mov   eax, [rsp + 16]
    mov   [rsp + 72 + 0*BCX_SIZE + 0 + rax], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + 0 + 4 + rax], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + 0 + rax], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + 0 + 4 + rax], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + 0 + rax], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + 0 + 4 + rax], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + 0 + rax], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + 0 + 4 + rax], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + 0 + rax], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + 0 + 4 + rax], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + 0 + rax], edi
    mov   [rsp + 72 + 5*BCX_SIZE + 0 + 4 + rax], esi
    add   eax, 8
    mov   [rsp + 16], eax
    cmp   eax, 4096
    jb    .Lpss6
    ret

# -------- bf_final6: encrypt the magic text 64 times per word pair into ctx.OUT (depth 1).
bf_final6:
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + 0]
    mov   r12d, [rax + 4]
    mov   r9d, [rax + 0]
    mov   r13d, [rax + 4]
    mov   r10d, [rax + 0]
    mov   r14d, [rax + 4]
    mov   r11d, [rax + 0]
    mov   r15d, [rax + 4]
    mov   ebx, [rax + 0]
    mov   ebp, [rax + 4]
    mov   edi, [rax + 0]
    mov   esi, [rax + 4]
    mov   dword ptr [rsp + 16], 64
.Lfin6_0:
    call  bf_enc6
    dec   dword ptr [rsp + 16]
    jnz   .Lfin6_0
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 0], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 4], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 0], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 4], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 0], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 4], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 0], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 4], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 0], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 4], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 0], edi
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 4], esi
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + 8]
    mov   r12d, [rax + 12]
    mov   r9d, [rax + 8]
    mov   r13d, [rax + 12]
    mov   r10d, [rax + 8]
    mov   r14d, [rax + 12]
    mov   r11d, [rax + 8]
    mov   r15d, [rax + 12]
    mov   ebx, [rax + 8]
    mov   ebp, [rax + 12]
    mov   edi, [rax + 8]
    mov   esi, [rax + 12]
    mov   dword ptr [rsp + 16], 64
.Lfin6_2:
    call  bf_enc6
    dec   dword ptr [rsp + 16]
    jnz   .Lfin6_2
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 8], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 12], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 8], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 12], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 8], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 12], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 8], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 12], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 8], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 12], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 8], edi
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 12], esi
    lea   rax, [rip + bf_magic]
    mov   r8d, [rax + 16]
    mov   r12d, [rax + 20]
    mov   r9d, [rax + 16]
    mov   r13d, [rax + 20]
    mov   r10d, [rax + 16]
    mov   r14d, [rax + 20]
    mov   r11d, [rax + 16]
    mov   r15d, [rax + 20]
    mov   ebx, [rax + 16]
    mov   ebp, [rax + 20]
    mov   edi, [rax + 16]
    mov   esi, [rax + 20]
    mov   dword ptr [rsp + 16], 64
.Lfin6_4:
    call  bf_enc6
    dec   dword ptr [rsp + 16]
    jnz   .Lfin6_4
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 16], r8d
    mov   [rsp + 72 + 0*BCX_SIZE + BCX_OUT + 20], r12d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 16], r9d
    mov   [rsp + 72 + 1*BCX_SIZE + BCX_OUT + 20], r13d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 16], r10d
    mov   [rsp + 72 + 2*BCX_SIZE + BCX_OUT + 20], r14d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 16], r11d
    mov   [rsp + 72 + 3*BCX_SIZE + BCX_OUT + 20], r15d
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 16], ebx
    mov   [rsp + 72 + 4*BCX_SIZE + BCX_OUT + 20], ebp
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 16], edi
    mov   [rsp + 72 + 5*BCX_SIZE + BCX_OUT + 20], esi
    ret

# -------- bc_crypt6: full Eksblowfish on 6 contiguous ctxs (rbx=ctx0, edi=cost). Preserves callee-saved.
# Works on a copy of the ctxs in its frame and writes the 6 OUT words per lane back to rbx.
# Frame: [rsp] remaining count, [rsp+8] loop counter, [rsp+16] ctx0, [rsp+24] cost, ctxs at [rsp+64].
bc_crypt6:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 64 + 6*BCX_SIZE
    mov   [rsp + 16], rbx
    mov   ecx, edi
    mov   eax, 1
    shl   eax, cl
    mov   [rsp + 0], eax           # remaining = 2^cost
    mov   rsi, rbx
    lea   rdi, [rsp + 64]
    mov   ecx, 6*BCX_SIZE/8
    rep   movsq
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   ebx, ebx
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    xor   esi, esi
    call  bf_expand_salted6
.Lmain6:
    xor   ecx, ecx
.Lxek6:
    mov   eax, [rsp + 64 + 0*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 0*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rsp + 64 + 1*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 1*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rsp + 64 + 2*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 2*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rsp + 64 + 3*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 3*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rsp + 64 + 4*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 4*BCX_SIZE + BCX_P + rcx], eax
    mov   eax, [rsp + 64 + 5*BCX_SIZE + BCX_EK + rcx]
    xor   [rsp + 64 + 5*BCX_SIZE + BCX_P + rcx], eax
    add   ecx, 4
    cmp   ecx, 72
    jb    .Lxek6
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   ebx, ebx
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    xor   esi, esi
    call  bf_expand_plain6
    xor   ecx, ecx
.Lxsalt6:
    mov   eax, ecx
    and   eax, 3
    mov   edx, [rsp + 64 + 0*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 0*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rsp + 64 + 1*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 1*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rsp + 64 + 2*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 2*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rsp + 64 + 3*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 3*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rsp + 64 + 4*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 4*BCX_SIZE + BCX_P + rcx*4], edx
    mov   edx, [rsp + 64 + 5*BCX_SIZE + BCX_SALT + rax*4]
    xor   [rsp + 64 + 5*BCX_SIZE + BCX_P + rcx*4], edx
    inc   ecx
    cmp   ecx, 18
    jb    .Lxsalt6
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   ebx, ebx
    xor   edi, edi
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebp, ebp
    xor   esi, esi
    call  bf_expand_plain6
    dec   dword ptr [rsp + 0]
    jnz   .Lmain6
    call  bf_final6
    mov   rdx, [rsp + 16]
    mov   rax, [rsp + 64 + 0*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 0*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 0*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 0*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 0*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 0*BCX_SIZE + BCX_OUT + 16], rax
    mov   rax, [rsp + 64 + 1*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 1*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 1*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 1*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 1*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 1*BCX_SIZE + BCX_OUT + 16], rax
    mov   rax, [rsp + 64 + 2*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 2*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 2*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 2*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 2*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 2*BCX_SIZE + BCX_OUT + 16], rax
    mov   rax, [rsp + 64 + 3*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 3*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 3*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 3*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 3*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 3*BCX_SIZE + BCX_OUT + 16], rax
    mov   rax, [rsp + 64 + 4*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 4*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 4*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 4*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 4*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 4*BCX_SIZE + BCX_OUT + 16], rax
    mov   rax, [rsp + 64 + 5*BCX_SIZE + BCX_OUT + 0]
    mov   [rdx + 5*BCX_SIZE + BCX_OUT + 0], rax
    mov   rax, [rsp + 64 + 5*BCX_SIZE + BCX_OUT + 8]
    mov   [rdx + 5*BCX_SIZE + BCX_OUT + 8], rax
    mov   rax, [rsp + 64 + 5*BCX_SIZE + BCX_OUT + 16]
    mov   [rdx + 5*BCX_SIZE + BCX_OUT + 16], rax
    add   rsp, 64 + 6*BCX_SIZE
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# ---------------------------------------------------------------- batch dispatch
# group-size table: for a run of R equal-cost jobs, bc_grp[R] = size of the first
# group (fastest split into 6/5/4/3/2/1-lane engine calls; 7 = 4+3, 8 = 4+4).
.section .rodata
.align 8
bc_grp:
    .byte 0, 1, 2, 3, 4, 5, 6, 4, 4
.section .text

# bcrypt_hash_batch(jobs=rdi, n=rsi): hash n jobs, grouping equal-cost runs into
# 2..6-lane engine calls; unique-cost jobs fall back to bcrypt_hash.
.globl bcrypt_hash_batch
bcrypt_hash_batch:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 26176
    mov   r12, rdi                 # jobs
    mov   r13, rsi                 # n
    xor   r14d, r14d               # i
.Lhb_loop:
    cmp   r14, r13
    jae   .Lhb_end
    # &job[i] -> r15 ; cost0 -> rbp
    mov   r15, r14
    imul  r15, r15, BCJ_SIZE
    add   r15, r12
    mov   rbp, [r15 + BCJ_HASH_LEN]        # cost0
    # run length R (eax): consecutive equal-cost jobs, capped at 8
    mov   eax, 1
    mov   rcx, r14
    inc   rcx
.Lhb_run:
    cmp   eax, 8
    jae   .Lhb_rund
    cmp   rcx, r13
    jae   .Lhb_rund
    mov   rdx, rcx
    imul  rdx, rdx, BCJ_SIZE
    add   rdx, r12
    mov   rdx, [rdx + BCJ_HASH_LEN]
    cmp   rdx, rbp
    jne   .Lhb_rund
    inc   eax
    inc   rcx
    jmp   .Lhb_run
.Lhb_rund:
    lea   rdx, [rip + bc_grp]
    movzx edx, byte ptr [rdx + rax]       # g
    cmp   edx, 1
    je    .Lhb_single
    mov   [rsp + 26112], rbp               # cost
    mov   [rsp + 26120], edx             # g
    # prep g lanes
    xor   ebp, ebp                        # l
.Lhb_prep:
    mov   rax, rbp
    imul  rax, rax, 4352
    lea   rdi, [rsp + rax]                # ctx lane l
    mov   rax, rbp
    imul  rax, rax, BCJ_SIZE
    add   rax, r15                        # &job[i+l]
    mov   rsi, [rax + BCJ_PW]
    mov   rdx, [rax + BCJ_PW_LEN]
    mov   r8,  [rax + BCJ_HASH]           # salt16
    mov   ecx, BCF_2B
    call  bc_prep
    inc   ebp
    cmp   ebp, [rsp + 26120]
    jb    .Lhb_prep
    # engine
    mov   edi, [rsp + 26112]
    mov   rbx, rsp
    mov   eax, [rsp + 26120]
    cmp   eax, 2
    je    .Lhb_c2
    cmp   eax, 3
    je    .Lhb_c3
    cmp   eax, 5
    je    .Lhb_c5
    cmp   eax, 6
    je    .Lhb_c6
    call  bc_crypt4
    jmp   .Lhb_emit0
.Lhb_c2:
    call  bc_crypt2
    jmp   .Lhb_emit0
.Lhb_c6:
    call  bc_crypt6
    jmp   .Lhb_emit0
.Lhb_c5:
    call  bc_crypt5
    jmp   .Lhb_emit0
.Lhb_c3:
    call  bc_crypt3
.Lhb_emit0:
    # emit g lanes
    xor   ebp, ebp
.Lhb_emit:
    mov   rax, rbp
    imul  rax, rax, BCJ_SIZE
    add   rax, r15                        # &job[i+l]
    mov   rdi, [rax + BCJ_OUT]
    mov   rcx, [rax + BCJ_HASH]           # salt16
    mov   rax, rbp
    imul  rax, rax, 4352
    lea   rsi, [rsp + rax]                # ctx
    mov   edx, [rsp + 26112]               # cost
    call  bc_emit_hash
    inc   ebp
    cmp   ebp, [rsp + 26120]
    jb    .Lhb_emit
    movzx rax, byte ptr [rsp + 26120]
    add   r14, rax
    jmp   .Lhb_loop
.Lhb_single:
    mov   rdi, [r15 + BCJ_PW]
    mov   rsi, [r15 + BCJ_PW_LEN]
    mov   rdx, [r15 + BCJ_HASH]
    mov   ecx, [r15 + BCJ_HASH_LEN]
    mov   r8,  [r15 + BCJ_OUT]
    call  bcrypt_hash
    inc   r14
    jmp   .Lhb_loop
.Lhb_end:
    add   rsp, 26176
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# bcrypt_verify_batch(jobs=rdi, n=rsi): verify n jobs. Parse a run of valid, equal-cost
# jobs, split into 1..6-lane engine calls; invalid jobs get result 0.
.globl bcrypt_verify_batch
bcrypt_verify_batch:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 26368
    mov   r12, rdi                 # jobs
    mov   r13, rsi                 # n
    xor   r14d, r14d               # i
.Lvb_loop:
    cmp   r14, r13
    jae   .Lvb_end
    # parse job i
    mov   rbx, r14
    imul  rbx, rbx, BCJ_SIZE
    add   rbx, r12                        # &job[i]
    mov   rdi, [rbx + BCJ_HASH]
    mov   rsi, [rbx + BCJ_HASH_LEN]
    lea   rdx, [rsp + 26112]
    call  bc_parse
    test  eax, eax
    jz    .Lvb_invalid
    mov   [rsp + 26336], eax
    mov   [rsp + 26240], r8d
    mov   dword ptr [rsp + 26344], 1
.Lvb_scan:
    mov   eax, [rsp + 26344]
    cmp   eax, 8
    jae   .Lvb_scandone
    mov   rcx, r14
    add   rcx, rax                        # j = i + R
    cmp   rcx, r13
    jae   .Lvb_scandone
    imul  rcx, rcx, BCJ_SIZE
    add   rcx, r12                        # &job[j]
    mov   rdi, [rcx + BCJ_HASH]
    mov   rsi, [rcx + BCJ_HASH_LEN]
    mov   eax, [rsp + 26344]
    mov   rdx, rax
    shl   rdx, 4                          # R*16
    lea   rdx, [rsp + rdx + 26112]    # saltbuf[R]
    call  bc_parse
    test  eax, eax
    jz    .Lvb_scandone
    cmp   eax, [rsp + 26336]
    jne   .Lvb_scandone
    mov   ecx, [rsp + 26344]
    mov   [rsp + rcx*4 + 26240], r8d
    inc   ecx
    mov   [rsp + 26344], ecx
    jmp   .Lvb_scan
.Lvb_scandone:
    xor   r15d, r15d                      # off within run
.Lvb_grp:
    mov   eax, [rsp + 26344]
    sub   eax, r15d                       # remaining
    jz    .Lvb_runc
    lea   rdx, [rip + bc_grp]
    movzx edx, byte ptr [rdx + rax]       # g
    mov   [rsp + 26352], edx
    # prep g lanes
    xor   ebp, ebp
.Lvb_prep:
    mov   rax, rbp
    imul  rax, rax, 4352
    lea   rdi, [rsp + rax]                # ctx lane l
    mov   rax, r14
    add   rax, r15
    add   rax, rbp                        # i+off+l
    imul  rax, rax, BCJ_SIZE
    add   rax, r12                        # &job
    mov   rsi, [rax + BCJ_PW]
    mov   rdx, [rax + BCJ_PW_LEN]
    mov   rax, r15
    add   rax, rbp                        # off+l (salt/flags index)
    mov   r8, rax
    shl   r8, 4
    lea   r8, [rsp + r8 + 26112]      # salt16
    mov   ecx, [rsp + rax*4 + 26240] # flags
    call  bc_prep
    inc   ebp
    cmp   ebp, [rsp + 26352]
    jb    .Lvb_prep
    # engine
    mov   edi, [rsp + 26336]
    mov   rbx, rsp
    mov   eax, [rsp + 26352]
    cmp   eax, 2
    je    .Lvb_c2
    cmp   eax, 3
    je    .Lvb_c3
    cmp   eax, 5
    je    .Lvb_c5
    cmp   eax, 6
    je    .Lvb_c6
    cmp   eax, 1
    je    .Lvb_c1
    call  bc_crypt4
    jmp   .Lvb_cmp0
.Lvb_c2:
    call  bc_crypt2
    jmp   .Lvb_cmp0
.Lvb_c1:
    call  bc_crypt1w
    jmp   .Lvb_cmp0
.Lvb_c6:
    call  bc_crypt6
    jmp   .Lvb_cmp0
.Lvb_c5:
    call  bc_crypt5
    jmp   .Lvb_cmp0
.Lvb_c3:
    call  bc_crypt3
.Lvb_cmp0:
    # build + compare g lanes (one shared temp, processed sequentially)
    xor   ebp, ebp
.Lvb_cmp:
    mov   rax, rbp
    imul  rax, rax, 4352
    lea   rsi, [rsp + rax]                # ctx
    lea   rdi, [rsp + 26272]          # computed string dst
    mov   rax, r14
    add   rax, r15
    add   rax, rbp
    imul  rax, rax, BCJ_SIZE
    add   rax, r12                        # &job
    mov   rdx, [rax + BCJ_HASH]           # setting = stored hash
    call  bc_build
    # recompute &job and stored hash, compare 60 bytes
    mov   rax, r14
    add   rax, r15
    add   rax, rbp
    imul  rax, rax, BCJ_SIZE
    add   rax, r12
    mov   rdx, [rax + BCJ_HASH]
    lea   rsi, [rsp + 26272]
    xor   r9d, r9d                        # acc
    xor   ecx, ecx
.Lvb_cmpb:
    movzx r8d, byte ptr [rsi + rcx]
    movzx r10d, byte ptr [rdx + rcx]
    xor   r8d, r10d
    or    r9d, r8d
    inc   ecx
    cmp   ecx, 60
    jb    .Lvb_cmpb
    xor   edx, edx
    test  r9d, r9d
    setz  dl
    mov   [rax + BCJ_RESULT], rdx
    inc   ebp
    cmp   ebp, [rsp + 26352]
    jb    .Lvb_cmp
    add   r15d, [rsp + 26352]
    jmp   .Lvb_grp
.Lvb_runc:
    mov   eax, [rsp + 26344]
    add   r14, rax
    jmp   .Lvb_loop
.Lvb_invalid:
    mov   qword ptr [rbx + BCJ_RESULT], 0
    inc   r14
    jmp   .Lvb_loop
.Lvb_end:
    add   rsp, 26368
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

.section .note.GNU-stack,"",@progbits
