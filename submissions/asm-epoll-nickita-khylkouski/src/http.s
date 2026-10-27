# http.s: HTTP/1.1 request parser, percent-decoding, query parameters, response head writer.
#
# Behaviour follows the Rust reference (submissions/rust-tokio-nickita-khylkouski/src/http.rs, which uses
# httparse 1.10): same accepted bytes, same header rules, same limits. See test/http/ for the differential
# test against that code.
#
# SIMD scans load aligned 16-byte blocks. An aligned block that holds at least one byte of the buffer lies
# in the same page as that byte, so reading the rest of the block cannot fault; bytes outside the buffer
# are masked off or ignored. (Memory checkers such as ASan would flag these reads; they are intended.)
.include "defs.inc"

.set LOW20, 0x2020202020202020          # OR-ing this lowercases ASCII letters (exact for our compares)
.set F_AUTH, 0x100                      # internal: Authorization seen (masked out of REQ_FLAGS)

# VALMASK: xmm0 = 16 bytes -> edx = mask of bytes that end a header value: < 0x20 except TAB, or DEL.
# Needs xmm8 = 0x1f x16, xmm9 = 0x7f x16, xmm10 = 0x09 x16. Clobbers xmm0-xmm2.
.macro VALMASK
    movdqa xmm1, xmm0
    pminub xmm1, xmm8
    pcmpeqb xmm1, xmm0
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm10
    pandn xmm2, xmm1
    pcmpeqb xmm0, xmm9
    por xmm0, xmm2
    pmovmskb edx, xmm0
.endm

# TGTMASK: xmm0 = 16 bytes -> edx = bytes that end a request-target (<= 0x20 or DEL), esi = '?' bytes,
# edi = bytes >= 0x80. Needs xmm9 = 0x7f, xmm11 = 0x20, xmm12 = '?'. Clobbers xmm1, xmm2.
.macro TGTMASK
    pmovmskb edi, xmm0
    movdqa xmm1, xmm0
    pminub xmm1, xmm11
    pcmpeqb xmm1, xmm0
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm9
    por xmm1, xmm2
    pmovmskb edx, xmm1
    pcmpeqb xmm0, xmm12
    pmovmskb esi, xmm0
.endm

.text

# ------------------------------------------------------------------------------------------------ http_parse
# http_parse(buf, len, req) -> consumed (> 0) | 0 (incomplete) | -1 (bad request) | -2 (too large)
#   rdi = buf, rsi = len, rdx = req (REQ_SIZE bytes, fully overwritten).
# Leading empty lines are skipped (and counted in consumed). Line ends are CRLF or a bare LF, as httparse.
# On 0 with REQF_HEAD_DONE set the head is complete and every field is valid except the body: for a
# Content-Length body the whole request needs (REQ_BODY - buf) + REQ_BODY_LEN bytes. A chunked body is
# decoded in place (the chunk data is moved down to REQ_BODY) once the whole message is buffered.
# On -1/-2 REQ_FLAGS is 0, or REQF_EXPECT when the head was valid and only the chunked body failed
# (Rust sends "100 Continue" before reading the body, then closes).
.globl http_parse
.type http_parse, @function
http_parse:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                        # buf
    lea r12, [rdi + rsi]                # end
    mov r13, rdx                        # req
    mov r14, rdi                        # cursor
    xor r15d, r15d                      # flags
    xor ebp, ebp                        # header count
    pxor xmm0, xmm0
    movdqu [r13], xmm0
    movdqu [r13 + 16], xmm0
    movdqu [r13 + 32], xmm0
    movdqu [r13 + 48], xmm0
    movdqu [r13 + 64], xmm0
    movdqa xmm8, [rip + .Lc1f]
    movdqa xmm9, [rip + .Lc7f]
    movdqa xmm10, [rip + .Lc09]
    movdqa xmm11, [rip + .Lc20]
    movdqa xmm12, [rip + .Lcqm]
    lea r11, [rip + .Ltchar]

.Lskip:                                 # empty lines before the request line
    cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp al, 13
    je .Lskip_cr
    cmp al, 10
    jne .Lmethod
    inc r14
    jmp .Lskip
.Lskip_cr:
    lea rax, [r14 + 1]
    cmp rax, r12
    jae .Lneed
    cmp byte ptr [rax], 10
    jne .Lbad
    add r14, 2
    jmp .Lskip

.Lmethod:
    mov rax, r12
    sub rax, r14
    cmp rax, 8
    jb .Lmeth_any
    mov rax, [r14]
    cmp eax, 0x20544547                 # "GET "
    je .Lm_get
    mov rcx, 0xffffffffff
    and rcx, rax
    mov rdx, 0x2054534f50               # "POST "
    cmp rcx, rdx
    je .Lm_post
    cmp eax, 0x20545550                 # "PUT "
    je .Lm_put
    mov rcx, 0xffffffffffffff
    and rcx, rax
    mov rdx, 0x204554454c4544           # "DELETE "
    cmp rcx, rdx
    je .Lm_delete
.Lmeth_any:                             # any token, then classify
    mov rsi, r14
1:  cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp al, ' '
    je 2f
    cmp byte ptr [r11 + rax], 0
    je .Lbad
    inc r14
    jmp 1b
2:  mov rcx, r14
    sub rcx, rsi
    jz .Lbad
    inc r14
    cmp rcx, 3
    je .Lm3
    cmp rcx, 4
    je .Lm4
    cmp rcx, 6
    jne .Ltarget
    cmp dword ptr [rsi], 0x454c4544     # "DELE"
    jne .Ltarget
    cmp word ptr [rsi + 4], 0x4554      # "TE"
    jne .Ltarget
    mov qword ptr [r13 + REQ_METHOD], M_DELETE
    jmp .Ltarget
