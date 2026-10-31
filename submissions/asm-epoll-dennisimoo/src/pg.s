# pg.s: Postgres frontend/backend protocol v3.
#   pg_url_parse, pg_connect (blocking TCP + cleartext / SCRAM-SHA-256 auth), pg_exec_simple, pg_prepare,
#   pgw_* message writers (binary params incl. 1-D binary arrays), pgr_* readers, pgd_* decoders.
#
# Calling notes (no room in pgbuf, no hidden globals):
#   pgw_bind_begin(...) returns a handle (buffer offset of the 'B'); pass it to pgw_bind_end(buf, handle).
#   pg_prepare(fd, name, sql, len): name is NUL-terminated.
# Handles (bind and array) are offsets from PGB_PTR, so they survive the caller moving the buffer.
# pg_connect uses ~12.1 KB of stack, pg_exec_simple / pg_prepare ~8.3 KB.
.include "defs.inc"

.equ PG_EINVAL, 22
.equ PG_EACCES, 13
.equ PG_EPROTO, 71
.equ PG_ECONNRESET, 104
.equ MSG_NOSIGNAL, 0x4000
.equ MSG_MORE, 0x8000
.equ PG_IO_TIMEOUT, 5

# blocking reader state (internal)
.equ RD_FD, 0
.equ RD_BUF, 8
.equ RD_POS, 16
.equ RD_END, 24
.equ RD_CAP, 32
.equ RD_SKIP, 40
.equ RD_BUFSZ, 8192

# pg_connect frame
.equ CF_RD, 0                # 48 B reader
.equ CF_SA, 48               # sockaddr_in
.equ CF_ONE, 64
.equ CF_SNLEN, 72            # server nonce len
.equ CF_SNPTR, 80            # server nonce ptr (into the read buffer)
.equ CF_SALTLEN, 88
.equ CF_ITERS, 96
.equ CF_AUTHEND, 104         # AuthMessage write cursor
.equ CF_SBEND, 112           # send buffer write cursor
.equ CF_P, 120
.equ CF_NONCE, 128           # client nonce, 24 base64 chars
.equ CF_NRAW, 160            # 18 random bytes
.equ CF_SP, 192              # SaltedPassword
.equ CF_CK, 224              # ClientKey
.equ CF_SK, 256              # StoredKey
.equ CF_CS, 288              # ClientSignature
.equ CF_SVK, 320             # ServerKey
.equ CF_SVS, 352             # ServerSignature
.equ CF_PROOF, 384
.equ CF_TMP, 416             # 64 B
.equ CF_SALT, 480            # 128 B
.equ CF_AUTH, 1024           # AuthMessage, 1024 B
.equ CF_SBUF, 2048           # send buffer, 2048 B
.equ CF_RBUF, 4096           # read buffer, RD_BUFSZ
.equ CF_FRAME, 12296         # = 8 mod 16

.section .rodata
.Ls_user:     .ascii "user\0"
.Ls_database: .ascii "database\0"
.Ls_enc:      .ascii "client_encoding\0UTF8\0\0"
.Ls_scram:    .ascii "SCRAM-SHA-256\0"
.Ls_ckey:     .ascii "Client Key"
.Ls_skey:     .ascii "Server Key"
.Ls_pg:       .ascii "pg: "
.Ls_nl:       .ascii "\n"
.Ls_sp:       .ascii " "
.Ls_badauth:  .ascii "pg: unsupported authentication method\n"
.equ BADAUTH_LEN, 38
.Ls_badscram: .ascii "pg: SCRAM negotiation failed\n"
.equ BADSCRAM_LEN, 29

.text

# ================================================================ pg_url_parse(url, len, cfg) -> 0 | -1
.globl pg_url_parse
pg_url_parse:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                     # [rsp] authority end, [rsp+8] '@' / host end, [rsp+16] ':'
    mov rbx, rdx
    mov r12, rdi                    # cursor
    lea r13, [rdi + rsi]            # end
    lea r14, [rdx + PGC_BUF]        # decode cursor
    lea r15, [rdx + PGC_SIZE]       # decode limit
    xor eax, eax
    mov [rbx + PGC_USER], r14
    mov [rbx + PGC_USER_LEN], rax
    mov [rbx + PGC_PASS], r14
    mov [rbx + PGC_PASS_LEN], rax
    mov [rbx + PGC_HOST], rax
    mov [rbx + PGC_HOST_LEN], rax
    mov [rbx + PGC_DB], rax
    mov [rbx + PGC_DB_LEN], rax
    mov qword ptr [rbx + PGC_PORT], 5432
    mov [rbx + PGC_ADDR], rax
    # scheme: postgres:// or postgresql://
    cmp rsi, 11
    jb .Lup_fail
    mov rax, 0x7365726774736f70     # "postgres"
    cmp rax, [rdi]
    jne .Lup_fail
    add r12, 8
    mov rcx, r13
    sub rcx, r12
    cmp rcx, 5
    jb 1f
    cmp dword ptr [r12], 0x2f3a6c71 # "ql:/"
    jne 1f
    cmp byte ptr [r12 + 4], 0x2f
    jne 1f
    add r12, 5
    jmp 2f
1:  cmp word ptr [r12], 0x2f3a      # ":/" (rcx >= 3 since len >= 11)
    jne .Lup_fail
    cmp byte ptr [r12 + 2], 0x2f
    jne .Lup_fail
    add r12, 3
2:  # authority ends at the first '/' or '?'
    mov rdi, r12
3:  cmp rdi, r13
    jae 4f
    movzx eax, byte ptr [rdi]
    cmp al, 0x2f
    je 4f
    cmp al, 0x3f
    je 4f
    inc rdi
    jmp 3b
4:  mov [rsp], rdi
    # last '@' in the authority splits userinfo from host
5:  cmp rdi, r12
    jbe .Lup_host
    dec rdi
    cmp byte ptr [rdi], 0x40
    jne 5b
    mov [rsp + 8], rdi
    mov rsi, r12                    # first ':' in userinfo splits user / password
6:  cmp rsi, rdi
    jae 7f
    cmp byte ptr [rsi], 0x3a
    je 7f
    inc rsi
    jmp 6b
7:  mov [rsp + 16], rsi
    mov rdi, r12
    sub rsi, r12
    call .Lpct
    test rax, rax
    js .Lup_fail
    mov [rbx + PGC_USER], rdx
    mov [rbx + PGC_USER_LEN], rax
    mov [rbx + PGC_PASS], r14
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 8]
    cmp rdi, rsi
    jae 8f
    inc rdi
    sub rsi, rdi
    call .Lpct
    test rax, rax
    js .Lup_fail
    mov [rbx + PGC_PASS], rdx
    mov [rbx + PGC_PASS_LEN], rax
8:  mov r12, [rsp + 8]
    inc r12
.Lup_host:                          # host[:port] = [r12, aend)
    mov r8, [rsp]
    mov rdi, r8
9:  cmp rdi, r12
    jbe .Lup_noport
    dec rdi
    cmp byte ptr [rdi], 0x3a
    jne 9b
    mov [rsp + 8], rdi
    lea rsi, [rdi + 1]
    mov rcx, r8
    sub rcx, rsi
    jz .Lup_fail
    cmp rcx, 5
    ja .Lup_fail
    xor eax, eax
10: movzx edx, byte ptr [rsi]
    sub edx, 0x30
    cmp edx, 9
    ja .Lup_fail
    imul eax, eax, 10
    add eax, edx
    inc rsi
    cmp rsi, r8
    jb 10b
    test eax, eax
    jz .Lup_fail
    cmp eax, 65535
    ja .Lup_fail
    mov [rbx + PGC_PORT], rax
    jmp 11f
.Lup_noport:
    mov [rsp + 8], r8
11: mov rsi, [rsp + 8]
    sub rsi, r12
    jz .Lup_fail
    mov [rbx + PGC_HOST], r12
    mov [rbx + PGC_HOST_LEN], rsi
    cmp rsi, 9
    jne 12f
    mov rax, 0x736f686c61636f6c     # "localhos"
    cmp rax, [r12]
    jne 12f
    cmp byte ptr [r12 + 8], 0x74    # 't'
    jne 12f
    mov dword ptr [rbx + PGC_ADDR], 0x0100007f
    jmp 13f
12: mov rdi, r12
    call .Lipv4
    test edx, edx
    jz .Lup_fail
    mov [rbx + PGC_ADDR], eax
13: # "/db" up to '?' (default: user name)
    mov rdi, [rsp]
    cmp rdi, r13
    jae .Lup_dbdef
    cmp byte ptr [rdi], 0x2f
    jne .Lup_dbdef
    inc rdi
    mov rsi, rdi
14: cmp rsi, r13
    jae 15f
    cmp byte ptr [rsi], 0x3f
    je 15f
    inc rsi
    jmp 14b
15: sub rsi, rdi
    jz .Lup_dbdef
    call .Lpct
    test rax, rax
    js .Lup_fail
    mov [rbx + PGC_DB], rdx
    mov [rbx + PGC_DB_LEN], rax
    jmp .Lup_ok
.Lup_dbdef:
    mov rax, [rbx + PGC_USER]
    mov [rbx + PGC_DB], rax
    mov rax, [rbx + PGC_USER_LEN]
    mov [rbx + PGC_DB_LEN], rax
.Lup_ok:
    xor eax, eax
    jmp .Lup_ret
.Lup_fail:
    mov rax, -1
.Lup_ret:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# .Lpct(rdi = src, rsi = len): percent-decode to [r14, r15), advancing r14.
# -> rax = decoded len | -1, rdx = start. Clobbers rcx, rdi, r9.
.Lpct:
    mov rdx, r14
    lea r9, [rdi + rsi]
1:  cmp rdi, r9
    jae 3f
    cmp r14, r15
    jae 9f
    movzx eax, byte ptr [rdi]
    cmp al, 0x25                    # '%'
    jne 2f
    lea rcx, [rdi + 3]
    cmp rcx, r9
    ja 9f
    movzx eax, byte ptr [rdi + 1]
    mov ecx, eax
    sub ecx, 0x30
    cmp ecx, 9
    jbe 4f
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 0x61
    cmp ecx, 5
    ja 9f
    add ecx, 10
4:  shl ecx, 4
    movzx eax, byte ptr [rdi + 2]
    mov esi, eax
    sub esi, 0x30
    cmp esi, 9
    jbe 5f
    mov esi, eax
    or esi, 0x20
    sub esi, 0x61
    cmp esi, 5
    ja 9f
    add esi, 10
5:  or ecx, esi
    mov [r14], cl
    inc r14
    add rdi, 3
    jmp 1b
2:  mov [r14], al
    inc r14
    inc rdi
    jmp 1b
3:  mov rax, r14
    sub rax, rdx
    ret
9:  mov rax, -1
    ret

# .Lipv4(rdi = ptr, rsi = len) -> eax = address (network byte order), edx = 1 ok | 0 bad
.Lipv4:
    lea r9, [rdi + rsi]
    xor r10d, r10d
    xor r11d, r11d
1:  xor eax, eax
    xor ecx, ecx
2:  cmp rdi, r9
    jae 3f
    movzx edx, byte ptr [rdi]
    sub edx, 0x30
    cmp edx, 9
    ja 3f
    imul eax, eax, 10
    add eax, edx
    inc rdi
    inc ecx
    cmp ecx, 3
    ja 9f
    jmp 2b
3:  test ecx, ecx
    jz 9f
    cmp eax, 255
    ja 9f
    mov ecx, r11d
    shl ecx, 3
    shl eax, cl
    or r10d, eax
    inc r11d
    cmp r11d, 4
    je 4f
    cmp rdi, r9
    jae 9f
    cmp byte ptr [rdi], 0x2e
    jne 9f
    inc rdi
    jmp 1b
4:  cmp rdi, r9
    jne 9f
    mov eax, r10d
    mov edx, 1
    ret
9:  xor eax, eax
    xor edx, edx
    ret

# ================================================================ blocking I/O helpers
# .Lsend(rdi = fd, rsi = ptr, rdx = len, rcx = extra send flags) -> rax = 0 | -errno
.Lsend:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    or r14d, MSG_NOSIGNAL
1:  test r13, r13
    jz 2f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    mov r10d, r14d
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_sendto
    syscall
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 3f
    add r12, rax
    sub r13, rax
    jmp 1b
2:  xor eax, eax
3:  pop r14
    pop r13
    pop r12
    pop rbx
    ret

# .Lrd_next(rdi = reader) -> rax = message ptr (valid until the next call) | -errno, rdx = total length.
# Messages larger than the buffer are skipped.
.Lrd_next:
    push rbx
    mov rbx, rdi
.Lrdn_loop:
    mov rax, [rbx + RD_POS]
    mov rcx, [rbx + RD_END]
    sub rcx, rax                    # available
    cmp rcx, 5
    jb .Lrdn_fill
    add rax, [rbx + RD_BUF]
    mov edx, [rax + 1]
    bswap edx
    cmp edx, 4
    jb .Lrdn_proto
    inc rdx
    cmp rdx, rcx
    ja .Lrdn_partial
    add [rbx + RD_POS], rdx
    pop rbx
    ret
.Lrdn_partial:
    cmp rdx, [rbx + RD_CAP]
    jbe .Lrdn_fill
    sub rdx, rcx                    # oversized: drop it
    mov [rbx + RD_SKIP], rdx
    xor eax, eax
    mov [rbx + RD_POS], rax
    mov [rbx + RD_END], rax
.Lrdn_skip:
    mov rdi, [rbx + RD_FD]
    mov rsi, [rbx + RD_BUF]
    mov rdx, [rbx + RD_CAP]
    mov eax, SYS_read
    syscall
    cmp rax, -EINTR
    je .Lrdn_skip
    test rax, rax
    jz .Lrdn_eof
    js .Lrdn_ret
    mov rcx, [rbx + RD_SKIP]
    cmp rax, rcx
    ja 1f
    sub [rbx + RD_SKIP], rax
    jnz .Lrdn_skip
    jmp .Lrdn_loop
1:  mov [rbx + RD_POS], rcx
    mov [rbx + RD_END], rax
    mov qword ptr [rbx + RD_SKIP], 0
    jmp .Lrdn_loop
.Lrdn_fill:
    mov rsi, [rbx + RD_POS]
    test rsi, rsi
    jz 2f
    mov rdi, [rbx + RD_BUF]
    mov rcx, [rbx + RD_END]
    sub rcx, rsi
    mov [rbx + RD_END], rcx
    mov qword ptr [rbx + RD_POS], 0
    add rsi, rdi
    rep movsb                       # compact (dst < src: forward copy is safe)
2:  mov rdi, [rbx + RD_FD]
    mov rsi, [rbx + RD_BUF]
    mov rdx, [rbx + RD_CAP]
    mov rax, [rbx + RD_END]
    add rsi, rax
    sub rdx, rax
    mov eax, SYS_read
    syscall
    cmp rax, -EINTR
    je 2b
    test rax, rax
    jz .Lrdn_eof
    js .Lrdn_ret
    add [rbx + RD_END], rax
    jmp .Lrdn_loop
.Lrdn_eof:
    mov rax, -PG_ECONNRESET
    jmp .Lrdn_ret
.Lrdn_proto:
    mov rax, -PG_EPROTO
.Lrdn_ret:
    pop rbx
    ret

# .Lerr_field(rdi = ErrorResponse/NoticeResponse msg, esi = field code) -> rax = value ptr | 0, rdx = len
.Lerr_field:
    mov ecx, [rdi + 1]
    bswap ecx
    lea r8, [rdi + rcx + 1]
    add rdi, 5
1:  cmp rdi, r8
    jae 9f
    movzx eax, byte ptr [rdi]
    test eax, eax
    jz 9f
    inc rdi
    mov r9, rdi
2:  cmp rdi, r8
    jae 9f
    cmp byte ptr [rdi], 0
    je 3f
    inc rdi
    jmp 2b
3:  cmp eax, esi
    je 4f
    inc rdi
    jmp 1b
4:  mov rax, r9
    mov rdx, rdi
    sub rdx, r9
    ret
9:  xor eax, eax
    xor edx, edx
    ret

# .Lwrite2(rsi = ptr, rdx = len): write to stderr, ignore errors
.Lwrite2:
    mov edi, 2
    mov eax, SYS_write
    syscall
    ret

# .Lprint_error(rdi = ErrorResponse msg): "pg: <SQLSTATE> <message>\n" to stderr
.Lprint_error:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + .Ls_pg]
    mov edx, 4
    call .Lwrite2
    mov rdi, rbx
    mov esi, 0x43                   # 'C'
    call .Lerr_field
    test rax, rax
    jz 1f
    mov rsi, rax
    call .Lwrite2
    lea rsi, [rip + .Ls_sp]
    mov edx, 1
    call .Lwrite2
1:  mov rdi, rbx
    mov esi, 0x4d                   # 'M'
    call .Lerr_field
    test rax, rax
    jz 2f
    mov rsi, rax
    call .Lwrite2
2:  lea rsi, [rip + .Ls_nl]
    mov edx, 1
    call .Lwrite2
    pop rbx
    ret

# .Ldrain(rdi = fd) -> 0 | -1: read until ReadyForQuery; -1 if an ErrorResponse (printed) or I/O error
.Ldrain:
    push rbx
    push r12
    sub rsp, 8248
    mov [rsp + RD_FD], rdi
    lea rax, [rsp + 48]
    mov [rsp + RD_BUF], rax
    xor eax, eax
    mov [rsp + RD_POS], rax
    mov [rsp + RD_END], rax
    mov [rsp + RD_SKIP], rax
    mov qword ptr [rsp + RD_CAP], RD_BUFSZ
    xor r12d, r12d
1:  mov rdi, rsp
    call .Lrd_next
    test rax, rax
    js 9f
    movzx ecx, byte ptr [rax]
    cmp ecx, 0x5a                   # 'Z'
    je 2f
    cmp ecx, 0x45                   # 'E'
    jne 1b
    mov rdi, rax
    call .Lprint_error
    or r12, -1
    jmp 1b
2:  mov rax, r12
3:  add rsp, 8248
    pop r12
    pop rbx
    ret
9:  mov rax, -1
    jmp 3b

# ================================================================ pg_connect(cfg) -> fd | -errno
.globl pg_connect
pg_connect:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, CF_FRAME
    mov rbx, rdi
    xor r15d, r15d                  # SCRAM state: 0 none, 1 first sent, 2 final sent, 3 server verified
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test rax, rax
    js .Lpc_ret
    mov r12, rax
    # the handshake and the prepares block: give up after PG_IO_TIMEOUT s rather than hang a worker (the send
    # timeout also bounds connect)
    mov qword ptr [rsp + CF_SA], PG_IO_TIMEOUT    # timeval {sec, usec}
    mov qword ptr [rsp + CF_SA + 8], 0
    mov rdi, r12
    mov esi, SOL_SOCKET
    mov edx, SO_RCVTIMEO
    lea r10, [rsp + CF_SA]
    mov r8d, 16
    mov eax, SYS_setsockopt
    syscall
    mov rdi, r12
    mov esi, SOL_SOCKET
    mov edx, SO_SNDTIMEO
    lea r10, [rsp + CF_SA]
    mov r8d, 16
    mov eax, SYS_setsockopt
    syscall
    mov word ptr [rsp + CF_SA], AF_INET
    mov eax, [rbx + PGC_PORT]
    xchg al, ah
    mov [rsp + CF_SA + 2], ax
    mov eax, [rbx + PGC_ADDR]
    mov [rsp + CF_SA + 4], eax
    mov qword ptr [rsp + CF_SA + 8], 0
1:  mov rdi, r12
    lea rsi, [rsp + CF_SA]
    mov edx, 16
    mov eax, SYS_connect
    syscall
    test rax, rax
    js .Lpc_fail
    mov dword ptr [rsp + CF_ONE], 1
    mov rdi, r12
    mov esi, IPPROTO_TCP
    mov edx, TCP_NODELAY
    lea r10, [rsp + CF_ONE]
    mov r8d, 4
    mov eax, SYS_setsockopt
    syscall
    test rax, rax
    js .Lpc_fail
    mov [rsp + CF_RD + RD_FD], r12
    lea rax, [rsp + CF_RBUF]
    mov [rsp + CF_RD + RD_BUF], rax
    xor eax, eax
    mov [rsp + CF_RD + RD_POS], rax
    mov [rsp + CF_RD + RD_END], rax
    mov [rsp + CF_RD + RD_SKIP], rax
    mov qword ptr [rsp + CF_RD + RD_CAP], RD_BUFSZ
    # StartupMessage: len, 3.0, user, database, client_encoding
    lea rdi, [rsp + CF_SBUF + 8]
    lea rsi, [rip + .Ls_user]
    mov ecx, 5
    rep movsb
    mov rsi, [rbx + PGC_USER]
    mov rcx, [rbx + PGC_USER_LEN]
    rep movsb
    mov byte ptr [rdi], 0
    inc rdi
    lea rsi, [rip + .Ls_database]
    mov ecx, 9
    rep movsb
    mov rsi, [rbx + PGC_DB]
    mov rcx, [rbx + PGC_DB_LEN]
    rep movsb
    mov byte ptr [rdi], 0
    inc rdi
    lea rsi, [rip + .Ls_enc]
    mov ecx, 22
    rep movsb
    lea rsi, [rsp + CF_SBUF]
    mov rdx, rdi
    sub rdx, rsi
    mov eax, edx
    bswap eax
    mov [rsi], eax
    mov dword ptr [rsi + 4], 0x00000300   # protocol 3.0
    mov rdi, r12
    xor ecx, ecx
    call .Lsend
    test rax, rax
    js .Lpc_fail

.Lpc_auth:
    lea rdi, [rsp + CF_RD]
    call .Lrd_next
    test rax, rax
    js .Lpc_fail
    mov r13, rax                    # message
    mov r14, rdx                    # total length
    movzx ecx, byte ptr [r13]
    cmp ecx, 0x52                   # 'R'
    je .Lpc_R
    cmp ecx, 0x45                   # 'E'
    je .Lpc_err
    jmp .Lpc_auth
.Lpc_R:
    cmp r14, 9
    jb .Lpc_proto
    mov eax, [r13 + 5]
    bswap eax
    test eax, eax
    jz .Lpc_authok
    cmp eax, 3
    je .Lpc_clear
    cmp eax, 10
    je .Lpc_sasl
    cmp eax, 11
    je .Lpc_cont
    cmp eax, 12
    je .Lpc_final
    lea rsi, [rip + .Ls_badauth]
    mov edx, BADAUTH_LEN
    call .Lwrite2
    mov rax, -PG_EPROTO
    jmp .Lpc_fail

.Lpc_clear:                         # PasswordMessage
    mov byte ptr [rsp + CF_SBUF], 0x70
    lea rdi, [rsp + CF_SBUF + 5]
    mov rsi, [rbx + PGC_PASS]
    mov rcx, [rbx + PGC_PASS_LEN]
    rep movsb
    mov byte ptr [rdi], 0
    inc rdi
    jmp .Lpc_send_p

.Lpc_sasl:                          # AuthenticationSASL: mechanism list must contain SCRAM-SHA-256
    test r15d, r15d
    jnz .Lpc_proto
    lea rbp, [r13 + 9]
    lea r14, [r13 + r14]            # end
2:  cmp rbp, r14
    jae .Lpc_badscram
    cmp byte ptr [rbp], 0
    je .Lpc_badscram
    lea rax, [rbp + 14]
    cmp rax, r14
    ja 4f
    mov rax, [rip + .Ls_scram]
    cmp rax, [rbp]
    jne 4f
    mov eax, [rip + .Ls_scram + 8]
    cmp eax, [rbp + 8]
    jne 4f
    movzx eax, word ptr [rip + .Ls_scram + 12]
    movzx ecx, word ptr [rbp + 12]
    cmp eax, ecx
    je 5f
4:  cmp rbp, r14                    # skip this name
    jae .Lpc_badscram
    inc rbp
    cmp byte ptr [rbp - 1], 0
    jne 4b
    jmp 2b
5:  mov r15d, 1
    lea rdi, [rsp + CF_NRAW]
    mov esi, 18
    call crypto_random
    test rax, rax
    js .Lpc_fail
    lea rdi, [rsp + CF_NRAW]
    mov esi, 18
    lea rdx, [rsp + CF_NONCE]
    call crypto_b64_encode          # 24 chars
    # AuthMessage starts with client-first-bare "n=,r=<nonce>" + ","
    lea rdi, [rsp + CF_AUTH]
    mov dword ptr [rdi], 0x722c3d6e # "n=,r"
    mov byte ptr [rdi + 4], 0x3d
    add rdi, 5
    lea rsi, [rsp + CF_NONCE]
    mov ecx, 24
    rep movsb
    mov byte ptr [rdi], 0x2c
    inc rdi
    mov [rsp + CF_AUTHEND], rdi
    # SASLInitialResponse: 'p' len "SCRAM-SHA-256\0" int4(32) "n,,n=,r=<nonce>"
    mov byte ptr [rsp + CF_SBUF], 0x70
    lea rdi, [rsp + CF_SBUF + 5]
    lea rsi, [rip + .Ls_scram]
    mov ecx, 14
    rep movsb
    mov dword ptr [rdi], 0x20000000 # 32 BE
    mov rax, 0x3d722c3d6e2c2c6e     # "n,,n=,r="
    mov [rdi + 4], rax
    add rdi, 12
    lea rsi, [rsp + CF_NONCE]
    mov ecx, 24
    rep movsb
    jmp .Lpc_send_p

.Lpc_cont:                          # AuthenticationSASLContinue: server-first-message
    cmp r15d, 1
    jne .Lpc_proto
    lea rbp, [r13 + 9]
    lea rcx, [r14 - 9]
    cmp rcx, 480
    ja .Lpc_badscram
    mov rdi, [rsp + CF_AUTHEND]
    mov rsi, rbp
    rep movsb
    mov byte ptr [rdi], 0x2c
    inc rdi
    mov [rsp + CF_AUTHEND], rdi
    lea r14, [r13 + r14]            # end of data
    # r=<client nonce><server part>
    lea rax, [rbp + 2]
    cmp rax, r14
    ja .Lpc_badscram
    cmp word ptr [rbp], 0x3d72      # "r="
    jne .Lpc_badscram
    add rbp, 2
    mov [rsp + CF_SNPTR], rbp
    mov rdi, rbp
    call .Lscan_comma
    mov rcx, rax
    sub rcx, rbp
    mov [rsp + CF_SNLEN], rcx
    cmp rcx, 24
    jbe .Lpc_badscram
    movdqu xmm0, [rbp]
    movdqu xmm1, [rsp + CF_NONCE]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
    cmp ecx, 0xffff
    jne .Lpc_badscram
    mov rcx, [rbp + 16]
    cmp rcx, [rsp + CF_NONCE + 16]
    jne .Lpc_badscram
    lea rbp, [rax + 1]
    # s=<base64 salt>
    lea rax, [rbp + 2]
    cmp rax, r14
    ja .Lpc_badscram
    cmp word ptr [rbp], 0x3d73      # "s="
    jne .Lpc_badscram
    add rbp, 2
    mov rdi, rbp
    call .Lscan_comma
    mov [rsp + CF_P], rax
    mov rsi, rax
    sub rsi, rbp
    jz .Lpc_badscram
    cmp rsi, 128
    ja .Lpc_badscram
    mov rdi, rbp
    lea rdx, [rsp + CF_SALT]
    call crypto_b64_decode
    test rax, rax
    jle .Lpc_badscram
    mov [rsp + CF_SALTLEN], rax
    mov rbp, [rsp + CF_P]
    inc rbp
    # i=<iterations>
    lea rax, [rbp + 2]
    cmp rax, r14
    ja .Lpc_badscram
    cmp word ptr [rbp], 0x3d69      # "i="
    jne .Lpc_badscram
    add rbp, 2
    mov rdi, rbp
    call .Lscan_comma
    mov rcx, rax
    sub rcx, rbp
    jz .Lpc_badscram
    cmp rcx, 8
    ja .Lpc_badscram
    xor eax, eax
6:  movzx edx, byte ptr [rbp]
    sub edx, 0x30
    cmp edx, 9
    ja .Lpc_badscram
    imul eax, eax, 10
    add eax, edx
    inc rbp
    dec rcx
    jnz 6b
    test eax, eax
    jz .Lpc_badscram
    mov [rsp + CF_ITERS], rax
    # client-final-message-without-proof "c=biws,r=<nonce>" into the send buffer and the AuthMessage
    mov byte ptr [rsp + CF_SBUF], 0x70
    lea rdi, [rsp + CF_SBUF + 5]
    mov rax, 0x722c737769623d63     # "c=biws,r"
    mov [rdi], rax
    mov byte ptr [rdi + 8], 0x3d
    add rdi, 9
    mov rsi, [rsp + CF_SNPTR]
    mov rcx, [rsp + CF_SNLEN]
    rep movsb
    mov [rsp + CF_SBEND], rdi
    lea rsi, [rsp + CF_SBUF + 5]
    mov rcx, rdi
    sub rcx, rsi
    mov rdi, [rsp + CF_AUTHEND]
    rep movsb
    mov [rsp + CF_AUTHEND], rdi
    # SaltedPassword = PBKDF2(password, salt, i)
    mov rdi, [rbx + PGC_PASS]
    mov rsi, [rbx + PGC_PASS_LEN]
    lea rdx, [rsp + CF_SALT]
    mov rcx, [rsp + CF_SALTLEN]
    mov r8, [rsp + CF_ITERS]
    lea r9, [rsp + CF_SP]
    call crypto_pbkdf2
    lea rdi, [rsp + CF_SP]          # ClientKey
    mov esi, 32
    lea rdx, [rip + .Ls_ckey]
    mov ecx, 10
    lea r8, [rsp + CF_CK]
    call crypto_hmac
    lea rdi, [rsp + CF_CK]          # StoredKey
    mov esi, 32
    lea rdx, [rsp + CF_SK]
    call crypto_sha256
    mov r14, [rsp + CF_AUTHEND]
    lea rax, [rsp + CF_AUTH]
    sub r14, rax                    # AuthMessage length
    lea rdi, [rsp + CF_SK]          # ClientSignature
    mov esi, 32
    lea rdx, [rsp + CF_AUTH]
    mov rcx, r14
    lea r8, [rsp + CF_CS]
    call crypto_hmac
    lea rdi, [rsp + CF_SP]          # ServerKey
    mov esi, 32
    lea rdx, [rip + .Ls_skey]
    mov ecx, 10
    lea r8, [rsp + CF_SVK]
    call crypto_hmac
    lea rdi, [rsp + CF_SVK]         # ServerSignature
    mov esi, 32
    lea rdx, [rsp + CF_AUTH]
    mov rcx, r14
    lea r8, [rsp + CF_SVS]
    call crypto_hmac
    movdqu xmm0, [rsp + CF_CK]      # ClientProof = ClientKey ^ ClientSignature
    movdqu xmm1, [rsp + CF_CS]
    pxor xmm0, xmm1
    movdqu [rsp + CF_PROOF], xmm0
    movdqu xmm0, [rsp + CF_CK + 16]
    movdqu xmm1, [rsp + CF_CS + 16]
    pxor xmm0, xmm1
    movdqu [rsp + CF_PROOF + 16], xmm0
    mov rdi, [rsp + CF_SBEND]
    mov word ptr [rdi], 0x702c      # ",p="
    mov byte ptr [rdi + 2], 0x3d
    add rdi, 3
    mov [rsp + CF_SBEND], rdi
    mov rdx, rdi
    lea rdi, [rsp + CF_PROOF]
    mov esi, 32
    call crypto_b64_encode          # 44 chars
    mov rdi, [rsp + CF_SBEND]
    add rdi, rax
    mov r15d, 2
    jmp .Lpc_send_p

