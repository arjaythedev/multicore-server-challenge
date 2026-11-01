.intel_syntax noprefix
.text
.globl fast_asm_zero
.type fast_asm_zero, @function
fast_asm_zero:
    # rdi: ptr, rsi: size
    xor eax, eax
    mov rcx, rsi
    shr rcx, 3
    rep stosq
    mov rcx, rsi
    and rcx, 7
    rep stosb
    ret

.globl fast_asm_rdtsc
.type fast_asm_rdtsc, @function
fast_asm_rdtsc:
    rdtsc
    shl rdx, 32
    or rax, rdx
    ret

# fast_asm_memchr(const char *buf, char c, size_t len) -> const char *
# Returns pointer to first occurrence of c in buf[0..len], or NULL (0) if not found.
.globl fast_asm_memchr
.type fast_asm_memchr, @function
fast_asm_memchr:
    test rdx, rdx
    jz .Lmemchr_not_found

    movzx eax, sil
    vmovd xmm0, eax
    vpbroadcastb ymm0, xmm0

    cmp rdx, 32
    jb .Lmemchr_check16

.Lmemchr_loop32:
    vmovdqu ymm1, [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test eax, eax
    jnz .Lmemchr_found32

    add rdi, 32
    sub rdx, 32
    cmp rdx, 32
    jae .Lmemchr_loop32

.Lmemchr_check16:
    cmp rdx, 16
    jb .Lmemchr_scalar
    vmovdqu xmm1, [rdi]
    vpcmpeqb xmm1, xmm1, xmm0
    vpmovmskb eax, xmm1
    test eax, eax
    jnz .Lmemchr_found16

    add rdi, 16
    sub rdx, 16

.Lmemchr_scalar:
    test rdx, rdx
    jz .Lmemchr_not_found
.Lmemchr_scalar_loop:
    cmp byte ptr [rdi], sil
    je .Lmemchr_scalar_found
    inc rdi
    dec rdx
    jnz .Lmemchr_scalar_loop

.Lmemchr_not_found:
    vzeroupper
    xor eax, eax
    ret

.Lmemchr_found32:
    tzcnt ecx, eax
    lea rax, [rdi + rcx]
    vzeroupper
    ret

.Lmemchr_found16:
    tzcnt ecx, eax
    lea rax, [rdi + rcx]
    vzeroupper
    ret

.Lmemchr_scalar_found:
    mov rax, rdi
    vzeroupper
    ret

# fast_asm_find_crlf_crlf(const char *buf, size_t len) -> const char *
# Returns pointer to first occurrence of "\r\n\r\n" in buf[0..len], or NULL (0) if not found.
.globl fast_asm_find_crlf_crlf
.type fast_asm_find_crlf_crlf, @function
fast_asm_find_crlf_crlf:
    cmp rdx, 4
    jb .Lcrlf_early_exit

    mov eax, 0x0d
    vmovd xmm4, eax
    vpbroadcastb ymm4, xmm4     # ymm4 = all 0x0D ('\r')

    mov eax, 0x0a
    vmovd xmm5, eax
    vpbroadcastb ymm5, xmm5     # ymm5 = all 0x0A ('\n')

    cmp rdx, 35
    jb .Lcrlf_check16

.Lcrlf_loop32:
    vmovdqu ymm0, [rdi]
    vmovdqu ymm1, [rdi + 1]
    vmovdqu ymm2, [rdi + 2]
    vmovdqu ymm3, [rdi + 3]

    vpcmpeqb ymm0, ymm0, ymm4
    vpcmpeqb ymm1, ymm1, ymm5
    vpcmpeqb ymm2, ymm2, ymm4
    vpcmpeqb ymm3, ymm3, ymm5

    vpand ymm0, ymm0, ymm1
    vpand ymm2, ymm2, ymm3
    vpand ymm0, ymm0, ymm2

    vpmovmskb eax, ymm0
    test eax, eax
    jnz .Lcrlf_found32

    add rdi, 32
    sub rdx, 32
    cmp rdx, 35
    jae .Lcrlf_loop32

.Lcrlf_check16:
    cmp rdx, 19
    jb .Lcrlf_scalar

    vmovdqu xmm0, [rdi]
    vmovdqu xmm1, [rdi + 1]
    vmovdqu xmm2, [rdi + 2]
    vmovdqu xmm3, [rdi + 3]

    vpcmpeqb xmm0, xmm0, xmm4
    vpcmpeqb xmm1, xmm1, xmm5
    vpcmpeqb xmm2, xmm2, xmm4
    vpcmpeqb xmm3, xmm3, xmm5

    vpand xmm0, xmm0, xmm1
    vpand xmm2, xmm2, xmm3
    vpand xmm0, xmm0, xmm2

    vpmovmskb eax, xmm0
    test eax, eax
    jnz .Lcrlf_found16

    add rdi, 16
    sub rdx, 16

.Lcrlf_scalar:
    cmp rdx, 4
    jb .Lcrlf_not_found
    mov r8d, 0x0a0d0a0d
.Lcrlf_scalar_loop:
    cmp dword ptr [rdi], r8d
    je .Lcrlf_scalar_found
    inc rdi
    dec rdx
    cmp rdx, 4
    jae .Lcrlf_scalar_loop

.Lcrlf_not_found:
    vzeroupper
    xor eax, eax
    ret

.Lcrlf_found32:
    tzcnt ecx, eax
    lea rax, [rdi + rcx]
    vzeroupper
    ret

.Lcrlf_found16:
    tzcnt ecx, eax
    lea rax, [rdi + rcx]
    vzeroupper
    ret

.Lcrlf_scalar_found:
    mov rax, rdi
    vzeroupper
    ret

.Lcrlf_early_exit:
    xor eax, eax
    ret

