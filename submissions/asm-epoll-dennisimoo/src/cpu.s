# cpu.s: CPU feature detection. cpu_detect() fills cpu_features (bitmask of CPU_* from defs.inc) once at startup,
# before any thread starts; afterwards it is read-only.
.include "defs.inc"

.bss
.align 8
.globl cpu_features
cpu_features: .quad 0

.text
.globl cpu_detect
cpu_detect:
    push rbx
    xor r8d, r8d                    # feature bits
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r9d, ecx                    # leaf 1 ecx
    bt ecx, 20                      # SSE4.2
    jnc 1f
    or r8d, CPU_SSE42
1:  # OS support for ymm/zmm state: OSXSAVE (ecx bit 27) then XCR0
    xor r10d, r10d                  # xcr0 low
    bt r9d, 27
    jnc 2f
    xor ecx, ecx
    xgetbv
    mov r10d, eax
2:  mov eax, 7
    xor ecx, ecx
    cpuid                           # ebx = leaf 7 features
    bt ebx, 29                      # SHA
    jnc 3f
    or r8d, CPU_SHA
3:  bt ebx, 8                       # BMI2
    jnc 4f
    or r8d, CPU_BMI2
4:  mov eax, r10d
    and eax, 6                      # XMM|YMM state
    cmp eax, 6
    jne 6f
    bt ebx, 5                       # AVX2
    jnc 5f
    or r8d, CPU_AVX2
5:  mov eax, r10d
    and eax, 0xe6                   # XMM|YMM|opmask|ZMM_Hi256|Hi16_ZMM
    cmp eax, 0xe6
    jne 6f
    mov eax, ebx
    and eax, (1 << 16) | (1 << 30) | (1 << 31)   # AVX512F, AVX512BW, AVX512VL
    cmp eax, (1 << 16) | (1 << 30) | (1 << 31)
    jne 6f
    or r8d, CPU_AVX512
6:  mov [rip + cpu_features], r8
    mov rax, r8
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits
