/*
 * Hand-written x86-64 assembly Blowfish engine:
 * Supports 6-lane, 4-lane, 2-lane, and 1-lane execution.
 * Keeps S-boxes pinned in L1d cache.
 */

.text
.globl bf_cost_loop_6x_asm
.type bf_cost_loop_6x_asm, @function
.globl bf_cost_loop_4x_asm
.type bf_cost_loop_4x_asm, @function
.globl bf_cost_loop_2x_asm
.type bf_cost_loop_2x_asm, @function
.globl bf_cost_loop_1x_asm
.type bf_cost_loop_1x_asm, @function

# =========================================================================
# 6-LANE INTERLEAVED ENGINE
# =========================================================================

.macro FEISTEL6 src, src_b, d
    mov   edx, \src
    shr   edx, 16
    movzx eax, dh                         # b3
    movzx edx, dl                         # b2
    mov   eax, [rcx + \d + 0 + rax*4]     # S0[b3]
    add   eax, [rcx + \d + 1024 + rdx*4]  # + S1[b2]
    mov   edx, \src
    movzx edx, dh                         # b1
    xor   eax, [rcx + \d + 2048 + rdx*4]  # ^ S2[b1]
    movzx edx, \src_b                     # b0
    add   eax, [rcx + \d + 3072 + rdx*4]  # + S3[b0]
.endm