.Lm3:
    movzx eax, word ptr [rsi]
    movzx edx, byte ptr [rsi + 2]
    shl edx, 16
    or eax, edx
    cmp eax, 0x544547                   # "GET"
    je 3f
    cmp eax, 0x545550                   # "PUT"
    jne .Ltarget
    mov qword ptr [r13 + REQ_METHOD], M_PUT
    jmp .Ltarget
3:  mov qword ptr [r13 + REQ_METHOD], M_GET
    jmp .Ltarget
.Lm4:
    cmp dword ptr [rsi], 0x54534f50     # "POST"
    jne .Ltarget
    mov qword ptr [r13 + REQ_METHOD], M_POST
    jmp .Ltarget
.Lm_get:
    mov qword ptr [r13 + REQ_METHOD], M_GET
    add r14, 4
    jmp .Ltarget
.Lm_post:
    mov qword ptr [r13 + REQ_METHOD], M_POST
    add r14, 5
    jmp .Ltarget
.Lm_put:
    mov qword ptr [r13 + REQ_METHOD], M_PUT
    add r14, 4
    jmp .Ltarget
.Lm_delete:
    mov qword ptr [r13 + REQ_METHOD], M_DELETE
    add r14, 7

.Ltarget:                               # request-target: bytes 0x21..0x7e and >= 0x80, ends at SP
    mov [r13 + REQ_PATH], r14
    xor r8d, r8d                        # first '?' (0 = none)
    xor r9d, r9d                        # OR of high-bit masks
    cmp r14, r12
    jae .Lneed
    mov rax, r14
    mov ecx, eax
    and ecx, 15
    and rax, -16
    movdqa xmm0, [rax]
    TGTMASK
    shr edx, cl
    shr esi, cl
    shr edi, cl
    mov r10, r14                        # bit i of the masks = byte r10 + i
    jmp .Ltgt_check
.Ltgt_loop:
    add rax, 16
    cmp rax, r12
    jae .Lneed
    movdqa xmm0, [rax]
    TGTMASK
    mov r10, rax
.Ltgt_check:
    test edx, edx
    jnz .Ltgt_stop
    or r9d, edi
    test r8, r8
    jnz .Ltgt_loop
    test esi, esi
    jz .Ltgt_loop
    bsf esi, esi
    lea r8, [r10 + rsi]
    jmp .Ltgt_loop
.Ltgt_stop:
    bsf ecx, edx
    lea r14, [r10 + rcx]
    cmp r14, r12
    jae .Lneed
    mov edx, 1
    shl edx, cl
    dec edx                             # bits below the stop byte
    and edi, edx
    or r9d, edi
    test r8, r8
    jnz 1f
    and esi, edx
    jz 1f
    bsf esi, esi
    lea r8, [r10 + rsi]
1:  cmp byte ptr [r14], ' '
    jne .Lbad
    mov rax, [r13 + REQ_PATH]
    cmp r14, rax
    je .Lbad                            # empty target
    mov rdx, r14
    test r8, r8
    jz 2f
    lea rcx, [r8 + 1]
    mov [r13 + REQ_QUERY], rcx
    sub rdx, rcx
    mov [r13 + REQ_QUERY_LEN], rdx
    mov rdx, r8
2:  sub rdx, rax
    mov [r13 + REQ_PATH_LEN], rdx
    test r9d, r9d
    jz 3f
    mov rdi, rax                        # non-ASCII target: must be UTF-8 (Rust's from_utf8)
    mov rsi, r14
    sub rsi, rax
    call .Lutf8_scan
    test edx, edx
    jnz .Lbad
3:  inc r14

    mov rax, r12                        # version
    sub rax, r14
    cmp rax, 8
    jb .Lver_short
    mov rax, [r14]
    mov rdx, 0x312e312f50545448         # "HTTP/1.1"
    cmp rax, rdx
    je 4f
    mov rdx, 0x302e312f50545448         # "HTTP/1.0"
    cmp rax, rdx
    jne .Lbad
    or r15d, REQF_HTTP10 | REQF_CLOSE
4:  add r14, 8
    cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp al, 10
    je 5f
    cmp al, 13
    jne .Lbad
    inc r14
    cmp r14, r12
    jae .Lneed
    cmp byte ptr [r14], 10
    jne .Lbad
5:  inc r14
    mov r10, LOW20

# ---- header lines
.Lhdr:
    cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp byte ptr [r11 + rax], 0
    je .Lhdr_end
    mov rsi, r14                        # name
    inc r14
.Lname:
    cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp byte ptr [r11 + rax], 0
    je .Lname_end
    inc r14
    jmp .Lname
.Lname_end:
    cmp al, ':'
    jne .Lbad
    mov rdi, r14
    sub rdi, rsi                        # name length
    inc r14
.Lows:
    cmp r14, r12
    jae .Lneed
    movzx eax, byte ptr [r14]
    cmp al, ' '
    je 1f
    cmp al, 9
    jne .Lval
1:  inc r14
    jmp .Lows
.Lval:
    mov r8, r14                         # value
    mov rax, r14
    mov ecx, eax
    and ecx, 15
    and rax, -16
    movdqa xmm0, [rax]
    VALMASK
    shr edx, cl
    test edx, edx
    jz .Lval_loop
    bsf edx, edx
    add rdx, r14
    jmp .Lval_end
.Lval_loop:
    add rax, 16
    cmp rax, r12
    jae .Lneed
    movdqa xmm0, [rax]
    VALMASK
    test edx, edx
    jz .Lval_loop
    bsf edx, edx
    add rdx, rax
.Lval_end:
    cmp rdx, r12
    jae .Lneed
    movzx ecx, byte ptr [rdx]
    lea r14, [rdx + 1]
    cmp cl, 10
    je 2f
    cmp cl, 13
    jne .Lbad
    cmp r14, r12
    jae .Lneed
    cmp byte ptr [r14], 10
    jne .Lbad
    inc r14
2:  mov r9, rdx                         # value end; trim trailing SP / HTAB
3:  cmp r9, r8
    jbe 4f
    movzx ecx, byte ptr [r9 - 1]
    cmp cl, ' '
    je 5f
    cmp cl, 9
    jne 4f
5:  dec r9
    jmp 3b
4:  inc ebp
    cmp ebp, HTTP_MAX_HEADERS
    ja .Lbad
    # rsi = name, rdi = name length, r8..r9 = trimmed value
    cmp rdi, 13
    je .Lh_auth
    cmp rdi, 14
    je .Lh_clen
    cmp rdi, 10
    je .Lh_conn
    cmp rdi, 6
    je .Lh_expect
    cmp rdi, 17
    je .Lh_te
    cmp rdi, 15
    je .Lh_ae
    jmp .Lhdr

.Lh_auth:
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x7a69726f68747561         # "authoriz"
    cmp rax, rdx
    jne .Lhdr
    mov rax, [rsi + 5]
    or rax, r10
    mov rdx, 0x6e6f6974617a6972         # "rization"
    cmp rax, rdx
    jne .Lhdr
    bts r15d, 8                         # F_AUTH
    jc .Lbad                            # duplicate
    mov [r13 + REQ_AUTH], r8
    sub r9, r8
    mov [r13 + REQ_AUTH_LEN], r9
    jmp .Lhdr

.Lh_clen:
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x2d746e65746e6f63         # "content-"
    cmp rax, rdx
    jne .Lhdr
    mov rax, [rsi + 6]
    or rax, r10
    mov rdx, 0x6874676e656c2d74         # "t-length"
    cmp rax, rdx
    jne .Lhdr
    bts r15d, 3                         # REQF_HAS_CL
    jc .Lbad                            # duplicate
    cmp r8, r9
    je .Lbad
    xor eax, eax
1:  movzx ecx, byte ptr [r8]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lbad
    imul rax, rax, 10
    jo .Lbad
    add rax, rcx
    jo .Lbad
    inc r8
    cmp r8, r9
    jb 1b
    cmp rax, HTTP_MAX_BODY
    ja .Ltoolarge
    mov [r13 + REQ_BODY_LEN], rax
    jmp .Lhdr

.Lh_conn:                               # comma-separated tokens: close / keep-alive
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x697463656e6e6f63         # "connecti"
    cmp rax, rdx
    jne .Lhdr
    movzx eax, word ptr [rsi + 8]
    or eax, 0x2020
    cmp eax, 0x6e6f                     # "on"
    jne .Lhdr
    xor edi, edi                        # 1 = close, 2 = keep-alive
.Lct_tok:
    mov rsi, r8                         # token start
1:  cmp r8, r9
    jae 2f
    cmp byte ptr [r8], ','
    je 2f
    inc r8
    jmp 1b
2:  mov rdx, r8                         # token end; trim
3:  cmp rsi, rdx
    jae .Lct_next
    movzx ecx, byte ptr [rsi]
    cmp cl, ' '
    je 4f
    cmp cl, 9
    jne 5f
4:  inc rsi
    jmp 3b
5:  movzx ecx, byte ptr [rdx - 1]
    cmp cl, ' '
    je 6f
    cmp cl, 9
    jne 7f
6:  dec rdx
    jmp 5b
7:  sub rdx, rsi
    cmp rdx, 5
    je .Lct_close
    cmp rdx, 10
    jne .Lct_next
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x696c612d7065656b         # "keep-ali"
    cmp rax, rdx
    jne .Lct_next
    movzx eax, word ptr [rsi + 8]
    or eax, 0x2020
    cmp eax, 0x6576                     # "ve"
    jne .Lct_next
    or edi, 2
    jmp .Lct_next
.Lct_close:
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x736f6c63                 # "clos"
    jne .Lct_next
    movzx eax, byte ptr [rsi + 4]
    or eax, 0x20
    cmp eax, 'e'
    jne .Lct_next
    or edi, 1
.Lct_next:
    inc r8                              # past ','
    cmp r8, r9
    jbe .Lct_tok
    test edi, 1
    jz 8f
    or r15d, REQF_CLOSE
    jmp .Lhdr
8:  test edi, 2
    jz .Lhdr
    test r15d, REQF_HTTP10
    jz .Lhdr
    and r15d, ~REQF_CLOSE
    jmp .Lhdr

.Lh_expect:
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x65707865                 # "expe"
    jne .Lhdr
    movzx eax, word ptr [rsi + 4]
    or eax, 0x2020
    cmp eax, 0x7463                     # "ct"
    jne .Lhdr
    mov rax, r9
    sub rax, r8
    cmp rax, 12
    jne .Lbad
    mov rax, [r8]
    or rax, r10
    mov rdx, 0x746e6f632d303031         # "100-cont"
    cmp rax, rdx
    jne .Lbad
    mov eax, [r8 + 8]
    or eax, 0x20202020
    cmp eax, 0x65756e69                 # "inue"
    jne .Lbad
    or r15d, REQF_EXPECT
    jmp .Lhdr

.Lh_te:
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x726566736e617274         # "transfer"
    cmp rax, rdx
    jne .Lhdr
    mov rax, [rsi + 8]
    or rax, r10
    mov rdx, 0x6e69646f636e652d         # "-encodin"
    cmp rax, rdx
    jne .Lhdr
    movzx eax, byte ptr [rsi + 16]
    or eax, 0x20
    cmp eax, 'g'
    jne .Lhdr
    bts r15d, 2                         # REQF_CHUNKED
    jc .Lbad                            # duplicate
    mov rax, r9
    sub rax, r8
    cmp rax, 7                          # exactly "chunked" (Rust rejects every other coding)
    jne .Lbad
    mov eax, [r8]
    or eax, 0x20202020
    cmp eax, 0x6e756863                 # "chun"
    jne .Lbad
    mov eax, [r8 + 3]
    or eax, 0x20202020
    cmp eax, 0x64656b6e                 # "nked"
    jne .Lbad
    jmp .Lhdr

.Lh_ae:                                 # Accept-Encoding: Rust's accepts_gzip, OR-ed over every such header
    mov rax, [rsi]
    or rax, r10
    mov rdx, 0x652d747065636361         # "accept-e"
    cmp rax, rdx
    jne .Lhdr
    mov rax, [rsi + 7]
    or rax, r10
    mov rdx, 0x676e69646f636e65         # "encoding"
    cmp rax, rdx
    jne .Lhdr
    test r15d, REQF_GZIP
    jnz .Lhdr
.Lae_coding:                            # a "gzip" or "*" coding (split on ',') with no q=0 param (split on ';')
    mov rsi, r8
1:  cmp r8, r9
    jae 2f
    movzx eax, byte ptr [r8]
    cmp al, ','
    je 2f
    cmp al, ';'
    je 2f
    inc r8
    jmp 1b
2:  mov rdx, r8                         # name = rsi..rdx, trimmed
3:  cmp rsi, rdx
    jae 6f
    movzx ecx, byte ptr [rsi]
    cmp cl, ' '
    je 4f
    cmp cl, 9
    jne 5f
4:  inc rsi
    jmp 3b
5:  movzx ecx, byte ptr [rdx - 1]
    cmp cl, ' '
    je 4f
    cmp cl, 9
    jne 6f
4:  dec rdx
    jmp 5b
6:  xor edi, edi                        # 1 = this coding accepts gzip so far
    sub rdx, rsi
    cmp rdx, 1
    jne 7f
    cmp byte ptr [rsi], '*'
    sete dil
    jmp .Lae_param
7:  cmp rdx, 4
    jne .Lae_param
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 0x70697a67                 # "gzip"
    sete dil
.Lae_param:                             # r8 at ',', ';' or the value end
    cmp r8, r9
    jae .Lae_end
    cmp byte ptr [r8], ','
    je .Lae_end
    inc r8                              # past ';'
1:  cmp r8, r9                          # skip leading SP / HTAB (trailing ones never matter)
    jae .Lae_end
    movzx eax, byte ptr [r8]
    cmp al, ' '
    je 2f
    cmp al, 9
    jne 3f
2:  inc r8
    jmp 1b
3:  xor ecx, ecx                        # 1 = "q=" param
    lea rsi, [r8 + 1]
    cmp rsi, r9
    jae 5f
    or eax, 0x20
    cmp al, 'q'
    jne 5f
    cmp byte ptr [rsi], '='
    jne 5f
    mov ecx, 1                          # needs a digit 1..9 somewhere in the rest of the param
    add r8, 2
5:  cmp r8, r9
    jae 7f
    movzx eax, byte ptr [r8]
    cmp al, ','
    je 7f
    cmp al, ';'
    je 7f
    sub eax, '1'
    cmp eax, 8
    ja 6f
    xor ecx, ecx
6:  inc r8
    jmp 5b
7:  test ecx, ecx
    jz .Lae_param
    xor edi, edi                        # q=0 (no nonzero digit)
    jmp .Lae_param
.Lae_end:
    test edi, edi
    jnz 8f
    cmp r8, r9
    jae .Lhdr
    inc r8                              # past ','
    jmp .Lae_coding
8:  or r15d, REQF_GZIP
    jmp .Lhdr

.Lhdr_end:                              # not a name byte: the empty line, or an error
    cmp al, 10
    je 1f
    cmp al, 13
    jne .Lbad
    inc r14
    cmp r14, r12
    jae .Lneed
    cmp byte ptr [r14], 10
    jne .Lbad
1:  inc r14
    mov rax, r14
    sub rax, rbx
    cmp rax, HTTP_MAX_HEAD
    ja .Ltoolarge
    mov eax, r15d
    and eax, REQF_HAS_CL | REQF_CHUNKED
    cmp eax, REQF_HAS_CL | REQF_CHUNKED
    je .Lbad
    mov [r13 + REQ_BODY], r14
    test r15d, REQF_CHUNKED
    jnz .Lchunked
    mov rcx, [r13 + REQ_BODY_LEN]
    mov rax, r12
    sub rax, r14
    cmp rax, rcx
    jb .Lbody_need
    lea rax, [r14 + rcx]
    sub rax, rbx
.Lret:
    and r15d, 0xff
    mov [r13 + REQ_FLAGS], r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lver_short:                            # < 8 bytes: reject early unless a prefix of "HTTP/1." (httparse)
    lea rdx, [rip + .Lhttp1]
    xor ecx, ecx
1:  cmp rcx, rax
    jae .Lneed
    cmp ecx, 7
    jae .Lneed
    movzx esi, byte ptr [r14 + rcx]
    cmp sil, [rdx + rcx]
    jne .Lbad
    inc ecx
    jmp 1b
.Lbody_need:
    or r15d, REQF_HEAD_DONE
    xor eax, eax
    jmp .Lret
.Lneed:                                 # incomplete head
    mov rax, r12
    sub rax, rbx
    cmp rax, HTTP_MAX_HEAD
    ja .Ltoolarge
    xor eax, eax
    jmp .Lout
.Lbad:
    mov rax, -1
    jmp .Lout
.Ltoolarge:
    mov rax, -2
.Lout:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ---- chunked body, as the Rust read_request: size line up to the first CRLF, hex digits before any ';'
# (1..16 of them), data + CRLF, then trailer lines (each must contain ':') up to an empty line.
.Lchunked:
    mov eax, r15d                       # the head is valid, so Rust has sent 100 Continue by now: a
    and eax, REQF_EXPECT                # -1/-2 from here on leaves REQF_EXPECT in REQ_FLAGS
    mov [r13 + REQ_FLAGS], rax
    mov r8, r14                         # at
    xor r9d, r9d                        # decoded length
.Lck_line:
    mov rdi, r8
    call .Lfind_crlf
    test rax, rax
    jz .Lck_need_line
    mov rcx, rax
    sub rcx, r8
    cmp rcx, HTTP_MAX_HEAD
    ja .Ltoolarge
    lea rdi, [rip + .Lhexval]
    xor edx, edx
    mov rsi, r8
1:  cmp rsi, rax
    je 2f
    movzx ecx, byte ptr [rsi]
    cmp cl, ';'
    je 2f
    movzx ecx, byte ptr [rdi + rcx]
    cmp ecx, 15
    ja .Lbad
    shl rdx, 4
    or rdx, rcx
    inc rsi
    jmp 1b
2:  sub rsi, r8
    jz .Lbad
    cmp rsi, 16
    ja .Lbad
    lea r8, [rax + 2]
    test rdx, rdx
    jz .Lck_trailers
    mov rcx, HTTP_MAX_BODY
    sub rcx, r9
    cmp rdx, rcx
    ja .Ltoolarge
    lea rcx, [r8 + rdx + 2]             # end of this chunk's data CRLF
    cmp rcx, r12
    ja .Lbody_need
    cmp word ptr [rcx - 2], 0x0a0d
    jne .Lbad
    add r9, rdx
    mov r8, rcx
    jmp .Lck_line
.Lck_need_line:
    mov rax, r12
    sub rax, r8
    cmp rax, HTTP_MAX_HEAD
    ja .Ltoolarge
    jmp .Lbody_need
.Lck_trailers:
    mov r10, r8                         # trailer start
.Lck_tr:
    mov rdi, r8
    call .Lfind_crlf
    test rax, rax
    jz .Lck_need_line
    cmp rax, r8
    je .Lck_done
    mov rcx, rax
    sub rcx, r10
    cmp rcx, HTTP_MAX_HEAD
    ja .Ltoolarge
    mov rsi, r8
1:  cmp rsi, rax
    jae .Lbad                           # trailer line without ':'
    cmp byte ptr [rsi], ':'
    je 2f
    inc rsi
    jmp 1b
2:  lea r8, [rax + 2]
    jmp .Lck_tr
.Lck_done:
    lea r14, [rax + 2]                  # end of the message
    mov [r13 + REQ_BODY_LEN], r9
    mov r8, [r13 + REQ_BODY]            # read cursor (wire)
    mov r10, r8                         # write cursor (decoded)
    lea r9, [rip + .Lhexval]
.Lck_copy:
    xor edx, edx
1:  movzx ecx, byte ptr [r8]
    movzx ecx, byte ptr [r9 + rcx]
    cmp ecx, 15
    ja 2f
    shl rdx, 4
    or rdx, rcx
    inc r8
    jmp 1b
2:  test rdx, rdx
    jz 3f
    mov rdi, r8
    call .Lfind_crlf
    lea rsi, [rax + 2]                  # data
    mov rdi, r10
    mov rcx, rdx
    rep movsb                           # forward copy, dst <= src
    mov r10, rdi
    lea r8, [rsi + 2]
    jmp .Lck_copy
3:  mov rax, r14
    sub rax, rbx
    jmp .Lret

# .Lfind_crlf: rdi = start, r12 = end -> rax = address of the '\r' of the first CRLF, or 0. Clobbers rdi.
.Lfind_crlf:
    lea rax, [r12 - 1]
1:  cmp rdi, rax
    jae 3f
    cmp byte ptr [rdi], 13
    jne 2f
    cmp byte ptr [rdi + 1], 10
    je 4f
2:  inc rdi
    jmp 1b
3:  xor eax, eax
    ret
4:  mov rax, rdi
    ret

# .Lutf8_scan: rdi = ptr, rsi = len -> rax = length of the valid UTF-8 prefix, rdx = 0 if all valid, else
# the length (1..3) of the maximal invalid subpart at rax (one U+FFFD each, as Rust's from_utf8_lossy).
# Preserves rdi, rsi; clobbers rcx, r8.
.Lutf8_scan:
    xor eax, eax
.Lu_loop:
    lea rcx, [rax + 8]
    cmp rcx, rsi
    ja .Lu_byte
    mov rcx, [rdi + rax]
    mov r8, 0x8080808080808080
    test rcx, r8
    jnz .Lu_byte
    add rax, 8
    jmp .Lu_loop
.Lu_byte:
    cmp rax, rsi
    jae .Lu_ok
    movzx ecx, byte ptr [rdi + rax]
    cmp ecx, 0x80
    jae .Lu_multi
    inc rax
    jmp .Lu_loop
.Lu_multi:
    cmp ecx, 0xc2
    jb .Lu_err1
    cmp ecx, 0xe0
    jb .Lu_2
    mov r8d, 0x80                       # second byte range [r8d, edx]
    mov edx, 0xbf
    cmp ecx, 0xf0
    jb .Lu_3
    cmp ecx, 0xf5
    jae .Lu_err1
    cmp ecx, 0xf0
    jne 1f
    mov r8d, 0x90
1:  cmp ecx, 0xf4
    jne 2f
    mov edx, 0x8f
2:  lea rcx, [rax + 1]
    cmp rcx, rsi
    jae .Lu_err1
    movzx ecx, byte ptr [rdi + rcx]
    cmp ecx, r8d
    jb .Lu_err1
    cmp ecx, edx
    ja .Lu_err1
    lea rcx, [rax + 2]
    cmp rcx, rsi
    jae .Lu_err2
    movzx ecx, byte ptr [rdi + rcx]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu_err2
    lea rcx, [rax + 3]
    cmp rcx, rsi
    jae .Lu_err3
    movzx ecx, byte ptr [rdi + rcx]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu_err3
    add rax, 4
    jmp .Lu_loop
.Lu_3:
    cmp ecx, 0xe0
    jne 1f
    mov r8d, 0xa0
1:  cmp ecx, 0xed
    jne 2f
    mov edx, 0x9f
2:  lea rcx, [rax + 1]
    cmp rcx, rsi
    jae .Lu_err1
    movzx ecx, byte ptr [rdi + rcx]
    cmp ecx, r8d
    jb .Lu_err1
    cmp ecx, edx
    ja .Lu_err1
    lea rcx, [rax + 2]
    cmp rcx, rsi
    jae .Lu_err2
    movzx ecx, byte ptr [rdi + rcx]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu_err2
    add rax, 3
    jmp .Lu_loop
.Lu_2:
    lea rcx, [rax + 1]
    cmp rcx, rsi
    jae .Lu_err1
    movzx ecx, byte ptr [rdi + rcx]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu_err1
    add rax, 2
    jmp .Lu_loop
.Lu_ok:
    mov rax, rsi
    xor edx, edx
    ret
.Lu_err1:
    mov edx, 1
    ret
.Lu_err2:
    mov edx, 2
    ret
.Lu_err3:
    mov edx, 3
    ret
.size http_parse, .-http_parse

# ------------------------------------------------------------------------------------------------ http_pct_decode
# http_pct_decode(src, len, dst, flags) -> outlen | -1
#   %XX (either case) -> byte. flags (PCT_* in defs.inc):
#   PCT_PLUS     '+' -> ' '                              (flags = 1 is the plus_is_space form)
#   PCT_LENIENT  a '%' not followed by two hex digits is copied as is (else -1)
#   PCT_UTF8     the decoded bytes must be valid UTF-8 (else -1)
#   PCT_LOSSY    invalid UTF-8 is replaced by U+FFFD per maximal subpart; dst must then hold 3 * len bytes
#   Rust equivalents: path segment = PCT_PATH (percent_decode_str + decode_utf8), query value = PCT_QUERY
#   (form_urlencoded). Without PCT_LOSSY, dst needs len bytes. dst may equal src (in-place decoding).
.globl http_pct_decode
.type http_pct_decode, @function
http_pct_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdx                        # dst
    mov r13, rcx                        # flags
    mov r14, rsi                        # len
    lea r9, [rdi + rsi]                 # src end
    mov r10, rdx                        # dst cursor
    lea r11, [rip + .Lhexval]
    movdqa xmm1, [rip + .Lc25]
    movdqa xmm2, xmm1
    test r13d, PCT_PLUS
    jz .Lpd_loop
    movdqa xmm2, [rip + .Lc2b]
.Lpd_loop:
    mov rax, r9
    sub rax, rdi
    cmp rax, 16
    jb .Lpd_one
    movdqu xmm0, [rdi]
    movdqa xmm3, xmm0
    pcmpeqb xmm3, xmm1
    movdqa xmm4, xmm0
    pcmpeqb xmm4, xmm2
    por xmm3, xmm4
    pmovmskb eax, xmm3
    test eax, eax
    jnz 1f
    movdqu [r10], xmm0                  # r10 <= rdi, so in place this only overwrites bytes already read
    add rdi, 16
    add r10, 16
    jmp .Lpd_loop
1:  bsf eax, eax                        # copy the plain bytes before the '%' / '+'
2:  test eax, eax
    jz .Lpd_one
    movzx edx, byte ptr [rdi]
    mov [r10], dl
    inc rdi
    inc r10
    dec eax
    jmp 2b
.Lpd_one:
    cmp rdi, r9
    jae .Lpd_done
    movzx eax, byte ptr [rdi]
    cmp al, '%'
    je .Lpd_pct
    cmp al, '+'
    jne .Lpd_lit
    test r13d, PCT_PLUS
    jz .Lpd_lit
    mov al, ' '
.Lpd_lit:
    mov [r10], al
    inc rdi
    inc r10
    jmp .Lpd_loop
.Lpd_pct:
    lea rcx, [rdi + 2]
    cmp rcx, r9
    jae .Lpd_badesc
    movzx ecx, byte ptr [rdi + 1]
    movzx ecx, byte ptr [r11 + rcx]
    cmp ecx, 15
    ja .Lpd_badesc
    movzx edx, byte ptr [rdi + 2]
    movzx edx, byte ptr [r11 + rdx]
    cmp edx, 15
    ja .Lpd_badesc
    shl ecx, 4
    or ecx, edx
    mov [r10], cl
    add rdi, 3
    inc r10
    jmp .Lpd_loop
.Lpd_badesc:
    test r13d, PCT_LENIENT
    jz .Lpd_fail
    jmp .Lpd_lit                        # al = '%'
.Lpd_done:
    mov rax, r10
    sub rax, r12
    test r13d, PCT_UTF8 | PCT_LOSSY
    jz .Lpd_ret
    mov r15, rax                        # n
    mov rdi, r12
    mov rsi, rax
    call .Lutf8_scan
    test edx, edx
    jz .Lpd_ok
    test r13d, PCT_LOSSY
    jz .Lpd_fail
    lea rbx, [r12 + 2 * r14]            # park the decoded bytes at dst + 2 * len (n <= len: no overlap)
    mov rdi, rbx
    mov rsi, r12
    mov rcx, r15
    rep movsb
    xor r13d, r13d                      # read index into rbx
    mov r10, r12                        # write cursor; never passes rbx + r13
.Lpd_lossy:
    lea rdi, [rbx + r13]
    mov rsi, r15
    sub rsi, r13
    call .Lutf8_scan
    mov rsi, rdi
    mov rdi, r10
    mov rcx, rax
    rep movsb
    mov r10, rdi
    add r13, rax
    test edx, edx
    jz .Lpd_lossy_end
    mov word ptr [r10], 0xbfef          # U+FFFD
    mov byte ptr [r10 + 2], 0xbd
    add r10, 3
    add r13, rdx
    jmp .Lpd_lossy
.Lpd_lossy_end:
    mov rax, r10
    sub rax, r12
    jmp .Lpd_ret
.Lpd_ok:
    mov rax, r15
    jmp .Lpd_ret
.Lpd_fail:
    mov rax, -1
.Lpd_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.size http_pct_decode, .-http_pct_decode

# ------------------------------------------------------------------------------------------------ http_query_get
# http_query_get(q, qlen, name, nlen) -> rax = raw value ptr (0 if absent), rdx = raw value length
#   form_urlencoded semantics as the Rust Query: pairs split on '&' (empty pairs skipped), key/value split at
#   the first '='; the key is compared after decoding ('+' -> ' ', %XX, a bad '%' stays literal); the first
#   matching pair wins. A pair without '=' has an empty value: rax = ptr just past the key (nonzero), rdx = 0.
#   Decode the value with http_pct_decode(..., PCT_QUERY).
.globl http_query_get
.type http_query_get, @function
http_query_get:
    push rbx
    push r12
    lea r8, [rdi + rsi]                 # end
    mov r9, rdi                         # pair start
    lea rbx, [rip + .Lhexval]
.Lqg_pair:
    cmp r9, r8
    jae .Lqg_none
    mov r10, r9                         # pair end ('&' or end)
1:  cmp r10, r8
    jae 2f
    cmp byte ptr [r10], '&'
    je 2f
    inc r10
    jmp 1b
2:  cmp r10, r9
    je .Lqg_next
    mov r11, r9                         # key end ('=' or pair end)
3:  cmp r11, r10
    jae 4f
    cmp byte ptr [r11], '='
    je 4f
    inc r11
    jmp 3b
4:  mov rsi, r9                         # decode-compare key with name
    xor edi, edi                        # name index
.Lqg_cmp:
    cmp rsi, r11
    jae .Lqg_keyend
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp al, '+'
    jne 5f
    mov al, ' '
    jmp 6f
5:  cmp al, '%'
    jne 6f
    lea r12, [rsi + 1]
    cmp r12, r11
    jae 6f                              # fewer than two bytes left in the key: literal '%'
    movzx r12d, byte ptr [rsi]
    movzx r12d, byte ptr [rbx + r12]
    cmp r12d, 15
    ja 6f
    movzx eax, byte ptr [rsi + 1]
    movzx eax, byte ptr [rbx + rax]
    cmp eax, 15
    ja 8f
    shl r12d, 4
    or eax, r12d
    add rsi, 2
    jmp 6f
8:  mov eax, '%'
6:  cmp rdi, rcx
    jae .Lqg_next
    cmp al, [rdx + rdi]
    jne .Lqg_next
    inc rdi
    jmp .Lqg_cmp
.Lqg_keyend:
    cmp rdi, rcx
    jne .Lqg_next
    cmp r11, r10
    je 9f
    lea rax, [r11 + 1]
    mov rdx, r10
    sub rdx, rax
    pop r12
    pop rbx
    ret
9:  mov rax, r10
    xor edx, edx
    pop r12
    pop rbx
    ret
.Lqg_next:
    lea r9, [r10 + 1]
    jmp .Lqg_pair
.Lqg_none:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    ret
.size http_query_get, .-http_query_get

# ------------------------------------------------------------------------------------------------ http_parse_uint
# http_parse_uint(ptr, len) -> rax = value, rdx = 1 ok / 0 bad (rax = 0)
#   As the Rust parse_uint: one or more ASCII digits, nothing else (no sign, no spaces), value <= 2^63 - 1.
#   Leading zeros are allowed and do not count against the limit ("000…0042" is 42).
.globl http_parse_uint
.type http_parse_uint, @function
http_parse_uint:
    xor eax, eax
    test rsi, rsi
    jz 2f
    lea r8, [rdi + rsi]
1:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 2f
    imul rax, rax, 10
    jo 2f
    add rax, rcx
    jo 2f
    inc rdi
    cmp rdi, r8
    jb 1b
    mov edx, 1
    ret
2:  xor eax, eax
    xor edx, edx
    ret
.size http_parse_uint, .-http_parse_uint

# ------------------------------------------------------------------------------------------------ http_write_head
# http_write_head(dst, status, content_len, flags) -> rax = dst past the head
#   "HTTP/1.1 <code> <reason>\r\nContent-Type: application/json\r\n" + "Content-Encoding: gzip\r\n" if
#   flags & HW_GZIP, + "Content-Length: N\r\n" + "Connection: close\r\n" if flags & HW_CLOSE, + "\r\n". 204 is the same minus Content-Length, matching
#   the Rust server byte for byte. Unknown codes 100..999 get the reason "Unknown"; others are sent as 500.
#   dst needs HTTP_HEAD_SPACE (160) writable bytes; the head itself is at most 151 bytes.
.globl http_write_head
.type http_write_head, @function
http_write_head:
    lea eax, [rsi - 100]
    cmp eax, 899
    ja .Lwh_500
    xor r9d, r9d                        # generic entry needs its digits patched
    cmp eax, 499
    ja .Lwh_generic
    lea r8, [rip + .Lst_idx]
    movzx eax, byte ptr [r8 + rax]
    test eax, eax
    jz .Lwh_generic
.Lwh_entry:
    shl eax, 7
    lea r8, [rip + .Lst_tab]
    add r8, rax
    movdqa xmm0, [r8]
    movdqa xmm1, [r8 + 16]
    movdqa xmm2, [r8 + 32]
    movdqa xmm3, [r8 + 48]
    movdqa xmm4, [r8 + 64]
    movdqa xmm5, [r8 + 80]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    movdqu [rdi + 32], xmm2
    movdqu [rdi + 48], xmm3
    movdqu [rdi + 64], xmm4
    movdqu [rdi + 80], xmm5
    test r9d, r9d
    jz 1f
    mov eax, esi                        # patch "000" with the code
    xor edx, edx
    mov r9d, 10
    div r9d
    add dl, '0'
    mov [rdi + 11], dl
    xor edx, edx
    div r9d
    add dl, '0'
    mov [rdi + 10], dl
    add al, '0'
    mov [rdi + 9], al
    mov rdx, r10
1:  mov eax, [r8 + 120]
    add rdi, rax
    test ecx, HW_GZIP
    jnz .Lwh_gzip