.Lpc_final:                         # AuthenticationSASLFinal: "v=<base64 ServerSignature>"
    cmp r15d, 2
    jne .Lpc_badscram
    lea rbp, [r13 + 9]
    lea rcx, [r14 - 9]
    cmp rcx, 46
    jb .Lpc_badscram
    je 7f
    cmp byte ptr [rbp + 46], 0x2c
    jne .Lpc_badscram
7:  cmp word ptr [rbp], 0x3d76      # "v="
    jne .Lpc_badscram
    lea rdi, [rsp + CF_SVS]
    mov esi, 32
    lea rdx, [rsp + CF_TMP]
    call crypto_b64_encode
    xor eax, eax
    xor ecx, ecx
8:  movzx edx, byte ptr [rsp + CF_TMP + rcx]
    xor dl, [rbp + 2 + rcx]
    or eax, edx
    inc ecx
    cmp ecx, 44
    jb 8b
    test eax, eax
    jnz .Lpc_badscram
    mov r15d, 3
    jmp .Lpc_auth

.Lpc_send_p:                        # finish the 'p' message in CF_SBUF ending at rdi, send it
    lea rsi, [rsp + CF_SBUF]
    mov rdx, rdi
    sub rdx, rsi
    lea eax, [rdx - 1]
    bswap eax
    mov [rsi + 1], eax
    mov rdi, r12
    xor ecx, ecx
    call .Lsend
    test rax, rax
    js .Lpc_fail
    jmp .Lpc_auth

.Lpc_authok:
    test r15d, r15d                 # SCRAM started: the server must have proven itself
    jz .Lpc_ready
    cmp r15d, 3
    jne .Lpc_badscram
.Lpc_ready:
    lea rdi, [rsp + CF_RD]
    call .Lrd_next
    test rax, rax
    js .Lpc_fail
    mov r13, rax
    movzx ecx, byte ptr [r13]
    cmp ecx, 0x5a                   # 'Z'
    je .Lpc_done
    cmp ecx, 0x45                   # 'E'
    je .Lpc_err
    jmp .Lpc_ready
.Lpc_done:
    mov rax, r12
    jmp .Lpc_ret
.Lpc_err:
    mov rdi, r13
    call .Lprint_error
    mov rax, -PG_EACCES
    jmp .Lpc_fail
.Lpc_badscram:
    lea rsi, [rip + .Ls_badscram]
    mov edx, BADSCRAM_LEN
    call .Lwrite2
    mov rax, -PG_EACCES
    jmp .Lpc_fail
.Lpc_proto:
    mov rax, -PG_EPROTO
.Lpc_fail:
    mov rbp, rax
    mov rdi, r12
    mov eax, SYS_close
    syscall
    mov rax, rbp
.Lpc_ret:
    add rsp, CF_FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# .Lscan_comma(rdi = ptr, r14 = end) -> rax = first ',' or end
.Lscan_comma:
    mov rax, rdi
1:  cmp rax, r14
    jae 2f
    cmp byte ptr [rax], 0x2c
    je 2f
    inc rax
    jmp 1b
2:  ret
    .skip 48, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# ================================================================ pg_exec_simple(fd, sql, len) -> 0 | -1
.globl pg_exec_simple
pg_exec_simple:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov byte ptr [rsp], 0x51        # 'Q'
    lea eax, [r13 + 5]
    bswap eax
    mov [rsp + 1], eax
    mov byte ptr [rsp + 8], 0
    mov edi, ebx
    mov rsi, rsp
    mov edx, 5
    mov ecx, MSG_MORE
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    mov ecx, MSG_MORE
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    lea rsi, [rsp + 8]
    mov edx, 1
    xor ecx, ecx
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    call .Ldrain
1:  add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret
9:  mov rax, -1
    jmp 1b

# ================================================================ pg_prepare(fd, name\0, sql, len) -> 0 | -1
.globl pg_prepare
pg_prepare:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor r15d, r15d
1:  cmp byte ptr [r12 + r15], 0
    je 2f
    inc r15
    jmp 1b
2:  inc r15                         # name length incl. NUL
    mov byte ptr [rsp], 0x50        # 'P'
    lea rax, [r15 + r14 + 7]        # 4 + name\0 + sql + \0 + int16 0
    bswap eax
    mov [rsp + 1], eax
    mov rax, 0x0400000053000000     # sql \0, int16 0 param types, Sync
    mov [rsp + 8], rax
    mov edi, ebx
    mov rsi, rsp
    mov edx, 5
    mov ecx, MSG_MORE
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r15
    mov ecx, MSG_MORE
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    mov rsi, r13
    mov rdx, r14
    mov ecx, MSG_MORE
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    lea rsi, [rsp + 8]
    mov edx, 8
    xor ecx, ecx
    call .Lsend
    test rax, rax
    js 9f
    mov edi, ebx
    call .Ldrain
3:  add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
9:  mov rax, -1
    jmp 3b

# ================================================================ message writers
# .Lmemcpy(rdi = dst, rsi = src, rdx = len): never touches bytes outside [src, src+len).
# Clobbers rax, rcx, rdx, rsi, rdi, r8, xmm0, xmm1.
.Lmemcpy:
    cmp rdx, 16
    jb 3f
    cmp rdx, 256
    jae 2f
    movdqu xmm1, [rsi + rdx - 16]
    lea r8, [rdi + rdx - 16]
1:  movdqu xmm0, [rsi]
    movdqu [rdi], xmm0
    add rsi, 16
    add rdi, 16
    sub rdx, 16
    cmp rdx, 16
    ja 1b
    movdqu [r8], xmm1
    ret
2:  mov rcx, rdx
    rep movsb
    ret
3:  cmp edx, 8
    jb 4f
    mov rax, [rsi]
    mov rcx, [rsi + rdx - 8]
    mov [rdi], rax
    mov [rdi + rdx - 8], rcx
    ret
4:  cmp edx, 4
    jb 5f
    mov eax, [rsi]
    mov ecx, [rsi + rdx - 4]
    mov [rdi], eax
    mov [rdi + rdx - 4], ecx
    ret
5:  test edx, edx
    jz 6f
    movzx eax, byte ptr [rsi]
    mov [rdi], al
    cmp edx, 2
    jb 6f
    movzx eax, word ptr [rsi + rdx - 2]
    mov [rdi + rdx - 2], ax
6:  ret

# pgw_bind_begin(buf, stmt, stmt_len, nparams) -> handle
.globl pgw_bind_begin
pgw_bind_begin:
    mov r8, rdi
    mov r9, [rdi + PGB_PTR]
    mov r10, [rdi + PGB_LEN]
    mov r11, rcx
    lea rdi, [r9 + r10]
    mov byte ptr [rdi], 0x42        # 'B'
    mov byte ptr [rdi + 5], 0       # portal ""
    add rdi, 6
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    mov dword ptr [rdi + 1], 0x01000100   # 1 param format code: binary
    mov eax, r11d
    xchg al, ah
    mov [rdi + 5], ax
    add rdi, 7
    sub rdi, r9
    mov [r8 + PGB_LEN], rdi
    mov rax, r10
    ret

# pgw_bind_end(buf, handle): 1 result format code (binary), patch the length
.globl pgw_bind_end
pgw_bind_end:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    mov dword ptr [r9 + rax], 0x01000100
    add rax, 4
    mov [rdi + PGB_LEN], rax
    sub rax, rsi
    dec rax
    bswap eax
    mov [r9 + rsi + 1], eax
    ret

.globl pgw_param_null
pgw_param_null:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    mov dword ptr [r9 + rax], -1
    add qword ptr [rdi + PGB_LEN], 4
    ret

.globl pgw_param_int8
pgw_param_int8:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    mov dword ptr [r9 + rax], 0x08000000
    bswap rsi
    mov [r9 + rax + 4], rsi
    add qword ptr [rdi + PGB_LEN], 12
    ret

# pgw_param_text(buf, ptr, len)
.globl pgw_param_text
pgw_param_text:
    mov r9, rdi
    mov rdi, [r9 + PGB_PTR]
    add rdi, [r9 + PGB_LEN]
    mov eax, edx
    bswap eax
    mov [rdi], eax
    add rdi, 4
    lea rax, [rdx + 4]
    add [r9 + PGB_LEN], rax
    jmp .Lmemcpy

# pgw_array_begin(buf, elem_oid) -> handle. Layout at handle: len, ndim=1, has_null, oid, dim (native count
# while building), lbound=1, elements.
.globl pgw_array_begin
pgw_array_begin:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    add qword ptr [rdi + PGB_LEN], 24
    lea r8, [r9 + rax]
    mov dword ptr [r8 + 4], 0x01000000
    mov dword ptr [r8 + 8], 0
    bswap esi
    mov [r8 + 12], esi
    mov dword ptr [r8 + 16], 0
    mov dword ptr [r8 + 20], 0x01000000
    ret

# pgw_array_int8(buf, handle, v)
.globl pgw_array_int8
pgw_array_int8:
    mov r9, [rdi + PGB_PTR]
    inc dword ptr [r9 + rsi + 16]
    mov rax, [rdi + PGB_LEN]
    add qword ptr [rdi + PGB_LEN], 12
    mov dword ptr [r9 + rax], 0x08000000
    bswap rdx
    mov [r9 + rax + 4], rdx
    ret

# pgw_array_text(buf, handle, ptr, len)
.globl pgw_array_text
pgw_array_text:
    mov r9, [rdi + PGB_PTR]
    inc dword ptr [r9 + rsi + 16]
    mov rax, [rdi + PGB_LEN]
    lea r8, [rcx + 4]
    add [rdi + PGB_LEN], r8
    lea rdi, [r9 + rax]
    mov eax, ecx
    bswap eax
    mov [rdi], eax
    add rdi, 4
    mov rsi, rdx
    mov rdx, rcx
    jmp .Lmemcpy

# pgw_array_null(buf, handle)
.globl pgw_array_null
pgw_array_null:
    mov r9, [rdi + PGB_PTR]
    inc dword ptr [r9 + rsi + 16]
    mov byte ptr [r9 + rsi + 11], 1 # has_null
    mov rax, [rdi + PGB_LEN]
    mov dword ptr [r9 + rax], -1
    add qword ptr [rdi + PGB_LEN], 4
    ret

# pgw_array_end(buf, handle): empty arrays are sent as ndim = 0
.globl pgw_array_end
pgw_array_end:
    mov r9, [rdi + PGB_PTR]
    lea r8, [r9 + rsi]
    mov eax, [r8 + 16]
    test eax, eax
    jz 1f
    bswap eax
    mov [r8 + 16], eax
    mov rax, [rdi + PGB_LEN]
    sub rax, rsi
    sub eax, 4
    bswap eax
    mov [r8], eax
    ret
1:  mov dword ptr [r8], 0x0c000000
    mov dword ptr [r8 + 4], 0
    mov dword ptr [r8 + 8], 0
    lea rax, [rsi + 16]
    mov [rdi + PGB_LEN], rax
    ret

# pgw_execute(buf): 'E', portal "", max rows 0
.globl pgw_execute
pgw_execute:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    mov rcx, 0x0000000900000045    # 'E' 00000009 00 + first byte of max rows
    mov [r9 + rax], rcx
    mov word ptr [r9 + rax + 8], 0
    add qword ptr [rdi + PGB_LEN], 10
    ret

# pgw_sync(buf): 'S'
.globl pgw_sync
pgw_sync:
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    mov dword ptr [r9 + rax], 0x00000053
    mov byte ptr [r9 + rax + 4], 4
    add qword ptr [rdi + PGB_LEN], 5
    ret

# pgw_query(buf, sql, len): 'Q' simple query
.globl pgw_query
pgw_query:
    push rbx
    mov rbx, rdi
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    lea rdi, [r9 + rax]
    mov byte ptr [rdi], 0x51
    lea eax, [rdx + 5]
    bswap eax
    mov [rdi + 1], eax
    lea rax, [rdx + 6]
    add [rbx + PGB_LEN], rax
    lea rax, [rdi + rdx + 5]
    push rax
    add rdi, 5
    call .Lmemcpy
    pop rax
    mov byte ptr [rax], 0
    pop rbx
    ret