.macro ROUND_PAIR_6X p_idx
    # Sub-round (p_idx*2 + 1): dst is R, src is L
    FEISTEL6 r8d, r8b, 0*4224
    xor   r9d, eax
    xor   r9d, [rcx + 0*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL6 r10d, r10b, 1*4224
    xor   r11d, eax
    xor   r11d, [rcx + 1*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL6 r12d, r12b, 2*4224
    xor   r13d, eax
    xor   r13d, [rcx + 2*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL6 r14d, r14b, 3*4224
    xor   r15d, eax
    xor   r15d, [rcx + 3*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL6 ebx, bl, 4*4224
    xor   ebp, eax
    xor   ebp, [rcx + 4*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL6 esi, sil, 5*4224
    xor   edi, eax
    xor   edi, [rcx + 5*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    # Sub-round (p_idx*2 + 2): dst is L, src is R
    FEISTEL6 r9d, r9b, 0*4224
    xor   r8d, eax
    xor   r8d, [rcx + 0*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL6 r11d, r11b, 1*4224
    xor   r10d, eax
    xor   r10d, [rcx + 1*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL6 r13d, r13b, 2*4224
    xor   r12d, eax
    xor   r12d, [rcx + 2*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL6 r15d, r15b, 3*4224
    xor   r14d, eax
    xor   r14d, [rcx + 3*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL6 ebp, bpl, 4*4224
    xor   ebx, eax
    xor   ebx, [rcx + 4*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL6 edi, dil, 5*4224
    xor   esi, eax
    xor   esi, [rcx + 5*4224 + 4096 + ((\p_idx)*2 + 2)*4]
.endm

.macro FINAL_SWAP6 l_reg, r_reg, d
    mov   eax, \l_reg
    mov   \l_reg, \r_reg
    xor   \l_reg, [rcx + \d + 4096 + 17*4]
    mov   \r_reg, eax
.endm

bf_enc6_inner:
    xor   r8d,  [rcx + 0*4224 + 4096 + 0]
    xor   r10d, [rcx + 1*4224 + 4096 + 0]
    xor   r12d, [rcx + 2*4224 + 4096 + 0]
    xor   r14d, [rcx + 3*4224 + 4096 + 0]
    xor   ebx,  [rcx + 4*4224 + 4096 + 0]
    xor   esi,  [rcx + 5*4224 + 4096 + 0]

    ROUND_PAIR_6X 0
    ROUND_PAIR_6X 1
    ROUND_PAIR_6X 2
    ROUND_PAIR_6X 3
    ROUND_PAIR_6X 4
    ROUND_PAIR_6X 5
    ROUND_PAIR_6X 6
    ROUND_PAIR_6X 7

    FINAL_SWAP6 r8d,  r9d,  0*4224
    FINAL_SWAP6 r10d, r11d, 1*4224
    FINAL_SWAP6 r12d, r13d, 2*4224
    FINAL_SWAP6 r14d, r15d, 3*4224
    FINAL_SWAP6 ebx,  ebp,  4*4224
    FINAL_SWAP6 esi,  edi,  5*4224
    ret

bf_expand_521_6x:
    pxor  xmm0, xmm0
.Lexp_p_6x:
    call  bf_enc6_inner
    movd  eax, xmm0
    mov   [rcx + 0*4224 + 4096 + rax], r8d
    mov   [rcx + 0*4224 + 4096 + rax + 4], r9d
    mov   [rcx + 1*4224 + 4096 + rax], r10d
    mov   [rcx + 1*4224 + 4096 + rax + 4], r11d
    mov   [rcx + 2*4224 + 4096 + rax], r12d
    mov   [rcx + 2*4224 + 4096 + rax + 4], r13d
    mov   [rcx + 3*4224 + 4096 + rax], r14d
    mov   [rcx + 3*4224 + 4096 + rax + 4], r15d
    mov   [rcx + 4*4224 + 4096 + rax], ebx
    mov   [rcx + 4*4224 + 4096 + rax + 4], ebp
    mov   [rcx + 5*4224 + 4096 + rax], esi
    mov   [rcx + 5*4224 + 4096 + rax + 4], edi
    add   eax, 8
    movd  xmm0, eax
    cmp   eax, 72
    jb    .Lexp_p_6x

    pxor  xmm0, xmm0
.Lexp_s_6x:
    call  bf_enc6_inner
    movd  eax, xmm0
    mov   [rcx + 0*4224 + rax], r8d
    mov   [rcx + 0*4224 + rax + 4], r9d
    mov   [rcx + 1*4224 + rax], r10d
    mov   [rcx + 1*4224 + rax + 4], r11d
    mov   [rcx + 2*4224 + rax], r12d
    mov   [rcx + 2*4224 + rax + 4], r13d
    mov   [rcx + 3*4224 + rax], r14d
    mov   [rcx + 3*4224 + rax + 4], r15d
    mov   [rcx + 4*4224 + rax], ebx
    mov   [rcx + 4*4224 + rax + 4], ebp
    mov   [rcx + 5*4224 + rax], esi
    mov   [rcx + 5*4224 + rax + 4], edi
    add   eax, 8
    movd  xmm0, eax
    cmp   eax, 4096
    jb    .Lexp_s_6x
    ret

bf_cost_loop_6x_asm:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 40

    mov   [rsp + 0], rdi     # [rsp + 0] = st (points to [BfState; 6])
    mov   [rsp + 8], rsi     # [rsp + 8] = key_p
    mov   [rsp + 16], rdx    # [rsp + 16] = salt_p
    mov   [rsp + 24], rcx    # [rsp + 24] = rounds counter

.Louter_cost_loop_6x:
    cmp   qword ptr [rsp + 24], 0
    jz    .Lcost_loop_done_6x

    mov   rcx, [rsp + 0]     # rcx = st
    mov   rdi, [rsp + 8]     # rdi = key_p
    xor   eax, eax
.Lxor_k6:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rcx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rcx + 1*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 2*72 + rax*4]
    xor   [rcx + 2*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 3*72 + rax*4]
    xor   [rcx + 3*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 4*72 + rax*4]
    xor   [rcx + 4*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 5*72 + rax*4]
    xor   [rcx + 5*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_k6

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebx,  ebx
    xor   ebp,  ebp
    xor   esi,  esi
    xor   edi,  edi
    call  bf_expand_521_6x

    mov   rcx, [rsp + 0]     # rcx = st
    mov   rdi, [rsp + 16]    # rdi = salt_p
    xor   eax, eax
.Lxor_s6:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rcx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rcx + 1*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 2*72 + rax*4]
    xor   [rcx + 2*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 3*72 + rax*4]
    xor   [rcx + 3*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 4*72 + rax*4]
    xor   [rcx + 4*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 5*72 + rax*4]
    xor   [rcx + 5*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_s6

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    xor   ebx,  ebx
    xor   ebp,  ebp
    xor   esi,  esi
    xor   edi,  edi
    call  bf_expand_521_6x

    dec   qword ptr [rsp + 24]
    jnz   .Louter_cost_loop_6x

.Lcost_loop_done_6x:
    add   rsp, 40
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret

# =========================================================================
# 4-LANE INTERLEAVED ENGINE
# =========================================================================

.macro FEISTEL4 src, d
    mov   edx, \src
    movzx ecx, dl
    movzx esi, dh
    shr   edx, 16
    movzx eax, dl
    shr   edx, 8
    mov   edx, [rbx + \d + 0 + rdx*4]
    add   edx, [rbx + \d + 1024 + rax*4]
    xor   edx, [rbx + \d + 2048 + rsi*4]
    add   edx, [rbx + \d + 3072 + rcx*4]
.endm

.macro ROUND_PAIR_4X p_idx
    FEISTEL4 r8d, 0*4224
    xor   r9d, edx
    xor   r9d, [rbx + 0*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r10d, 1*4224
    xor   r11d, edx
    xor   r11d, [rbx + 1*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r12d, 2*4224
    xor   r13d, edx
    xor   r13d, [rbx + 2*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r14d, 3*4224
    xor   r15d, edx
    xor   r15d, [rbx + 3*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r9d, 0*4224
    xor   r8d, edx
    xor   r8d, [rbx + 0*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL4 r11d, 1*4224
    xor   r10d, edx
    xor   r10d, [rbx + 1*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL4 r13d, 2*4224
    xor   r12d, edx
    xor   r12d, [rbx + 2*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL4 r15d, 3*4224
    xor   r14d, edx
    xor   r14d, [rbx + 3*4224 + 4096 + ((\p_idx)*2 + 2)*4]
.endm

.macro FINAL_SWAP4 l_reg, r_reg, d
    mov   eax, \l_reg
    mov   \l_reg, \r_reg
    xor   \l_reg, [rbx + \d + 4096 + 17*4]
    mov   \r_reg, eax
.endm

bf_enc4_inner:
    xor   r8d,  [rbx + 0*4224 + 4096 + 0]
    xor   r10d, [rbx + 1*4224 + 4096 + 0]
    xor   r12d, [rbx + 2*4224 + 4096 + 0]
    xor   r14d, [rbx + 3*4224 + 4096 + 0]

    ROUND_PAIR_4X 0
    ROUND_PAIR_4X 1
    ROUND_PAIR_4X 2
    ROUND_PAIR_4X 3
    ROUND_PAIR_4X 4
    ROUND_PAIR_4X 5
    ROUND_PAIR_4X 6
    ROUND_PAIR_4X 7

    FINAL_SWAP4 r8d,  r9d,  0*4224
    FINAL_SWAP4 r10d, r11d, 1*4224
    FINAL_SWAP4 r12d, r13d, 2*4224
    FINAL_SWAP4 r14d, r15d, 3*4224
    ret

bf_expand_521_4x:
    push  rbp
    xor   ebp, ebp
.Lexp_p_4x:
    call  bf_enc4_inner
    mov   [rbx + 0*4224 + 4096 + rbp], r8d
    mov   [rbx + 0*4224 + 4096 + rbp + 4], r9d
    mov   [rbx + 1*4224 + 4096 + rbp], r10d
    mov   [rbx + 1*4224 + 4096 + rbp + 4], r11d
    mov   [rbx + 2*4224 + 4096 + rbp], r12d
    mov   [rbx + 2*4224 + 4096 + rbp + 4], r13d
    mov   [rbx + 3*4224 + 4096 + rbp], r14d
    mov   [rbx + 3*4224 + 4096 + rbp + 4], r15d
    add   ebp, 8
    cmp   ebp, 72
    jb    .Lexp_p_4x

    xor   ebp, ebp
.Lexp_s_4x:
    call  bf_enc4_inner
    mov   [rbx + 0*4224 + rbp], r8d
    mov   [rbx + 0*4224 + rbp + 4], r9d
    mov   [rbx + 1*4224 + rbp], r10d
    mov   [rbx + 1*4224 + rbp + 4], r11d
    mov   [rbx + 2*4224 + rbp], r12d
    mov   [rbx + 2*4224 + rbp + 4], r13d
    mov   [rbx + 3*4224 + rbp], r14d
    mov   [rbx + 3*4224 + rbp + 4], r15d
    add   ebp, 8
    cmp   ebp, 4096
    jb    .Lexp_s_4x

    pop   rbp
    ret

bf_cost_loop_4x_asm:
    push  rbx
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 32

    mov   rbx, rdi
    mov   [rsp + 0], rsi
    mov   [rsp + 8], rdx
    mov   [rsp + 16], rcx

.Louter_cost_loop_4x:
    cmp   qword ptr [rsp + 16], 0
    jz    .Lcost_loop_done_4x

    mov   rdi, [rsp + 0]
    xor   eax, eax
.Lxor_k4:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rbx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rbx + 1*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 2*72 + rax*4]
    xor   [rbx + 2*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 3*72 + rax*4]
    xor   [rbx + 3*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_k4

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    call  bf_expand_521_4x

    mov   rdi, [rsp + 8]
    xor   eax, eax
.Lxor_s4:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rbx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rbx + 1*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 2*72 + rax*4]
    xor   [rbx + 2*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 3*72 + rax*4]
    xor   [rbx + 3*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_s4

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    call  bf_expand_521_4x

    dec   qword ptr [rsp + 16]
    jnz   .Louter_cost_loop_4x

.Lcost_loop_done_4x:
    add   rsp, 32
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret

# =========================================================================
# 2-LANE INTERLEAVED ENGINE
# =========================================================================

.macro ROUND_PAIR_2X p_idx
    FEISTEL4 r8d, 0*4224
    xor   r9d, edx
    xor   r9d, [rbx + 0*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r10d, 1*4224
    xor   r11d, edx
    xor   r11d, [rbx + 1*4224 + 4096 + ((\p_idx)*2 + 1)*4]

    FEISTEL4 r9d, 0*4224
    xor   r8d, edx
    xor   r8d, [rbx + 0*4224 + 4096 + ((\p_idx)*2 + 2)*4]

    FEISTEL4 r11d, 1*4224
    xor   r10d, edx
    xor   r10d, [rbx + 1*4224 + 4096 + ((\p_idx)*2 + 2)*4]
.endm

bf_enc2_inner:
    xor   r8d,  [rbx + 0*4224 + 4096 + 0]
    xor   r10d, [rbx + 1*4224 + 4096 + 0]

    ROUND_PAIR_2X 0
    ROUND_PAIR_2X 1
    ROUND_PAIR_2X 2
    ROUND_PAIR_2X 3
    ROUND_PAIR_2X 4
    ROUND_PAIR_2X 5
    ROUND_PAIR_2X 6
    ROUND_PAIR_2X 7

    FINAL_SWAP4 r8d,  r9d,  0*4224
    FINAL_SWAP4 r10d, r11d, 1*4224
    ret

bf_expand_521_2x:
    push  rbp
    xor   ebp, ebp
.Lexp_p_2x:
    call  bf_enc2_inner
    mov   [rbx + 0*4224 + 4096 + rbp], r8d
    mov   [rbx + 0*4224 + 4096 + rbp + 4], r9d
    mov   [rbx + 1*4224 + 4096 + rbp], r10d
    mov   [rbx + 1*4224 + 4096 + rbp + 4], r11d
    add   ebp, 8
    cmp   ebp, 72
    jb    .Lexp_p_2x

    xor   ebp, ebp
.Lexp_s_2x:
    call  bf_enc2_inner
    mov   [rbx + 0*4224 + rbp], r8d
    mov   [rbx + 0*4224 + rbp + 4], r9d
    mov   [rbx + 1*4224 + rbp], r10d
    mov   [rbx + 1*4224 + rbp + 4], r11d
    add   ebp, 8
    cmp   ebp, 4096
    jb    .Lexp_s_2x

    pop   rbp
    ret

bf_cost_loop_2x_asm:
    push  rbx
    push  r12
    push  r13
    push  r14
    push  r15
    sub   rsp, 32

    mov   rbx, rdi
    mov   [rsp + 0], rsi
    mov   [rsp + 8], rdx
    mov   [rsp + 16], rcx

.Louter_cost_loop_2x:
    cmp   qword ptr [rsp + 16], 0
    jz    .Lcost_loop_done_2x

    mov   rdi, [rsp + 0]
    xor   eax, eax
.Lxor_k2:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rbx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rbx + 1*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_k2

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    call  bf_expand_521_2x

    mov   rdi, [rsp + 8]
    xor   eax, eax
.Lxor_s2:
    mov   edx, [rdi + 0*72 + rax*4]
    xor   [rbx + 0*4224 + 4096 + rax*4], edx
    mov   edx, [rdi + 1*72 + rax*4]
    xor   [rbx + 1*4224 + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_s2

    xor   r8d,  r8d
    xor   r9d,  r9d
    xor   r10d, r10d
    xor   r11d, r11d
    call  bf_expand_521_2x

    dec   qword ptr [rsp + 16]
    jnz   .Louter_cost_loop_2x

.Lcost_loop_done_2x:
    add   rsp, 32
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret

# =========================================================================
# 1-LANE ENGINE
# =========================================================================

bf_enc1_inner:
    xor   r8d, [rbx + 4096 + 0]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 1*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 2*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 3*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 4*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 5*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 6*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 7*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 8*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 9*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 10*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 11*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 12*4]
    FEISTEL4 r9d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 13*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 14*4]
    FEISTEL4 r8d, 0
    xor   r9d, edx
    xor   r9d, [rbx + 4096 + 15*4]
    FEISTEL4 r9d, 0
    xor   r8d, edx
    xor   r8d, [rbx + 4096 + 16*4]
    FINAL_SWAP4 r8d, r9d, 0
    ret

bf_expand_521_1x:
    xor   r10d, r10d
.Lexp_p_1x:
    call  bf_enc1_inner
    mov   [rbx + 4096 + r10], r8d
    mov   [rbx + 4096 + r10 + 4], r9d
    add   r10d, 8
    cmp   r10d, 72
    jb    .Lexp_p_1x

    xor   r10d, r10d
.Lexp_s_1x:
    call  bf_enc1_inner
    mov   [rbx + r10], r8d
    mov   [rbx + r10 + 4], r9d
    add   r10d, 8
    cmp   r10d, 4096
    jb    .Lexp_s_1x
    ret

bf_cost_loop_1x_asm:
    push  rbx
    push  r12
    push  r13
    push  r14

    mov   rbx, rdi
    mov   r12, rsi
    mov   r13, rdx
    mov   r14, rcx

.Louter_cost_loop_1x:
    cmp   r14, 0
    jz    .Lcost_loop_done_1x

    mov   rdi, r12
    xor   eax, eax
.Lxor_k1:
    mov   edx, [rdi + rax*4]
    xor   [rbx + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_k1

    xor   r8d, r8d
    xor   r9d, r9d
    call  bf_expand_521_1x

    mov   rdi, r13
    xor   eax, eax
.Lxor_s1:
    mov   edx, [rdi + rax*4]
    xor   [rbx + 4096 + rax*4], edx
    inc   rax
    cmp   rax, 18
    jb    .Lxor_s1

    xor   r8d, r8d
    xor   r9d, r9d
    call  bf_expand_521_1x

    dec   r14
    jnz   .Louter_cost_loop_1x

.Lcost_loop_done_1x:
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret
