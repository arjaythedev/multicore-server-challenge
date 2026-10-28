# api.s: routing and the endpoints. Mirrors the Rust reference src/api.rs: the order of checks is auth (401) ->
# body (422) -> database (404/403/422), responses are byte-identical, and the SQL semantics match.
#
# A request becomes a job (J_*). Synchronous failures (routing, auth, body) answer at once with api_fail and
# return to api_request. Otherwise the job is handed to Postgres (db_read / db_write) or the bcrypt threads
# (bcq_submit) with a continuation in J_CONT; the continuation runs later (pgio dispatch / srv_completions) and
# either hands the job on again or renders the response (api_send) and returns.
#
# Conventions:
#   rbx  = the current job throughout; r15 = worker (never touched).
#   Body/auth helpers return CF set when they have already answered (caller just returns), CF clear on success.
#   A continuation is cont(job, seg_ptr, seg_len) with seg_len = -1 when the connection died.
#   Stack: every function reaches rsp % 16 == 0 before any `call` (SysV). Endpoints that touch a body use a
#   `sub rsp, 24` frame holding objlen at [rsp] and obj at [rsp+8]; other endpoints use `sub rsp, 8`.
.include "defs.inc"
.include "app.inc"

.equ BCRYPT_COST, 10
.equ COLS_MAX, 20                        # columns decoded per DataRow
.equ COLS_BYTES, COLS_MAX * 16

# Param slot \i (rbx = job).
.macro PARAM_INT i, vr
    mov [rbx + J_P + (\i)*16], \vr
    mov qword ptr [rbx + J_P + (\i)*16 + 8], 0
    mov byte ptr [rbx + J_PT + (\i)], PT_INT8
.endm
.macro PARAM_TXT i, pr, lr
    mov qword ptr [rbx + J_P + (\i)*16], \pr
    mov qword ptr [rbx + J_P + (\i)*16 + 8], \lr
    mov byte ptr [rbx + J_PT + (\i)], PT_TEXT
.endm
.macro PARAM_ARR i, pr, cr
    mov [rbx + J_P + (\i)*16], \pr
    mov [rbx + J_P + (\i)*16 + 8], \cr
    mov byte ptr [rbx + J_PT + (\i)], PT_TEXTARR
.endm

# SEG_IS i, lit: ZF set if path segment i equals the rodata DEFSTR \lit. Preserves rbx, r11.
.macro SEG_IS i, lit
    mov rdi, [rbx + J_SEG + (\i)*16]
    mov rsi, [rbx + J_SEG + (\i)*16 + 8]
    lea rdx, [rip + \lit]
    mov ecx, \lit\()_len
    call rt_memeq
    cmp eax, 1                              # ZF set when rt_memeq returned 1 (equal); dispatch uses jnz to skip
.endm
.macro SEG_EMPTY i
    cmp qword ptr [rbx + J_SEG + (\i)*16 + 8], 0
.endm
.macro METHOD reg
    mov \reg, [rbx + J_REQ + REQ_METHOD]
.endm

.section .rodata
# ---- path segment keywords ----
DEFSTR k_tags, "tags"
DEFSTR k_users, "users"
DEFSTR k_user, "user"
DEFSTR k_articles, "articles"
DEFSTR k_login, "login"
DEFSTR k_profiles, "profiles"
DEFSTR k_feed, "feed"
DEFSTR k_follow, "follow"
DEFSTR k_favorite, "favorite"
DEFSTR k_comments, "comments"
DEFSTR k_tokenpfx, "Token "
# ---- body field keys ----
DEFSTR fk_user, "user"
DEFSTR fk_article, "article"
DEFSTR fk_comment, "comment"
DEFSTR fk_username, "username"
DEFSTR fk_email, "email"
DEFSTR fk_password, "password"
DEFSTR fk_title, "title"
DEFSTR fk_description, "description"
DEFSTR fk_body, "body"
DEFSTR fk_bio, "bio"
DEFSTR fk_image, "image"
DEFSTR fk_taglist, "tagList"
# ---- query keys (index order: limit, offset, tag, author, favorited) ----
.balign 8
qv_keys:
    .quad qk_limit, 5
    .quad qk_offset, 6
    .quad qk_tag, 3
    .quad qk_author, 6
    .quad qk_favorited, 9
qk_limit:     .ascii "limit"
qk_offset:    .ascii "offset"
qk_tag:       .ascii "tag"
qk_author:    .ascii "author"
qk_favorited: .ascii "favorited"
# ---- response wrappers ----
lit_article_open:   .ascii "{\"article\":"
ENDLIT lit_article_open
lit_articles_open:  .ascii "{\"articles\":["
ENDLIT lit_articles_open
lit_articles_count: .ascii "],\"articlesCount\":"
ENDLIT lit_articles_count
lit_profile_open:   .ascii "{\"profile\":"
ENDLIT lit_profile_open
lit_comments_open:  .ascii "{\"comments\":["
ENDLIT lit_comments_open
lit_comment_open:   .ascii "{\"comment\":"
ENDLIT lit_comment_open
lit_tags_open:      .ascii "{\"tags\":"
ENDLIT lit_tags_open
# ---- error messages ----
DEFSTR m_malformed, "malformed JSON body"
DEFSTR m_noobj, "missing or invalid request object"
DEFSTR m_required, "required field missing or empty"
DEFSTR m_optional, "field must be a non-empty string"
DEFSTR m_pwlong, "password is too long"
DEFSTR m_badlimit, "invalid limit"
DEFSTR m_badoffset, "invalid offset"
DEFSTR m_taglist, "tagList must be an array of non-empty strings"
DEFSTR m_taken, "username or email already taken"
DEFSTR m_unauthorized, "unauthorized"
DEFSTR m_forbidden, "forbidden"
DEFSTR m_notfound, "not found"
DEFSTR m_internal, "internal server error"
DEFSTR m_busy, "server busy"


.text

# ================================================================ entry
# api_request(conn, req): build the job and route it.
.globl api_request
api_request:
    push rbx
    push r12
    push r13
    mov r13, rdi                         # conn
    mov r12, rsi                         # parsed req (caller's stack)
    mov edi, J_SIZE
    call rt_alloc
    mov rbx, rax
    mov rdi, rbx
    xor eax, eax
    mov ecx, J_INL / 8                   # zero the header, not the inline scratch tail
    rep stosq
    mov [rbx + J_CONN], r13
    mov [r13 + C_JOB], rbx
    mov qword ptr [rbx + J_STATUS], 200
    lea rdi, [rbx + J_REQ]
    mov rsi, r12
    mov ecx, REQ_SIZE / 8
    rep movsq
    xor eax, eax
    test qword ptr [rbx + J_REQ + REQ_FLAGS], REQF_CLOSE
    setnz al
    mov [rbx + J_CLOSE], rax
    # scratch arena: 3*(path+query) + 6*body + JWT + 1024, comfortably covers every decode this request makes
    mov rsi, [rbx + J_REQ + REQ_PATH_LEN]
    add rsi, [rbx + J_REQ + REQ_QUERY_LEN]
    lea rsi, [rsi + rsi*2]
    mov rax, [rbx + J_REQ + REQ_BODY_LEN]
    lea rsi, [rsi + rax*2]
    lea rsi, [rsi + rax*4]
    add rsi, JWT_SIGN_MAX + 1024
    cmp rsi, JOB_INLINE_SCR
    ja 1f
    lea rax, [rbx + J_INL]
    mov [rbx + J_SCR], rax
    mov qword ptr [rbx + J_SCRCAP], JOB_INLINE_SCR
    jmp 2f
1:  mov rdi, rsi
    call rt_alloc
    mov [rbx + J_SCR], rax
    mov [rbx + J_SCRCAP], rdx
    mov qword ptr [rbx + J_SCRALLOC], 1
2:  mov qword ptr [rbx + J_SCRUSED], 0
    call route
    pop r13
    pop r12
    pop rbx
    ret

# api_scr(n) -> rax = n reserved scratch bytes (rbx = job). The arena is sized up front, so earlier pointers
# never move. Clobbers only rax.
api_scr:
    mov rax, [rbx + J_SCR]
    add rax, [rbx + J_SCRUSED]
    add [rbx + J_SCRUSED], rdi
    ret

# ================================================================ routing
# Strip "/api/", split the rest on '/', decode %-escaped segments, store J_SEG/J_NSEG, dispatch by count and
# method. r12/r13/r14/rbp are the parse state; r11 carries the chosen handler across the epilogue.
route:
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 8
    mov rsi, [rbx + J_REQ + REQ_PATH]
    mov rdx, [rbx + J_REQ + REQ_PATH_LEN]
    cmp rdx, 5
    jb .Lrt_404
    cmp dword ptr [rsi], 0x6970612f       # "/api"
    jne .Lrt_404
    cmp byte ptr [rsi + 4], '/'
    jne .Lrt_404
    add rsi, 5
    sub rdx, 5
    lea r13, [rsi + rdx]                   # end of the rest
    xor ebp, ebp                           # segment count
    mov r14, rsi                           # scan cursor
