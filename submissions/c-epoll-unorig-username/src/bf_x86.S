// Register-resident Blowfish key-schedule kernels for x86-64 with BMI2. Each fills a whole state (P, then S) for 1..5
// lanes in one pass with no salt: every lane's L and R live in general-purpose registers, and all lanes run the same
// round one after another, so the out-of-order core overlaps their load chains.
//   void bf_fill_x86_N(void *states);   // N states, 4224 bytes apart
#if defined(__x86_64__)
.intel_syntax noprefix
.set STRIDE, 4224
.set S0, 18*4
.set S1, S0+1024
.set S2, S1+1024
.set S3, S2+1024

// Y ^= F(X) ^ P[i], lane l
.macro FROUND X, X8, Y, l, i
  rorx ecx, \X, 24
  movzx edx, cl
  mov eax, dword ptr [rdi + rdx*4 + \l*STRIDE + S0]
  rorx ecx, \X, 16
  movzx edx, cl
  add eax, dword ptr [rdi + rdx*4 + \l*STRIDE + S1]
  rorx ecx, \X, 8
  movzx edx, cl
  xor eax, dword ptr [rdi + rdx*4 + \l*STRIDE + S2]
  movzx edx, \X8
  add eax, dword ptr [rdi + rdx*4 + \l*STRIDE + S3]
  xor eax, dword ptr [rdi + \l*STRIDE + \i*4]
  xor \Y, eax
.endm

.macro PUSHALL
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
.endm
.macro POPALL
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
.endm

.macro LANE_END L, R, l
  xor \R, dword ptr [rdi + \l*STRIDE + 17*4]
  mov dword ptr [rdi + rsi*4 + \l*STRIDE], \R
  mov dword ptr [rdi + rsi*4 + \l*STRIDE + 4], \L
  mov eax, \L
  mov \L, \R
  mov \R, eax
.endm

// lane registers: (L, L8, R, R8)
#define L0 r8d
#define L0b r8b
#define R0 r9d
#define R0b r9b
#define L1 r10d
#define L1b r10b
#define R1 r11d
#define R1b r11b
#define L2 r12d
#define L2b r12b
#define R2 r13d
#define R2b r13b
#define L3 r14d
#define L3b r14b
#define R3 r15d
#define R3b r15b
#define L4 ebx
#define L4b bl
#define R4 ebp
#define R4b bpl

.macro KERNEL n
.globl bf_fill_x86_\n
.type bf_fill_x86_\n, @function
.p2align 6
bf_fill_x86_\n:
  PUSHALL
  xor esi, esi
  xor r8d, r8d
  xor r9d, r9d
  xor r10d, r10d
  xor r11d, r11d
  xor r12d, r12d
  xor r13d, r13d
  xor r14d, r14d
  xor r15d, r15d
  xor ebx, ebx
  xor ebp, ebp
.p2align 6
1:
  .if \n > 0
  xor L0, dword ptr [rdi + 0*STRIDE]
  .endif
  .if \n > 1
  xor L1, dword ptr [rdi + 1*STRIDE]
  .endif
  .if \n > 2
  xor L2, dword ptr [rdi + 2*STRIDE]
  .endif
  .if \n > 3
  xor L3, dword ptr [rdi + 3*STRIDE]
  .endif
  .if \n > 4
  xor L4, dword ptr [rdi + 4*STRIDE]
  .endif
  .irp i, 1, 3, 5, 7, 9, 11, 13, 15
    FROUND L0, L0b, R0, 0, \i
    .if \n > 1
    FROUND L1, L1b, R1, 1, \i
    .endif
    .if \n > 2
    FROUND L2, L2b, R2, 2, \i
    .endif
    .if \n > 3
    FROUND L3, L3b, R3, 3, \i
    .endif
    .if \n > 4
    FROUND L4, L4b, R4, 4, \i
    .endif
    FROUND R0, R0b, L0, 0, (\i+1)
    .if \n > 1
    FROUND R1, R1b, L1, 1, (\i+1)
    .endif
    .if \n > 2
    FROUND R2, R2b, L2, 2, (\i+1)
    .endif
    .if \n > 3
    FROUND R3, R3b, L3, 3, (\i+1)
    .endif
    .if \n > 4
    FROUND R4, R4b, L4, 4, (\i+1)
    .endif
  .endr
  LANE_END L0, R0, 0
  .if \n > 1
  LANE_END L1, R1, 1
  .endif
  .if \n > 2
  LANE_END L2, R2, 2
  .endif
  .if \n > 3
  LANE_END L3, R3, 3
  .endif
  .if \n > 4
  LANE_END L4, R4, 4
  .endif
  add esi, 2
  cmp esi, 1042
  jb 1b
  POPALL
  ret
.size bf_fill_x86_\n, .-bf_fill_x86_\n
.endm

.text
KERNEL 1
KERNEL 2
KERNEL 3
KERNEL 4
KERNEL 5
.section .note.GNU-stack,"",@progbits
#endif