.Lwh_len:
    cmp byte ptr [r8 + 124], 0
    je .Lwh_nolen
    mov rax, rdx                        # Content-Length digits
    lea r10, [rip + .Lpow10]
    mov r9d, 1
2:  cmp r9d, 20
    jae 3f
    cmp rax, [r10 + r9 * 8]
    jb 3f
    inc r9d
    jmp 2b
3:  add rdi, r9
    mov r11, rdi
    mov r8, 0xcccccccccccccccd
4:  mov rsi, rax
    mul r8
    shr rdx, 3                          # q = v / 10
    lea rax, [rdx + rdx * 4]
    add rax, rax
    sub rsi, rax
    add sil, '0'
    dec r11
    mov [r11], sil
    mov rax, rdx
    test rax, rax
    jnz 4b
    test ecx, HW_CLOSE
    jnz 5f
    mov dword ptr [rdi], 0x0a0d0a0d
    lea rax, [rdi + 4]
    ret
5:  movdqu xmm0, [rip + .Lcrlf_close]
    movdqu xmm1, [rip + .Lcrlf_close + 16]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    lea rax, [rdi + 23]
    ret
.Lwh_nolen:                             # 204: the Content-Type line already ends in CRLF
    test ecx, HW_CLOSE
    jnz 6f
    mov word ptr [rdi], 0x0a0d
    lea rax, [rdi + 2]
    ret
6:  movdqu xmm0, [rip + .Lcrlf_close + 2]
    movdqu xmm1, [rip + .Lcrlf_close + 18]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    lea rax, [rdi + 21]
    ret
.Lwh_gzip:                              # "Content-Encoding: gzip\r\n" goes after Content-Type, as Rust
    movzx eax, byte ptr [r8 + 124]
    shl eax, 4                          # 16 = rewrite the "Content-Length: " the entry ends with
    sub rdi, rax
    movdqa xmm0, [rip + .Lce_gzip]
    movdqa xmm1, [rip + .Lce_gzip + 16]
    movdqa xmm2, [rip + .Lce_gzip + 32]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    movdqu [rdi + 32], xmm2
    lea rdi, [rdi + rax + 24]
    jmp .Lwh_len
.Lwh_generic:
    mov r10, rdx
    mov r9d, 1
    xor eax, eax
    jmp .Lwh_entry
.Lwh_500:
    mov esi, 500
    jmp http_write_head
.size http_write_head, .-http_write_head

# http_write_continue(dst) -> dst + 25: "HTTP/1.1 100 Continue\r\n\r\n" (send it when REQF_EXPECT is set,
# before the response, as the Rust server does). dst needs 32 writable bytes.
.globl http_write_continue
.type http_write_continue, @function
http_write_continue:
    movdqu xmm0, [rip + .Lcontinue]
    movdqu xmm1, [rip + .Lcontinue + 16]
    movdqu [rdi], xmm0
    movdqu [rdi + 16], xmm1
    lea rax, [rdi + 25]
    ret
.size http_write_continue, .-http_write_continue

# ------------------------------------------------------------------------------------------------ tables
.section .rodata
.balign 16
.Lc1f: .fill 16, 1, 0x1f
.Lc7f: .fill 16, 1, 0x7f
.Lc09: .fill 16, 1, 0x09
.Lc20: .fill 16, 1, 0x20
.Lcqm: .fill 16, 1, 0x3f
.Lc25: .fill 16, 1, 0x25
.Lc2b: .fill 16, 1, 0x2b
.Lcrlf_close: .ascii "\r\nConnection: close\r\n\r\n"
    .fill 16, 1, 0
.balign 16
.Lce_gzip: .ascii "Content-Encoding: gzip\r\nContent-Length: "
    .fill 8, 1, 0
.Lhttp1: .ascii "HTTP/1."
.Lcontinue: .ascii "HTTP/1.1 100 Continue\r\n\r\n"
    .fill 8, 1, 0
.balign 8
.Lpow10:
    .quad 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000
    .quad 10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000
    .quad 1000000000000000, 10000000000000000, 100000000000000000, 1000000000000000000
    .quad 10000000000000000000
# tchar (RFC 9110 token) map: 1 = allowed in a method or header name
.Ltchar:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x01,0x00,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x01,0x01,0x00,0x01,0x01,0x00
    .byte 0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01
    .byte 0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x01,0x01
    .byte 0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01
    .byte 0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x01,0x00,0x01,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
# hex digit value, 0xff = not a hex digit
.Lhexval:
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
# status code - 100 -> entry index in .Lst_tab (0 = generic entry, digits patched)
.Lst_idx:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x01,0x02,0x00,0x00,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x04,0x05,0x00,0x06,0x07,0x08,0x00,0x00,0x00,0x09,0x00,0x00,0x00,0x0a,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0b,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x0c,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x0d,0x00,0x00,0x0e,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
# 128-byte entries: head prefix (<= 96 bytes), .long length at +120, .byte has-length at +124
.balign 16
.Lst_tab:
    .ascii "HTTP/1.1 000 Unknown\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 50, 1, 0
    .long 70
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 55, 1, 0
    .long 65
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 50, 1, 0
    .long 70
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 204 No Content\r\nContent-Type: application/json\r\n"
    .fill 63, 1, 0
    .long 57
    .byte 0, 0, 0, 0
    .ascii "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 46, 1, 0
    .long 74
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 45, 1, 0
    .long 75
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 48, 1, 0
    .long 72
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 48, 1, 0
    .long 72
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 39, 1, 0
    .long 81
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 49, 1, 0
    .long 71
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 413 Payload Too Large\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 40, 1, 0
    .long 80
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 37, 1, 0
    .long 83
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 40, 1, 0
    .long 80
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 36, 1, 0
    .long 84
    .byte 1, 0, 0, 0
    .ascii "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: "
    .fill 38, 1, 0
    .long 82
    .byte 1, 0, 0, 0

.section .note.GNU-stack,"",@progbits