.Lrt_seg:
    mov r12, r14                           # segment start
.Lrt_scan:
    cmp r14, r13
    je .Lrt_segend
    cmp byte ptr [r14], '/'
    je .Lrt_segend
    inc r14
    jmp .Lrt_scan
.Lrt_segend:
    cmp ebp, 4
    jae .Lrt_404                           # a 5th segment: not a route
    mov rdi, r12
    mov rsi, r14
    sub rsi, r12                           # segment length
    mov edx, '%'
    call rt_memchr
    test rax, rax
    jz .Lrt_raw
    mov rdi, r14
    sub rdi, r12
    call api_scr                           # dst for the decode
    mov [rsp], rax                          # save dst in the frame slot (keeps rsp aligned)
    mov rdi, r12
    mov rsi, r14
    sub rsi, r12
    mov rdx, rax                           # dst
    mov ecx, PCT_PATH
    call http_pct_decode
    mov rcx, [rsp]                          # dst
    test rax, rax
    js .Lrt_404
    mov rdx, rbp
    shl rdx, 4
    mov [rbx + J_SEG + rdx], rcx
    mov [rbx + J_SEG + rdx + 8], rax
    jmp .Lrt_stored
.Lrt_raw:
    mov rdx, rbp
    shl rdx, 4
    mov [rbx + J_SEG + rdx], r12
    mov rax, r14
    sub rax, r12
    mov [rbx + J_SEG + rdx + 8], rax
.Lrt_stored:
    inc ebp
    cmp r14, r13
    je .Lrt_done
    inc r14                                # skip the '/'
    jmp .Lrt_seg
.Lrt_done:
    mov [rbx + J_NSEG], rbp
    cmp ebp, 1
    je .Lrt_n1
    cmp ebp, 2
    je .Lrt_n2
    cmp ebp, 3
    je .Lrt_n3
    cmp ebp, 4
    je .Lrt_n4
.Lrt_404:
    lea r11, [rip + api_404]
.Lrt_go:
    add rsp, 8
    pop rbp
    pop r14
    pop r13
    pop r12
    jmp r11

.Lrt_n1:
    SEG_IS 0, k_tags
    jnz 1f
    METHOD rax
    cmp rax, M_GET
    jne .Lrt_404
    lea r11, [rip + ep_tags]
    jmp .Lrt_go
1:  SEG_IS 0, k_users
    jnz 2f
    METHOD rax
    cmp rax, M_POST
    jne .Lrt_404
    lea r11, [rip + ep_register]
    jmp .Lrt_go
2:  SEG_IS 0, k_user
    jnz 3f
    METHOD rax
    lea r11, [rip + ep_current_user]
    cmp rax, M_GET
    je .Lrt_go
    lea r11, [rip + ep_update_user]
    cmp rax, M_PUT
    je .Lrt_go
    jmp .Lrt_404
3:  SEG_IS 0, k_articles
    jnz .Lrt_404
    METHOD rax
    lea r11, [rip + ep_list]
    cmp rax, M_GET
    je .Lrt_go
    lea r11, [rip + ep_create]
    cmp rax, M_POST
    je .Lrt_go
    jmp .Lrt_404

.Lrt_n2:
    SEG_IS 0, k_users
    jnz 1f
    SEG_IS 1, k_login
    jnz .Lrt_404
    METHOD rax
    cmp rax, M_POST
    jne .Lrt_404
    lea r11, [rip + ep_login]
    jmp .Lrt_go
1:  SEG_IS 0, k_profiles
    jnz 2f
    SEG_EMPTY 1
    je .Lrt_404
    METHOD rax
    cmp rax, M_GET
    jne .Lrt_404
    lea r11, [rip + ep_profile]
    jmp .Lrt_go
2:  SEG_IS 0, k_articles
    jnz .Lrt_404
    SEG_IS 1, k_feed
    jnz 3f
    METHOD rax
    cmp rax, M_GET
    jne .Lrt_404
    lea r11, [rip + ep_feed]
    jmp .Lrt_go
3:  SEG_EMPTY 1
    je .Lrt_404
    METHOD rax
    lea r11, [rip + ep_get_article]
    cmp rax, M_GET
    je .Lrt_go
    lea r11, [rip + ep_update_article]
    cmp rax, M_PUT
    je .Lrt_go
    lea r11, [rip + ep_delete_article]
    cmp rax, M_DELETE
    je .Lrt_go
    jmp .Lrt_404

.Lrt_n3:
    SEG_IS 0, k_profiles
    jnz 1f
    SEG_EMPTY 1
    je .Lrt_404
    SEG_IS 2, k_follow
    jnz .Lrt_404
    METHOD rax
    lea r11, [rip + ep_follow_on]
    cmp rax, M_POST
    je .Lrt_go
    lea r11, [rip + ep_follow_off]
    cmp rax, M_DELETE
    je .Lrt_go
    jmp .Lrt_404
1:  SEG_IS 0, k_articles
    jnz .Lrt_404
    SEG_EMPTY 1
    je .Lrt_404
    SEG_IS 2, k_favorite
    jnz 2f
    METHOD rax
    lea r11, [rip + ep_favorite_on]
    cmp rax, M_POST
    je .Lrt_go
    lea r11, [rip + ep_favorite_off]
    cmp rax, M_DELETE
    je .Lrt_go
    jmp .Lrt_404
2:  SEG_IS 2, k_comments
    jnz .Lrt_404
    METHOD rax
    lea r11, [rip + ep_comments]
    cmp rax, M_GET
    je .Lrt_go
    lea r11, [rip + ep_add_comment]
    cmp rax, M_POST
    je .Lrt_go
    jmp .Lrt_404

.Lrt_n4:
    SEG_IS 0, k_articles
    jnz .Lrt_404
    SEG_EMPTY 1
    je .Lrt_404
    SEG_IS 2, k_comments
    jnz .Lrt_404
    SEG_EMPTY 3
    je .Lrt_404
    METHOD rax
    cmp rax, M_DELETE
    jne .Lrt_404
    lea r11, [rip + ep_delete_comment]
    jmp .Lrt_go

# ================================================================ auth
# auth_required -> rax = user id (CF clear); or answers 401 (CF set). Sets J_TOK/J_TOKLEN.
auth_required:
    sub rsp, 8
    mov rdi, [rbx + J_REQ + REQ_AUTH]
    test rdi, rdi
    jz 1f
    mov rsi, [rbx + J_REQ + REQ_AUTH_LEN]
    call auth_token
    test rax, rax
    jz 1f
    add rsp, 8
    clc
    ret
1:  call api_401
    add rsp, 8
    stc
    ret

# auth_viewer -> rax = viewer id (0 = anonymous, CF clear); a present but invalid token answers 401 (CF set).
auth_viewer:
    sub rsp, 8
    mov rdi, [rbx + J_REQ + REQ_AUTH]
    test rdi, rdi
    jz 2f
    mov rsi, [rbx + J_REQ + REQ_AUTH_LEN]
    call auth_token
    test rax, rax
    jz 1f
    add rsp, 8
    clc
    ret
1:  call api_401
    add rsp, 8
    stc
    ret
2:  xor eax, eax
    add rsp, 8
    clc
    ret

# auth_token(ptr, len) -> rax = id (0 invalid). Requires the exact "Token " prefix; sets J_TOK/J_TOKLEN.
auth_token:
    push r12
    push r13
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    cmp r13, 6
    jb 1f
    mov rdi, r12
    mov esi, 6
    lea rdx, [rip + k_tokenpfx]
    mov ecx, 6
    call rt_memeq
    test eax, eax
    jz 1f
    add r12, 6
    sub r13, 6
    mov [rbx + J_TOK], r12
    mov [rbx + J_TOKLEN], r13
    lea rdi, [rip + g_jwt]
    mov rsi, r12
    mov rdx, r13
    mov rcx, [r15 + W_NOW]
    call crypto_jwt_verify
    add rsp, 8
    pop r13
    pop r12
    ret
1:  xor eax, eax
    add rsp, 8
    pop r13
    pop r12
    ret

# ================================================================ body helpers
# body_object(key, keylen) -> rax = inner object ptr, rdx = len (CF clear); or answers 422 (CF set).
body_object:
    push r12
    push r13
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov rdi, [rbx + J_REQ + REQ_BODY]
    mov rsi, [rbx + J_REQ + REQ_BODY_LEN]
    call json_validate
    test eax, eax
    jz .Lbo_malformed
    mov rdi, [rbx + J_REQ + REQ_BODY]
    mov rsi, [rbx + J_REQ + REQ_BODY_LEN]
    call skip_ws_byte
    cmp al, '{'
    jne .Lbo_malformed
    mov rdi, [rbx + J_REQ + REQ_BODY]
    mov rsi, [rbx + J_REQ + REQ_BODY_LEN]
    mov rdx, r12
    mov rcx, r13
    call json_find
    test rax, rax
    jz .Lbo_noobj
    cmp rcx, JT_OBJECT
    jne .Lbo_noobj
    add rsp, 8
    pop r13
    pop r12
    clc
    ret
.Lbo_malformed:
    lea rdi, [rip + m_malformed]
    mov esi, m_malformed_len
    call api_422
    jmp .Lbo_fail
.Lbo_noobj:
    lea rdi, [rip + m_noobj]
    mov esi, m_noobj_len
    call api_422
.Lbo_fail:
    add rsp, 8
    pop r13
    pop r12
    stc
    ret

# skip_ws_byte(ptr, len) -> al = first non-whitespace byte (0 if none). Clobbers rax, rcx.
skip_ws_byte:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 3f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, ' '
    je 2f
    cmp al, 9
    je 2f
    cmp al, 10
    je 2f
    cmp al, 13
    je 2f
    ret
2:  inc rcx
    jmp 1b
3:  xor eax, eax
    ret

# required(obj, objlen, key, keylen) -> rax = decoded ptr, rdx = len > 0 (CF clear); or answers 422 (CF set).
required:
    push r12
    push r13
    push r14
    call json_find
    test rax, rax
    jz .Lreq_bad
    cmp rcx, JT_STRING
    jne .Lreq_bad
    mov r12, rax
    mov r13, rdx
    mov rdi, rdx
    call api_scr
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call json_str_decode
    test rax, rax
    jle .Lreq_bad
    mov rdx, rax
    mov rax, r14
    pop r14
    pop r13
    pop r12
    clc
    ret
.Lreq_bad:
    lea rdi, [rip + m_required]
    mov esi, m_required_len
    call api_422
    pop r14
    pop r13
    pop r12
    stc
    ret

# optional(obj, objlen, key, keylen, non_empty_in_r8) -> CF set: answered 422. CF clear & rdx = -1: None.
# CF clear & rdx >= 0: Some(rax = ptr, rdx = len).
optional:
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 8
    mov rbp, r8
    call json_find
    test rax, rax
    jz .Lopt_none
    cmp rcx, JT_NULL
    je .Lopt_none
    cmp rcx, JT_STRING
    jne .Lopt_bad
    mov r12, rax
    mov r13, rdx
    mov rdi, rdx
    call api_scr
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call json_str_decode
    test rax, rax
    js .Lopt_bad
    jnz .Lopt_some
    test rbp, rbp
    jnz .Lopt_bad
.Lopt_some:
    mov rdx, rax
    mov rax, r14
    add rsp, 8
    pop rbp
    pop r14
    pop r13
    pop r12
    clc
    ret
.Lopt_none:
    mov rdx, -1
    add rsp, 8
    pop rbp
    pop r14
    pop r13
    pop r12
    clc
    ret
.Lopt_bad:
    lea rdi, [rip + m_optional]
    mov esi, m_optional_len
    call api_422
    add rsp, 8
    pop rbp
    pop r14
    pop r13
    pop r12
    stc
    ret

# ================================================================ Postgres handoff
# db_read(job): put the job on the live read connection with the fewest queued ops (the first one if all are
# down: the enqueue then fails the job at once).
.globl db_read
db_read:
    push r12
    push r13
    sub rsp, 8
    mov r12, rdi
    xor r13d, r13d
    xor r8d, r8d
1:  cmp r8, [r15 + W_NRD]
    jae 2f
    mov rcx, [r15 + W_RDS + r8*8]
    inc r8
    test qword ptr [rcx + PC_FLAGS], PCF_DEAD
    jnz 1b
    test r13, r13
    jz 3f
    mov rax, [rcx + PC_NQ]
    cmp rax, [r13 + PC_NQ]
    jae 1b
3:  mov r13, rcx
    jmp 1b
2:  test r13, r13
    jnz 4f
    mov r13, [r15 + W_RDS]
4:  mov rdi, r13
    mov rsi, r12
    call pgio_put_job
    mov rdi, r13
    mov rsi, r12
    call pgio_enqueue
    add rsp, 8
    pop r13
    pop r12
    ret
    .skip 44, 0xcc                     # padding: keeps the code after this at its previous 64-byte alignment

# db_write(job) lives in writer.s (group commit).

# ================================================================ response builders
# api_body(need) -> rax = body start (rbx = job). Reserves OUT_HEAD_ROOM before the body for the HTTP head.
.globl api_body
api_body:
    sub rsp, 8
    lea rdi, [rdi + OUT_HEAD_ROOM]
    call rt_alloc
    mov [rbx + J_OUT], rax
    mov [rbx + J_OUTCAP], rdx
    lea rax, [rax + OUT_HEAD_ROOM]
    add rsp, 8
    ret

# api_send(bodyend): finish a response whose body is J_OUT+OUT_HEAD_ROOM .. bodyend; frees the job via
# srv_respond. J_OUTSTART / J_OUTEND are stored as offsets from J_OUT (srv_respond adds J_OUT back).
# As the Rust handle_one: a body of HTTP_GZIP_MIN+ bytes is gzipped when the request accepts gzip, the response is
# not bodiless (HEAD, 204) and egress_compress says so (the short-circuit order matters: it advances the turn);
# the gzip member is kept only when smaller. egress_sent then counts head + payload (0 for bodiless).
.equ AS_BODILESS, 16                         # api_send's own flag next to HW_CLOSE / HW_GZIP
.globl api_send
api_send:
    push r12
    push r13
    sub rsp, 168                             # [rsp] head scratch; [rsp+144] new buffer, [rsp+152] its capacity
    mov r12, rdi                             # bodyend (absolute)
    mov r13, [rbx + J_CLOSE]                 # 0 / 1 = HW_CLOSE
    mov rax, [rbx + J_CONN]
    test qword ptr [rax + C_FLAGS], CF_HEADM
    jnz .Las_bodiless
    cmp qword ptr [rbx + J_STATUS], 204
    je .Las_bodiless
    test qword ptr [rbx + J_REQ + REQ_FLAGS], REQF_GZIP
    jz .Las_head
    mov rax, r12
    sub rax, [rbx + J_OUT]
    sub rax, OUT_HEAD_ROOM
    cmp rax, HTTP_GZIP_MIN
    jb .Las_head
    lea rdi, [r15 + W_TURN]
    call egress_compress
    test eax, eax
    jz .Las_head
    mov rdi, r12
    sub rdi, [rbx + J_OUT]                   # OUT_HEAD_ROOM + body length
    add rdi, 64                              # gzip_bound
    call rt_alloc
    mov [rsp + 144], rax
    mov [rsp + 152], rdx
    mov rdi, [r15 + W_GZ]
    mov rsi, [rbx + J_OUT]
    add rsi, OUT_HEAD_ROOM
    mov rdx, r12
    sub rdx, rsi
    lea rcx, [rax + OUT_HEAD_ROOM]
    mov r8, [rsp + 152]
    sub r8, OUT_HEAD_ROOM
    call gzip_compress
    test rax, rax
    jz .Las_nogz
    mov rcx, r12
    sub rcx, [rbx + J_OUT]
    sub rcx, OUT_HEAD_ROOM
    cmp rax, rcx                             # kept only when smaller, like Rust (http.rs)
    jae .Las_nogz
    mov r12, [rsp + 144]
    lea r12, [r12 + rax + OUT_HEAD_ROOM]     # the gzip body's end
    mov rdi, [rbx + J_OUT]
    mov rsi, [rbx + J_OUTCAP]
    call rt_free
    mov rax, [rsp + 144]
    mov [rbx + J_OUT], rax
    mov rax, [rsp + 152]
    mov [rbx + J_OUTCAP], rax
    or r13, HW_GZIP
    jmp .Las_head
.Las_nogz:
    mov rdi, [rsp + 144]
    mov rsi, [rsp + 152]
    call rt_free
    jmp .Las_head
.Las_bodiless:
    or r13, AS_BODILESS
.Las_head:
    mov rdi, rsp                             # head scratch
    mov rsi, [rbx + J_STATUS]
    mov rdx, r12
    sub rdx, [rbx + J_OUT]
    sub rdx, OUT_HEAD_ROOM                    # content length
    mov rcx, r13
    and ecx, HW_CLOSE | HW_GZIP
    call r_head                               # rax = head end
    sub rax, rsp                              # rax = head length
    mov r8, [rbx + J_OUT]                      # base
    lea rdx, [r8 + OUT_HEAD_ROOM]
    sub rdx, rax                               # dst = bodystart - headlen (absolute)
    mov rcx, rdx
    sub rcx, r8
    mov [rbx + J_OUTSTART], rcx                # head start offset
    mov rcx, r12
    sub rcx, r8
    mov [rbx + J_OUTEND], rcx                  # body end offset
    mov [rsp + 144], rax
    mov rdi, rdx
    mov rsi, rsp
    mov rdx, rax
    call rt_memcpy
    mov rdi, [rsp + 144]                       # bytes sent: head + payload (none when bodiless)
    test r13, AS_BODILESS
    jnz 1f
    mov rdi, [rbx + J_OUTEND]
    sub rdi, [rbx + J_OUTSTART]
1:  call egress_sent
    add rsp, 168
    pop r13
    pop r12
    mov rdi, rbx
    jmp srv_respond

# api_fail(status, msgptr, msglen): answer {"errors":{"body":["msg"]}}.
.globl api_fail
api_fail:
    mov [rbx + J_STATUS], rdi
    sub rsp, 24
    mov [rsp], rsi                            # msgptr
    mov [rsp + 8], rdx                        # msglen
    lea rdi, [rdx + 64]
    call api_body
    mov rdi, rax
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call r_error
    mov rdi, rax
    add rsp, 24
    jmp api_send

api_401:
    mov edi, 401
    lea rsi, [rip + m_unauthorized]
    mov edx, m_unauthorized_len
    jmp api_fail
api_403:
    mov edi, 403
    lea rsi, [rip + m_forbidden]
    mov edx, m_forbidden_len
    jmp api_fail
.globl api_404
api_404:
    mov edi, 404
    lea rsi, [rip + m_notfound]
    mov edx, m_notfound_len
    jmp api_fail
.globl api_500
api_500:
    mov edi, 500
    lea rsi, [rip + m_internal]
    mov edx, m_internal_len
    jmp api_fail
api_503:
    mov edi, 503
    lea rsi, [rip + m_busy]
    mov edx, m_busy_len
    jmp api_fail
# api_422(msgptr, msglen)
api_422:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 422
    jmp api_fail

# api_204(): 204 No Content.
api_204:
    sub rsp, 8
    mov qword ptr [rbx + J_STATUS], 204
    mov edi, 16
    call api_body
    mov rdi, rax
    add rsp, 8
    jmp api_send

# ================================================================ continuation frame
# A read/write continuation keeps rbx=job, r12=seg, r13=seglen, r14=cols (on the stack).
.macro CO_ENTER
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, COLS_BYTES
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rsp
.endm
.macro CO_LEAVE
    add rsp, COLS_BYTES
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.endm

# co_first_row -> rax = first DataRow (0 none), rdx = sqlstate (CF clear); dead conn answers 500 (CF set).
# rbx = job, r12 = seg, r13 = seglen. Called with rsp 16-aligned.
co_first_row:
    cmp r13, -1
    je 1f
    sub rsp, 8
    mov rdi, r12
    mov rsi, r13
    call seg_scan                            # rax row, rdx sqlstate, rcx nrows
    add rsp, 8
    clc
    ret
1:  sub rsp, 8
    call api_500
    add rsp, 8
    stc
    ret

# decode_row(rowptr): pgr_datarow(rowptr, r14, COLS_MAX). Fills r14 with the {ptr,len} columns.
decode_row:
    mov rsi, r14
    mov edx, COLS_MAX
    jmp pgr_datarow

# col_user_bytes -> rax = sum of r_user's four field lengths (cols 1..4), NULL counted as 0. (r14 = cols)
col_user_bytes:
    xor eax, eax
    mov ecx, 1
1:  cmp ecx, 5
    jae 2f
    mov rdx, rcx
    shl rdx, 4
    mov rdx, [r14 + rdx + 8]
    test rdx, rdx
    js 3f
    add rax, rdx
3:  inc ecx
    jmp 1b
2:  ret

# ================================================================ render helpers (rbx=job, r14=cols)
# emit_user(): {"user":...} with token J_TOK/J_TOKLEN.
emit_user:
    sub rsp, 8
    call col_user_bytes
    lea rdi, [rax*8]
    add rdi, [rbx + J_TOKLEN]
    add rdi, 1024
    call api_body
    mov rdi, rax
    mov rsi, r14
    mov rdx, [rbx + J_TOK]
    mov rcx, [rbx + J_TOKLEN]
    call r_user
    mov rdi, rax
    add rsp, 8
    jmp api_send

# emit_user_new_token(): issue a token for the row (id in col0) and emit_user. For register/login.
emit_user_new_token:
    sub rsp, 8
    mov rdi, [r14]
    call pgd_int8
    mov [rbx + J_ID], rax
    mov edi, JWT_SIGN_MAX
    call api_scr
    mov [rbx + J_TOK], rax
    lea rdi, [rip + g_jwt]
    mov rsi, [rbx + J_ID]
    mov rdx, [r15 + W_NOW]
    mov rcx, rax
    call crypto_jwt_sign
    mov [rbx + J_TOKLEN], rax
    add rsp, 8
    jmp emit_user

# emit_article(with_body): {"article":...} from cols r14 at column 0.
emit_article:
    push r12
    mov r12, rdi                             # with_body
    lea rdi, [r13*8 + 2048]
    call api_body
    mov rdi, rax
    PUTL lit_article_open
    mov rsi, r14
    xor edx, edx
    mov rcx, r12
    call r_article_row
    mov byte ptr [rax], '}'
    lea rdi, [rax + 1]
    pop r12
    jmp api_send

# emit_profile(following): {"profile":...} from cols r14 at column 0.
emit_profile:
    push r12
    mov r12, rdi
    lea rdi, [r13*8 + 1024]
    call api_body
    mov rdi, rax
    PUTL lit_profile_open
    mov rsi, r14
    xor edx, edx
    mov rcx, r12
    call r_profile
    mov byte ptr [rax], '}'
    lea rdi, [rax + 1]
    pop r12
    jmp api_send

# emit_comment_created(): {"comment":...} (following = false).
emit_comment_created:
    sub rsp, 8
    lea rdi, [r13*8 + 2048]
    call api_body
    mov rdi, rax
    PUTL lit_comment_open
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call r_comment
    mov byte ptr [rax], '}'
    lea rdi, [rax + 1]
    add rsp, 8
    jmp api_send

# ================================================================ users
# ---------------------------------------------------------------- POST /api/users (register)
ep_register:
    sub rsp, 24
    lea rdi, [rip + fk_user]
    mov esi, fk_user_len
    call body_object
    jc .Lrg_ret
    mov [rsp + 8], rax
    mov [rsp], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + fk_username]
    mov ecx, fk_username_len
    call required
    jc .Lrg_ret
    PARAM_TXT 0, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_email]
    mov ecx, fk_email_len
    call required
    jc .Lrg_ret
    PARAM_TXT 1, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_password]
    mov ecx, fk_password_len
    call required
    jc .Lrg_ret
    mov [rbx + J_PW], rax
    mov [rbx + J_PWLEN], rdx
    cmp rdx, 72
    ja .Lrg_toolong
    lea rdi, [rbx + J_SALT]
    mov esi, 16
    call crypto_random
    mov rcx, [rbx + J_PW]
    mov [rbx + J_BC + BCJ_PW], rcx
    mov rcx, [rbx + J_PWLEN]
    mov [rbx + J_BC + BCJ_PW_LEN], rcx
    lea rcx, [rbx + J_SALT]
    mov [rbx + J_BC + BCJ_HASH], rcx
    mov qword ptr [rbx + J_BC + BCJ_HASH_LEN], BCRYPT_COST
    lea rcx, [rbx + J_HASH]
    mov [rbx + J_BC + BCJ_OUT], rcx
    mov qword ptr [rbx + J_BCKIND], 2
    lea rax, [rip + co_register_hashed]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call bcq_submit
    add rsp, 24
    ret
.Lrg_toolong:
    lea rdi, [rip + m_pwlong]
    mov esi, m_pwlong_len
    call api_422
.Lrg_ret:
    add rsp, 24
    ret

co_register_hashed:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + J_BUSY], 0
    jne 1f
    lea rax, [rbx + J_HASH]
    PARAM_TXT 2, rax, 60
    mov qword ptr [rbx + J_STMT], S_USER_INSERT
    mov qword ptr [rbx + J_NP], 3
    lea rax, [rip + co_register_done]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
    pop rbx
    ret
1:  call api_503
    pop rbx
    ret

co_register_done:
    CO_ENTER
    call co_first_row
    jc .Lrgd_ret
    test rax, rax
    jz .Lrgd_err
    test rdx, rdx
    jnz .Lrgd_err
    mov rdi, rax
    call decode_row
    mov qword ptr [rbx + J_STATUS], 201
    call emit_user_new_token
    jmp .Lrgd_ret
.Lrgd_err:
    mov rcx, SQLSTATE_UNIQUE_VIOLATION
    cmp rdx, rcx
    jne .Lrgd_500
    lea rdi, [rip + m_taken]
    mov esi, m_taken_len
    call api_422
    jmp .Lrgd_ret
.Lrgd_500:
    call api_500
.Lrgd_ret:
    CO_LEAVE

# ---------------------------------------------------------------- POST /api/users/login
ep_login:
    sub rsp, 24
    lea rdi, [rip + fk_user]
    mov esi, fk_user_len
    call body_object
    jc .Llg_ret
    mov [rsp + 8], rax
    mov [rsp], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + fk_email]
    mov ecx, fk_email_len
    call required
    jc .Llg_ret
    PARAM_TXT 0, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_password]
    mov ecx, fk_password_len
    call required
    jc .Llg_ret
    mov [rbx + J_PW], rax
    mov [rbx + J_PWLEN], rdx
    mov qword ptr [rbx + J_STMT], S_USER_EMAIL
    mov qword ptr [rbx + J_NP], 1
    lea rax, [rip + co_login_row]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Llg_ret:
    add rsp, 24
    ret

co_login_row:
    CO_ENTER
    call co_first_row
    jc .Llgr_ret
    test rdx, rdx
    jnz .Llgr_500
    test rax, rax
    jz .Llgr_401
    mov rdi, rax
    call decode_row
    mov rdi, [r14]
    call pgd_int8
    mov [rbx + J_ID], rax
    mov ebp, 1
.Llgr_cp:
    cmp ebp, 5
    jae .Llgr_hash
    mov rdi, rbp
    call cp_slot
    inc ebp
    jmp .Llgr_cp
.Llgr_hash:
    mov rsi, [r14 + 5*16]
    mov rdx, [r14 + 5*16 + 8]
    test rdx, rdx
    js .Llgr_401
    cmp rdx, 64
    ja .Llgr_401
    lea rdi, [rbx + J_STORED]
    mov [rbx + J_STOREDLEN], rdx
    call rt_memcpy
    cmp qword ptr [rbx + J_PWLEN], 72
    ja .Llgr_401
    mov rcx, [rbx + J_PW]
    mov [rbx + J_BC + BCJ_PW], rcx
    mov rcx, [rbx + J_PWLEN]
    mov [rbx + J_BC + BCJ_PW_LEN], rcx
    lea rcx, [rbx + J_STORED]
    mov [rbx + J_BC + BCJ_HASH], rcx
    mov rcx, [rbx + J_STOREDLEN]
    mov [rbx + J_BC + BCJ_HASH_LEN], rcx
    mov qword ptr [rbx + J_BCKIND], 1
    lea rax, [rip + co_login_verified]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call bcq_submit
    jmp .Llgr_ret
.Llgr_401:
    call api_401
    jmp .Llgr_ret
.Llgr_500:
    call api_500
.Llgr_ret:
    CO_LEAVE

# cp_slot(i): copy column i into scratch and store {dst,len} at J_P[i] (TEXT); NULL -> {0,-1}. rbx=job, r14=cols.
cp_slot:
    push r12
    mov r12, rdi                             # slot
    mov byte ptr [rbx + J_PT + r12], PT_TEXT
    mov rax, r12
    shl rax, 4
    mov rdx, [r14 + rax + 8]
    test rdx, rdx
    jns 2f
    mov qword ptr [rbx + J_P + rax], 0
    mov qword ptr [rbx + J_P + rax + 8], -1
    pop r12
    ret
2:  mov rdi, rdx
    call api_scr                             # rax = dst
    mov rcx, r12
    shl rcx, 4
    mov rsi, [r14 + rcx]
    mov rdx, [r14 + rcx + 8]
    mov [rbx + J_P + rcx], rax
    mov [rbx + J_P + rcx + 8], rdx
    mov rdi, rax
    call rt_memcpy
    pop r12
    ret

co_login_verified:
    push rbx
    push r14
    sub rsp, 8
    mov rbx, rdi
    cmp qword ptr [rbx + J_BUSY], 0
    jne .Llv_503
    cmp qword ptr [rbx + J_BC + BCJ_RESULT], 0
    je .Llv_401
    lea r14, [rbx + J_P]
    mov edi, JWT_SIGN_MAX
    call api_scr
    mov [rbx + J_TOK], rax
    lea rdi, [rip + g_jwt]
    mov rsi, [rbx + J_ID]
    mov rdx, [r15 + W_NOW]
    mov rcx, rax
    call crypto_jwt_sign
    mov [rbx + J_TOKLEN], rax
    mov qword ptr [rbx + J_STATUS], 200
    call emit_user
    jmp .Llv_ret
.Llv_401:
    call api_401
    jmp .Llv_ret
.Llv_503:
    call api_503
.Llv_ret:
    add rsp, 8
    pop r14
    pop rbx
    ret

# ---------------------------------------------------------------- GET /api/user
ep_current_user:
    sub rsp, 8
    call auth_required
    jc .Lcu_ret
    PARAM_INT 0, rax
    mov qword ptr [rbx + J_STMT], S_USER_ID
    mov qword ptr [rbx + J_NP], 1
    lea rax, [rip + co_current_user]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lcu_ret:
    add rsp, 8
    ret

co_current_user:
    CO_ENTER
    call co_first_row
    jc .Lccu_ret
    test rdx, rdx
    jnz .Lccu_500
    test rax, rax
    jz .Lccu_401
    mov rdi, rax
    call decode_row
    call emit_user                            # token = presented J_TOK
    jmp .Lccu_ret
.Lccu_401:
    call api_401
    jmp .Lccu_ret
.Lccu_500:
    call api_500
.Lccu_ret:
    CO_LEAVE

# ---------------------------------------------------------------- PUT /api/user
ep_update_user:
    sub rsp, 24
    call auth_required
    jc .Luu_ret
    PARAM_INT 0, rax
    lea rdi, [rip + fk_user]
    mov esi, fk_user_len
    call body_object
    jc .Luu_ret
    mov [rsp + 8], rax
    mov [rsp], rdx
    OPT_FIELD fk_email, 1, 1
    OPT_FIELD fk_username, 2, 1
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_password]
    mov ecx, fk_password_len
    mov r8d, 1
    call optional
    jc .Luu_ret
    cmp rdx, -1
    je .Luu_nopw
    mov [rbx + J_PW], rax
    mov [rbx + J_PWLEN], rdx
    mov byte ptr [rbx + J_FLAG], 1
    jmp .Luu_bio
.Luu_nopw:
    mov byte ptr [rbx + J_FLAG], 0
.Luu_bio:
    OPT_FIELD fk_bio, 4, 0
    OPT_FIELD fk_image, 5, 0
    mov qword ptr [rbx + J_STMT], S_USER_UPDATE
    mov qword ptr [rbx + J_NP], 6
    cmp byte ptr [rbx + J_FLAG], 0
    je .Luu_nohash
    cmp qword ptr [rbx + J_PWLEN], 72
    ja .Luu_toolong
    lea rdi, [rbx + J_SALT]
    mov esi, 16
    call crypto_random
    mov rcx, [rbx + J_PW]
    mov [rbx + J_BC + BCJ_PW], rcx
    mov rcx, [rbx + J_PWLEN]
    mov [rbx + J_BC + BCJ_PW_LEN], rcx
    lea rcx, [rbx + J_SALT]
    mov [rbx + J_BC + BCJ_HASH], rcx
    mov qword ptr [rbx + J_BC + BCJ_HASH_LEN], BCRYPT_COST
    lea rcx, [rbx + J_HASH]
    mov [rbx + J_BC + BCJ_OUT], rcx
    mov qword ptr [rbx + J_BCKIND], 2
    lea rax, [rip + co_update_user_hashed]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call bcq_submit
    add rsp, 24
    ret
.Luu_nohash:
    mov qword ptr [rbx + J_P + 3*16], 0       # hash param NULL
    mov qword ptr [rbx + J_P + 3*16 + 8], -1
    mov byte ptr [rbx + J_PT + 3], PT_TEXT
    lea rax, [rip + co_update_user_done]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
    add rsp, 24
    ret
.Luu_toolong:
    lea rdi, [rip + m_pwlong]
    mov esi, m_pwlong_len
    call api_422
.Luu_ret:
    add rsp, 24
    ret

co_update_user_hashed:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + J_BUSY], 0
    jne 1f
    lea rax, [rbx + J_HASH]
    PARAM_TXT 3, rax, 60
    lea rax, [rip + co_update_user_done]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
    pop rbx
    ret
1:  call api_503
    pop rbx
    ret

co_update_user_done:
    CO_ENTER
    call co_first_row
    jc .Luud_ret
    test rax, rax
    jz .Luud_norow
    test rdx, rdx
    jnz .Luud_errstate
    mov rdi, rax
    call decode_row
    mov qword ptr [rbx + J_STATUS], 200
    call emit_user                            # token = presented J_TOK
    jmp .Luud_ret
.Luud_norow:
    test rdx, rdx
    jnz .Luud_errstate
    call api_401                              # query_opt None -> Unauthorized
    jmp .Luud_ret
.Luud_errstate:
    mov rcx, SQLSTATE_UNIQUE_VIOLATION
    cmp rdx, rcx
    jne .Luud_500
    lea rdi, [rip + m_taken]
    mov esi, m_taken_len
    call api_422
    jmp .Luud_ret
.Luud_500:
    call api_500
.Luud_ret:
    CO_LEAVE

# ================================================================ profiles
# ---------------------------------------------------------------- GET /api/profiles/:u
ep_profile:
    sub rsp, 8
    call auth_viewer
    jc .Lpr_ret
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov qword ptr [rbx + J_STMT], S_PROFILE
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_profile]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lpr_ret:
    add rsp, 8
    ret

co_profile:
    CO_ENTER
    call co_first_row
    jc .Lcpr_ret
    test rdx, rdx
    jnz .Lcpr_500
    test rax, rax
    jz .Lcpr_404
    mov rdi, rax
    call decode_row
    mov rdi, [r14 + 3*16]                      # following col3
    call pgd_bool
    mov rdi, rax
    mov qword ptr [rbx + J_STATUS], 200
    call emit_profile
    jmp .Lcpr_ret
.Lcpr_404:
    call api_404
    jmp .Lcpr_ret
.Lcpr_500:
    call api_500
.Lcpr_ret:
    CO_LEAVE

# ---------------------------------------------------------------- POST/DELETE /api/profiles/:u/follow
ep_follow_on:
    mov edi, S_FOLLOW
    mov esi, 1
    jmp ep_follow
ep_follow_off:
    mov edi, S_UNFOLLOW
    xor esi, esi
ep_follow:
    sub rsp, 24
    mov [rsp], rdi                            # stmt
    mov [rsp + 8], rsi                        # flag
    call auth_required
    jc .Lfo_ret
    mov rcx, [rsp]
    mov [rbx + J_STMT], rcx
    mov rcx, [rsp + 8]
    mov [rbx + J_FLAG], rcx
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_follow]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lfo_ret:
    add rsp, 24
    ret

co_follow:
    CO_ENTER
    call co_first_row
    jc .Lcf_ret
    test rdx, rdx
    jnz .Lcf_500
    test rax, rax
    jz .Lcf_404
    mov rdi, rax
    call decode_row
    mov rdi, [rbx + J_FLAG]
    mov qword ptr [rbx + J_STATUS], 200
    call emit_profile
    jmp .Lcf_ret
.Lcf_404:
    call api_404
    jmp .Lcf_ret
.Lcf_500:
    call api_500
.Lcf_ret:
    CO_LEAVE

# ================================================================ articles: list / feed
# ---------------------------------------------------------------- GET /api/articles
ep_list:
    sub rsp, 8
    call auth_viewer
    jc .Lls_ret
    mov [rbx + J_VIEWER], rax
    call parse_query
    call page
    jc .Lls_ret
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 0, rax
    mov rdi, 2                                # tag
    call qv_filter
    test rax, rax
    jz 1f
    PARAM_TXT 3, rax, rdx
    mov qword ptr [rbx + J_STMT], S_LIST_TAG
    jmp .Lls_go4
1:  mov rdi, 3                                # author
    call qv_filter
    test rax, rax
    jz 2f
    PARAM_TXT 3, rax, rdx
    mov qword ptr [rbx + J_STMT], S_LIST_AUTHOR
    jmp .Lls_go4
2:  mov rdi, 4                                # favorited
    call qv_filter
    test rax, rax
    jz 3f
    PARAM_TXT 3, rax, rdx
    mov qword ptr [rbx + J_STMT], S_LIST_FAVORITED
    jmp .Lls_go4
3:  mov qword ptr [rbx + J_STMT], S_LIST_ALL
    mov qword ptr [rbx + J_NP], 3
    jmp .Lls_read
.Lls_go4:
    mov qword ptr [rbx + J_NP], 4
.Lls_read:
    lea rax, [rip + co_list]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lls_ret:
    add rsp, 8
    ret

# ---------------------------------------------------------------- GET /api/articles/feed
ep_feed:
    sub rsp, 8
    call auth_required
    jc .Lfe_ret
    mov [rbx + J_VIEWER], rax
    call parse_query
    call page
    jc .Lfe_ret
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 0, rax
    mov rax, [rbx + J_P + 1*16]               # limit value
    add rax, [rbx + J_P + 2*16]               # offset value
    jno 1f
    mov rax, 0x7fffffffffffffff
1:  PARAM_INT 3, rax
    mov qword ptr [rbx + J_STMT], S_LIST_FEED
    mov qword ptr [rbx + J_NP], 4
    lea rax, [rip + co_list]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lfe_ret:
    add rsp, 8
    ret

# co_list: render {"articles":[...],"articlesCount":N}. Local frame: [rsp]=p, [rsp+8]=count, [rsp+16]=first.
co_list:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, COLS_BYTES + 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea r14, [rsp + 32]
    cmp r13, -1
    je .Lcl_500
    mov rdi, r12
    mov rsi, r13
    call seg_scan
    test rdx, rdx                             # the statement failed (e.g. 22021 on a NUL in ?tag=): 500
    jnz .Lcl_500
    lea rdi, [r13*8 + 2048]
    call api_body
    mov rbp, rax
    PUTL_R rbp, lit_articles_open
    mov qword ptr [rsp + 8], 0
    mov byte ptr [rsp + 16], 1
    mov [rsp], r12
.Lcl_loop:
    mov rdi, [rsp]
    lea rsi, [r12 + r13]
    call seg_next_row
    test rax, rax
    jz .Lcl_end
    mov r8, rax
    add rax, rdx
    mov [rsp], rax
    mov rdi, r8
    call decode_row
    mov rdi, [r14]                            # count col0
    call pgd_int8
    mov [rsp + 8], rax
    mov rax, [r14 + 1*16 + 8]                 # id col1 len (-1 = NULL padding row)
    test rax, rax
    js .Lcl_loop
    cmp byte ptr [rsp + 16], 1
    je 1f
    mov byte ptr [rbp], ','
    inc rbp
1:  mov byte ptr [rsp + 16], 0
    mov rdi, rbp
    mov rsi, r14
    mov edx, 1                                # column base
    xor ecx, ecx                             # with_body = 0
    call r_article_row
    mov rbp, rax
    jmp .Lcl_loop
.Lcl_end:
    PUTL_R rbp, lit_articles_count
    mov rdi, rbp
    mov rsi, [rsp + 8]
    call jw_int
    mov byte ptr [rax], '}'
    lea rdi, [rax + 1]
    call api_send
    jmp .Lcl_ret
.Lcl_500:
    call api_500
.Lcl_ret:
    add rsp, COLS_BYTES + 32
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ================================================================ single article
# ---------------------------------------------------------------- GET /api/articles/:slug
ep_get_article:
    sub rsp, 8
    call auth_viewer
    jc .Lga_ret
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov qword ptr [rbx + J_STMT], S_ARTICLE_SLUG
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_article]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lga_ret:
    add rsp, 8
    ret

# co_article: {"article":...} from the one row, with body. 404 on no row.
co_article:
    CO_ENTER
    call co_first_row
    jc .Lca_ret
    test rdx, rdx
    jnz .Lca_500
    test rax, rax
    jz .Lca_404
    mov rdi, rax
    call decode_row
    mov qword ptr [rbx + J_STATUS], 200
    mov edi, 1
    call emit_article
    jmp .Lca_ret
.Lca_404:
    call api_404
    jmp .Lca_ret
.Lca_500:
    call api_500
.Lca_ret:
    CO_LEAVE

# ---------------------------------------------------------------- POST /api/articles (create)
ep_create:
    sub rsp, 24
    call auth_required
    jc .Lcr_ret
    mov [rbx + J_VIEWER], rax
    lea rdi, [rip + fk_article]
    mov esi, fk_article_len
    call body_object
    jc .Lcr_ret
    mov [rsp + 8], rax
    mov [rsp], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + fk_title]
    mov ecx, fk_title_len
    call required
    jc .Lcr_ret
    PARAM_TXT 1, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_description]
    mov ecx, fk_description_len
    call required
    jc .Lcr_ret
    PARAM_TXT 2, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    lea rdx, [rip + fk_body]
    mov ecx, fk_body_len
    call required
    jc .Lcr_ret
    PARAM_TXT 3, rax, rdx
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    call parse_taglist
    jc .Lcr_ret
    PARAM_ARR 4, rax, rdx
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 0, rax
    mov qword ptr [rbx + J_STMT], S_ARTICLE_CREATE
    mov qword ptr [rbx + J_NP], 5
    lea rax, [rip + co_create_done]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lcr_ret:
    add rsp, 24
    ret

co_create_done:
    CO_ENTER
    call co_first_row
    jc .Lccd_ret
    test rdx, rdx
    jnz .Lccd_500
    test rax, rax
    jz .Lccd_500
    mov rdi, rax
    call decode_row
    mov qword ptr [rbx + J_STATUS], 201
    mov edi, 1
    call emit_article
    jmp .Lccd_ret
.Lccd_500:
    call api_500
.Lccd_ret:
    CO_LEAVE

# ---------------------------------------------------------------- PUT /api/articles/:slug
ep_update_article:
    sub rsp, 24
    call auth_required
    jc .Lua_ret
    mov [rbx + J_VIEWER], rax
    lea rdi, [rip + fk_article]
    mov esi, fk_article_len
    call body_object
    jc .Lua_ret
    mov [rsp + 8], rax
    mov [rsp], rdx
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 0, rax, rdx                       # slug
    OPT_FIELD fk_title, 1, 1
    OPT_FIELD fk_description, 2, 1
    OPT_FIELD fk_body, 3, 1
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 4, rax
    mov qword ptr [rbx + J_STMT], S_ARTICLE_UPDATE
    mov qword ptr [rbx + J_NP], 5
    lea rax, [rip + co_update_article]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lua_ret:
    add rsp, 24
    ret

# co_update_article: row = (id, author, updated_count). None -> 404. author != viewer -> 403. Else re-read by id.
co_update_article:
    CO_ENTER
    call co_first_row
    jc .Lcua_ret
    test rdx, rdx
    jnz .Lcua_500
    test rax, rax
    jz .Lcua_404
    mov rdi, rax
    call decode_row
    mov rdi, [r14]                             # id col0
    call pgd_int8
    mov [rbx + J_ID], rax
    mov rdi, [r14 + 16]                         # author col1
    call pgd_int8
    cmp rax, [rbx + J_VIEWER]
    jne .Lcua_403
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 0, rax
    mov rax, [rbx + J_ID]
    PARAM_INT 1, rax
    mov qword ptr [rbx + J_STMT], S_ARTICLE_ID
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_article]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
    jmp .Lcua_ret
.Lcua_403:
    call api_403
    jmp .Lcua_ret
.Lcua_404:
    call api_404
    jmp .Lcua_ret
.Lcua_500:
    call api_500
.Lcua_ret:
    CO_LEAVE

# ---------------------------------------------------------------- DELETE /api/articles/:slug
ep_delete_article:
    sub rsp, 8
    call auth_required
    jc .Lda_ret
    mov [rbx + J_VIEWER], rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 0, rax, rdx
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 1, rax
    mov qword ptr [rbx + J_STMT], S_ARTICLE_DELETE
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_delete_article]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lda_ret:
    add rsp, 8
    ret

co_delete_article:
    CO_ENTER
    call co_first_row
    jc .Lcda_ret
    test rdx, rdx
    jnz .Lcda_500
    test rax, rax
    jz .Lcda_404
    mov rdi, rax
    call decode_row
    mov rdi, [r14]                             # author col0
    call pgd_int8
    cmp rax, [rbx + J_VIEWER]
    jne .Lcda_403
    call api_204
    jmp .Lcda_ret
.Lcda_403:
    call api_403
    jmp .Lcda_ret
.Lcda_404:
    call api_404
    jmp .Lcda_ret
.Lcda_500:
    call api_500
.Lcda_ret:
    CO_LEAVE

# ---------------------------------------------------------------- POST/DELETE /api/articles/:slug/favorite
ep_favorite_on:
    mov edi, S_FAVORITE
    jmp ep_favorite
ep_favorite_off:
    mov edi, S_UNFAVORITE
ep_favorite:
    sub rsp, 24
    mov [rsp], rdi                            # stmt
    call auth_required
    jc .Lfv_ret
    mov rcx, [rsp]
    mov [rbx + J_STMT], rcx
    mov [rbx + J_VIEWER], rax
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_favorite]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lfv_ret:
    add rsp, 24
    ret

co_favorite:
    CO_ENTER
    call co_first_row
    jc .Lcfv_ret
    test rdx, rdx
    jnz .Lcfv_500
    test rax, rax
    jz .Lcfv_404
    mov rdi, rax
    call decode_row
    mov rdi, [r14]                             # id col0
    call pgd_int8
    mov [rbx + J_ID], rax
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 0, rax
    mov rax, [rbx + J_ID]
    PARAM_INT 1, rax
    mov qword ptr [rbx + J_STMT], S_ARTICLE_ID
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_article]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
    jmp .Lcfv_ret
.Lcfv_404:
    call api_404
    jmp .Lcfv_ret
.Lcfv_500:
    call api_500
.Lcfv_ret:
    CO_LEAVE

# ================================================================ comments
# ---------------------------------------------------------------- GET /api/articles/:slug/comments
ep_comments:
    sub rsp, 8
    call auth_viewer
    jc .Lcm_ret
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov qword ptr [rbx + J_STMT], S_COMMENTS
    mov qword ptr [rbx + J_NP], 2
    lea rax, [rip + co_comments]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
.Lcm_ret:
    add rsp, 8
    ret

# co_comments: {"comments":[...]}. nrows == 0 -> 404. Skip rows whose c.id (col1) is NULL.
co_comments:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, COLS_BYTES + 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea r14, [rsp + 32]
    cmp r13, -1
    je .Lcc_500
    mov rdi, r12
    mov rsi, r13
    call seg_scan
    test rdx, rdx                             # the statement failed (e.g. 22021 on a NUL in the slug): 500
    jnz .Lcc_500
    test rcx, rcx
    jz .Lcc_404
    lea rdi, [r13*8 + 2048]
    call api_body
    mov rbp, rax
    PUTL_R rbp, lit_comments_open
    mov byte ptr [rsp + 16], 1
    mov [rsp], r12
.Lcc_loop:
    mov rdi, [rsp]
    lea rsi, [r12 + r13]
    call seg_next_row
    test rax, rax
    jz .Lcc_end
    mov r8, rax
    add rax, rdx
    mov [rsp], rax
    mov rdi, r8
    call decode_row
    mov rax, [r14 + 1*16 + 8]                   # c.id col1 len
    test rax, rax
    js .Lcc_loop
    cmp byte ptr [rsp + 16], 1
    je 1f
    mov byte ptr [rbp], ','
    inc rbp
1:  mov byte ptr [rsp + 16], 0
    mov rdi, [r14 + 8*16]                       # following col8
    call pgd_bool
    mov rcx, rax
    mov rdi, rbp
    mov rsi, r14
    mov edx, 1
    call r_comment
    mov rbp, rax
    jmp .Lcc_loop
.Lcc_end:
    mov byte ptr [rbp], ']'
    mov byte ptr [rbp + 1], '}'
    lea rdi, [rbp + 2]
    call api_send
    jmp .Lcc_ret
.Lcc_404:
    call api_404
    jmp .Lcc_ret
.Lcc_500:
    call api_500
.Lcc_ret:
    add rsp, COLS_BYTES + 32
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- POST /api/articles/:slug/comments
ep_add_comment:
    sub rsp, 24
    call auth_required
    jc .Lac_ret
    mov [rbx + J_VIEWER], rax
    lea rdi, [rip + fk_comment]
    mov esi, fk_comment_len
    call body_object
    jc .Lac_ret
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + fk_body]
    mov ecx, fk_body_len
    call required
    jc .Lac_ret
    PARAM_TXT 2, rax, rdx
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 0, rax, rdx
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 1, rax
    mov qword ptr [rbx + J_STMT], S_COMMENT_CREATE
    mov qword ptr [rbx + J_NP], 3
    lea rax, [rip + co_add_comment]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
.Lac_ret:
    add rsp, 24
    ret

co_add_comment:
    CO_ENTER
    call co_first_row
    jc .Lcac_ret
    test rdx, rdx
    jnz .Lcac_500
    test rax, rax
    jz .Lcac_404
    mov rdi, rax
    call decode_row
    mov qword ptr [rbx + J_STATUS], 201
    call emit_comment_created
    jmp .Lcac_ret
.Lcac_404:
    call api_404
    jmp .Lcac_ret
.Lcac_500:
    call api_500
.Lcac_ret:
    CO_LEAVE

# ---------------------------------------------------------------- DELETE /api/articles/:slug/comments/:id
ep_delete_comment:
    sub rsp, 8
    call auth_required
    jc .Ldc_ret
    mov [rbx + J_VIEWER], rax
    mov rdi, [rbx + J_SEG + 3*16]
    mov rsi, [rbx + J_SEG + 3*16 + 8]
    call http_parse_uint                        # rax value, rdx ok
    test rdx, rdx
    jz .Ldc_404
    PARAM_INT 0, rax
    mov rax, [rbx + J_SEG + 16]
    mov rdx, [rbx + J_SEG + 16 + 8]
    PARAM_TXT 1, rax, rdx
    mov rax, [rbx + J_VIEWER]
    PARAM_INT 2, rax
    mov qword ptr [rbx + J_STMT], S_COMMENT_DELETE
    mov qword ptr [rbx + J_NP], 3
    lea rax, [rip + co_delete_comment]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call db_write
    add rsp, 8
    ret
.Ldc_404:
    call api_404
.Ldc_ret:
    add rsp, 8
    ret

co_delete_comment:
    CO_ENTER
    call co_first_row
    jc .Lcdc_ret
    test rdx, rdx
    jnz .Lcdc_500
    test rax, rax
    jz .Lcdc_404
    mov rdi, rax
    call decode_row
    mov rdi, [r14]
    call pgd_int8
    cmp rax, [rbx + J_VIEWER]
    jne .Lcdc_403
    call api_204
    jmp .Lcdc_ret
.Lcdc_403:
    call api_403
    jmp .Lcdc_ret
.Lcdc_404:
    call api_404
    jmp .Lcdc_ret
.Lcdc_500:
    call api_500
.Lcdc_ret:
    CO_LEAVE

# ================================================================ GET /api/tags
ep_tags:
    sub rsp, 8
    mov qword ptr [rbx + J_STMT], S_TAGS
    mov qword ptr [rbx + J_NP], 0
    lea rax, [rip + co_tags]
    mov [rbx + J_CONT], rax
    mov rdi, rbx
    call readb_enqueue
    add rsp, 8
    ret

co_tags:
    CO_ENTER
    call co_first_row
    jc .Lct_ret
    test rax, rax
    jz .Lct_500
    test rdx, rdx
    jnz .Lct_500
    mov rdi, rax
    call decode_row
    lea rdi, [r13*8 + 1024]
    call api_body
    mov rdi, rax
    PUTL lit_tags_open
    mov rsi, [r14]
    mov rdx, [r14 + 8]
    call r_tags
    mov byte ptr [rax], '}'
    lea rdi, [rax + 1]
    call api_send
    jmp .Lct_ret
.Lct_500:
    call api_500
.Lct_ret:
    CO_LEAVE

# ================================================================ query parsing
# parse_query(): fill J_QV[0..4] (limit, offset, tag, author, favorited) with decoded {ptr,len}; -1 = absent.
parse_query:
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 8
    mov r12, [rbx + J_REQ + REQ_QUERY]
    mov r13, [rbx + J_REQ + REQ_QUERY_LEN]
    xor ebp, ebp
.Lpq_loop:
    cmp ebp, 5
    jae .Lpq_done
    mov rax, rbp
    shl rax, 4
    mov qword ptr [rbx + J_QV + rax + 8], -1
    test r12, r12
    jz .Lpq_next
    lea r14, [rip + qv_keys]
    mov eax, ebp
    shl eax, 4
    add r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14]
    mov rcx, [r14 + 8]
    call http_query_get                        # rax raw ptr (0 absent), rdx raw len
    test rax, rax
    jz .Lpq_next
    push rax
    push rdx
    lea rdi, [rdx + rdx*2]
    add rdi, 1
    call api_scr
    mov r14, rax                               # dst
    pop rdx
    pop rsi                                    # raw ptr
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, r14
    mov ecx, PCT_QUERY
    call http_pct_decode                       # outlen (>= 0, lossy)
    mov rcx, rbp
    shl rcx, 4
    mov [rbx + J_QV + rcx], r14
    mov [rbx + J_QV + rcx + 8], rax
.Lpq_next:
    inc ebp
    jmp .Lpq_loop
.Lpq_done:
    add rsp, 8
    pop rbp
    pop r14
    pop r13
    pop r12
    ret

# qv_filter(i) -> rax = ptr, rdx = len if J_QV[i] present and non-empty, else rax = 0.
qv_filter:
    shl rdi, 4
    mov rdx, [rbx + J_QV + rdi + 8]
    test rdx, rdx
    jle .Lqf_none                              # absent (-1) or empty (0)
    mov rax, [rbx + J_QV + rdi]
    ret
.Lqf_none:
    xor eax, eax
    ret

# page(): limit (slot1) and offset (slot2) from J_QV[0], J_QV[1]; CF set on 422.
page:
    sub rsp, 8
    mov rdx, [rbx + J_QV + 0*16 + 8]
    cmp rdx, -1
    je .Lpg_deflimit
    mov rdi, [rbx + J_QV + 0*16]
    mov rsi, rdx
    call http_parse_uint
    test rdx, rdx
    jz .Lpg_badlimit
    cmp rax, 1
    jl .Lpg_badlimit
    cmp rax, 100
    jg .Lpg_badlimit
    jmp .Lpg_setlimit
.Lpg_deflimit:
    mov eax, 20
.Lpg_setlimit:
    PARAM_INT 1, rax
    mov rdx, [rbx + J_QV + 1*16 + 8]
    cmp rdx, -1
    je .Lpg_defoffset
    mov rdi, [rbx + J_QV + 1*16]
    mov rsi, rdx
    call http_parse_uint
    test rdx, rdx
    jz .Lpg_badoffset
    jmp .Lpg_setoffset
.Lpg_defoffset:
    xor eax, eax
.Lpg_setoffset:
    PARAM_INT 2, rax
    add rsp, 8
    clc
    ret
.Lpg_badlimit:
    lea rdi, [rip + m_badlimit]
    mov esi, m_badlimit_len
    call api_422
    add rsp, 8
    stc
    ret
.Lpg_badoffset:
    lea rdi, [rip + m_badoffset]
    mov esi, m_badoffset_len
    call api_422
    add rsp, 8
    stc
    ret

# parse_taglist(obj, objlen) -> rax = pairs ptr, rdx = count (CF clear); or answers 422 (CF set).
parse_taglist:
    push r12
    push r13
    push r14
    push rbp
    sub rsp, JIT_SIZE + 24                    # [rsp] iterator, [rsp+JIT_SIZE] count
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + fk_taglist]
    mov ecx, fk_taglist_len
    call json_find
    test rax, rax
    jz .Lpt_empty
    cmp rcx, JT_NULL
    je .Lpt_empty
    cmp rcx, JT_ARRAY
    jne .Lpt_bad
    mov r14, rax                               # array ptr
    mov rbp, rdx                               # array len
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rsp]
    call json_arr_first                        # rax elem, rdx len, rcx type
    mov qword ptr [rsp + JIT_SIZE], 0
.Lpt_count:
    test rax, rax
    jz .Lpt_counted
    cmp rcx, JT_STRING
    jne .Lpt_bad
    cmp rdx, 3
    jb .Lpt_bad
    inc qword ptr [rsp + JIT_SIZE]
    lea rdi, [rsp]
    call json_arr_next
    jmp .Lpt_count
.Lpt_counted:
    mov rcx, [rsp + JIT_SIZE]
    test rcx, rcx
    jz .Lpt_empty
    mov rdi, rcx
    shl rdi, 4
    call api_scr
    mov r12, rax                               # pairs base
    mov rdi, r14
    mov rsi, rbp
    lea rdx, [rsp]
    call json_arr_first
    xor ebp, ebp
.Lpt_fill:
    test rax, rax
    jz .Lpt_done
    push rax
    push rdx
    mov rdi, rdx
    call api_scr                               # dst
    mov r9, rax
    pop rdx
    pop rsi                                    # token ptr
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, r9
    call json_str_decode                       # rax = outlen
    mov rcx, rbp
    shl rcx, 4
    mov [r12 + rcx], r9
    mov [r12 + rcx + 8], rax
    inc rbp
    lea rdi, [rsp]
    call json_arr_next
    jmp .Lpt_fill
.Lpt_done:
    mov rax, r12
    mov rdx, rbp
    add rsp, JIT_SIZE + 24
    pop rbp
    pop r14
    pop r13
    pop r12
    clc
    ret
.Lpt_empty:
    xor eax, eax
    xor edx, edx
    add rsp, JIT_SIZE + 24
    pop rbp
    pop r14
    pop r13
    pop r12
    clc
    ret
.Lpt_bad:
    lea rdi, [rip + m_taglist]
    mov esi, m_taglist_len
    call api_422
    add rsp, JIT_SIZE + 24
    pop rbp
    pop r14
    pop r13
    pop r12
    stc
    ret

.section .note.GNU-stack,"",@progbits