# pgw_parse(buf, name, name_len, sql, sql_len): 'P' with no parameter types (extra, for pipelined prepares)
.globl pgw_parse
pgw_parse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rcx                    # sql
    mov r13, r8                     # sql len
    mov r9, [rdi + PGB_PTR]
    mov rax, [rdi + PGB_LEN]
    lea rdi, [r9 + rax]
    mov byte ptr [rdi], 0x50
    lea eax, [rdx + r13 + 8]        # 4 + name + \0 + sql + \0 + int16
    bswap eax
    mov [rdi + 1], eax
    lea rax, [rdx + r13 + 9]
    add [rbx + PGB_LEN], rax
    add rdi, 5
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    inc rdi
    mov rsi, r12
    mov rdx, r13
    lea rax, [rdi + r13]
    push rax
    call .Lmemcpy                   # (stack: 3 pushes + 1 = aligned is irrelevant for a leaf)
    pop rax
    mov byte ptr [rax], 0
    mov word ptr [rax + 1], 0
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ message reader
# pgr_next(ptr, len) -> rax = type byte | 0 if incomplete | -1 if malformed (length < 4);
#                       rdx = total message length (also when incomplete and len >= 5; else 0)
.globl pgr_next
pgr_next:
    xor edx, edx
    cmp rsi, 5
    jb 1f
    mov edx, [rdi + 1]
    bswap edx
    cmp edx, 4
    jb 2f
    inc rdx
    cmp rdx, rsi
    ja 1f
    movzx eax, byte ptr [rdi]
    ret
1:  xor eax, eax
    ret
2:  mov rax, -1
    ret

# pgr_datarow(msg, cols_out, maxcols) -> ncols; fills min(ncols, maxcols) {ptr, len} pairs (len -1 = NULL)
.globl pgr_datarow
pgr_datarow:
    movzx eax, word ptr [rdi + 5]
    xchg al, ah
    lea r8, [rdi + 7]
    mov ecx, eax
    cmp rcx, rdx
    cmova rcx, rdx
    test ecx, ecx
    jz 2f
1:  mov r9d, [r8]
    bswap r9d
    movsxd r9, r9d
    add r8, 4
    mov [rsi], r8
    mov [rsi + 8], r9
    xor r10d, r10d
    test r9, r9
    cmovns r10, r9
    add r8, r10
    add rsi, 16
    dec ecx
    jnz 1b
2:  ret

# pgr_error_sqlstate(msg) -> SQLSTATE as 5 bytes little-endian in the low 40 bits ("23505" = 0x3530353332), 0 if absent
.globl pgr_error_sqlstate
pgr_error_sqlstate:
    mov esi, 0x43
    call .Lerr_field
    test rax, rax
    jz 1f
    cmp rdx, 5
    jb 2f
    mov ecx, [rax]
    movzx edx, byte ptr [rax + 4]
    shl rdx, 32
    or rcx, rdx
    mov rax, rcx
1:  ret
2:  xor eax, eax
    ret

# pgr_error_message(msg, out_ptr*, out_len*) -> 1 found | 0 (out = 0, 0)
.globl pgr_error_message
pgr_error_message:
    mov r10, rsi
    mov r11, rdx
    mov esi, 0x4d
    call .Lerr_field
    mov [r10], rax
    mov [r11], rdx
    test rax, rax
    setnz al
    movzx eax, al
    ret

# ================================================================ decoders
.globl pgd_int8
pgd_int8:
.globl pgd_ts
pgd_ts:
    mov rax, [rdi]
    bswap rax
    ret

.globl pgd_int4
pgd_int4:
    mov eax, [rdi]
    bswap eax
    movsxd rax, eax
    ret

.globl pgd_bool
pgd_bool:
    xor eax, eax
    cmp byte ptr [rdi], 0
    setne al
    ret

# pgd_array_first(ptr, len, it) -> first element (see pgd_array_next). Multi-dim arrays iterate flattened.
# it (PAIT_SIZE): PAIT_CUR, PAIT_END, PAIT_LEFT, PAIT_COUNT (total element count)
.globl pgd_array_first
pgd_array_first:
    lea r8, [rdi + rsi]
    mov [rdx + PAIT_END], r8
    xor eax, eax
    mov [rdx + PAIT_LEFT], rax
    mov [rdx + PAIT_COUNT], rax
    mov [rdx + PAIT_CUR], r8
    cmp rsi, 12
    jb 9f
    mov ecx, [rdi]
    bswap ecx                       # ndim
    test ecx, ecx
    jz 9f
    cmp ecx, 6
    ja 9f
    lea r9, [rcx*8 + 12]
    cmp r9, rsi
    ja 9f
    mov eax, 1
    lea r10, [rdi + 12]
1:  mov r11d, [r10]
    bswap r11d
    test r11d, r11d
    js 8f
    imul rax, r11
    add r10, 8
    dec ecx
    jnz 1b
    mov [rdx + PAIT_LEFT], rax
    mov [rdx + PAIT_COUNT], rax
    mov [rdx + PAIT_CUR], r10
9:  mov rdi, rdx
    jmp pgd_array_next
8:  xor eax, eax
    jmp 9b

# pgd_array_next(it) -> rax = element ptr (0 at end / malformed), rdx = element len (-1 = NULL)
.globl pgd_array_next
pgd_array_next:
    mov rcx, [rdi + PAIT_LEFT]
    test rcx, rcx
    jz 9f
    mov rax, [rdi + PAIT_CUR]
    mov r8, [rdi + PAIT_END]
    lea r9, [rax + 4]
    cmp r9, r8
    ja 8f
    mov edx, [rax]
    bswap edx
    movsxd rdx, edx
    add rax, 4
    test rdx, rdx
    js 1f
    lea r9, [rax + rdx]
    cmp r9, r8
    ja 8f
    mov [rdi + PAIT_CUR], r9
    dec qword ptr [rdi + PAIT_LEFT]
    ret
1:  mov rdx, -1
    mov [rdi + PAIT_CUR], rax
    dec qword ptr [rdi + PAIT_LEFT]
    ret
8:  mov qword ptr [rdi + PAIT_LEFT], 0
9:  xor eax, eax
    xor edx, edx
    ret

.section .note.GNU-stack,"",@progbits
