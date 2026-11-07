// bcrypt spends nearly all its time here: replace P and the S-boxes of five Blowfish states with a chain
// of 521 encryptions. Compilers run out of registers on this and spill, which costs about twice as much.
//
//   void bc_expand0_5(bf_state *states);
//
// One base register reaches every lane, and the ten halves stay in registers. Blowfish's F takes four
// table reads, and a half round is 11 instructions. Bytes 1 and 2 come out of one rorx, so the two
// load ports stay busy while the 4-wide front end of Skylake-class cores keeps up. Needs BMI2.
#if defined(__x86_64__) && defined(__linux__)
    .intel_syntax noprefix
    .text

    .set STRIDE, 4224       // sizeof(bf_state): one lane's tables never 4K-alias the next lane's
    .set SBOX, 72           // S follows P[18]
    .set WORDS, 1042        // 18 + 1024

// y ^= F(x) ^ P[p]
.macro half x, xb, y, lane, p
    shrx  esi, \x, ecx
    mov   edx, [rdi + rsi*4 + \lane*STRIDE + SBOX]
    rorx  eax, \x, 8
    movzx esi, ah
    add   edx, [rdi + rsi*4 + \lane*STRIDE + SBOX + 1024]
    movzx esi, al
    xor   edx, [rdi + rsi*4 + \lane*STRIDE + SBOX + 2048]
    movzx esi, \xb
    add   edx, [rdi + rsi*4 + \lane*STRIDE + SBOX + 3072]
    xor   edx, [rdi + \lane*STRIDE + \p*4]
    xor   \y, edx
.endm

.macro left_to_right p      // r ^= F(l) ^ P[p]
    half ebx, bl, ebp, 0, \p
    half r8d, r8b, r9d, 1, \p
    half r10d, r10b, r11d, 2, \p
    half r12d, r12b, r13d, 3, \p
    half r14d, r14b, r15d, 4, \p
.endm

.macro right_to_left p      // l ^= F(r) ^ P[p]
    half ebp, bpl, ebx, 0, \p
    half r9d, r9b, r8d, 1, \p
    half r11d, r11b, r10d, 2, \p
    half r13d, r13b, r12d, 3, \p
    half r15d, r15b, r14d, 4, \p
.endm

// Finishes one lane's block and writes it over the next two table words.
.macro finish l, r, lane
    xor   \r, [rdi + \lane*STRIDE + 17*4]
    mov   [rdi + rsi + \lane*STRIDE], \r
    mov   [rdi + rsi + \lane*STRIDE + 4], \l
    mov   edx, \l
    mov   \l, \r
    mov   \r, edx
.endm

    .globl bc_expand0_5
    .type bc_expand0_5, @function
    .p2align 6
bc_expand0_5:
    push  rbx
    push  rbp
    push  r12
    push  r13
    push  r14
    push  r15
    push  0                 // byte offset of the next table word
    mov   ecx, 24
    xor   ebx, ebx
    xor   ebp, ebp
    xor   r8d, r8d
    xor   r9d, r9d
    xor   r10d, r10d
    xor   r11d, r11d
    xor   r12d, r12d
    xor   r13d, r13d
    xor   r14d, r14d
    xor   r15d, r15d
    .p2align 6
1:
    xor   ebx, [rdi]
    xor   r8d, [rdi + 1*STRIDE]
    xor   r10d, [rdi + 2*STRIDE]
    xor   r12d, [rdi + 3*STRIDE]
    xor   r14d, [rdi + 4*STRIDE]
    left_to_right 1
    right_to_left 2
    left_to_right 3
    right_to_left 4
    left_to_right 5
    right_to_left 6
    left_to_right 7
    right_to_left 8
    left_to_right 9
    right_to_left 10
    left_to_right 11
    right_to_left 12
    left_to_right 13
    right_to_left 14
    left_to_right 15
    right_to_left 16
    mov   rsi, [rsp]
    finish ebx, ebp, 0
    finish r8d, r9d, 1
    finish r10d, r11d, 2
    finish r12d, r13d, 3
    finish r14d, r15d, 4
    add   rsi, 8
    mov   [rsp], rsi
    cmp   rsi, WORDS*4
    jne   1b
    add   rsp, 8
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbp
    pop   rbx
    ret
    .size bc_expand0_5, .-bc_expand0_5
#endif
    .section .note.GNU-stack,"",@progbits
