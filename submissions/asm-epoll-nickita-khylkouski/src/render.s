# render.s: response JSON, written straight from DataRow columns (Rust api.rs write_* functions, same bytes).
# Columns are arrays of {ptr, len} (16 B each, len -1 = NULL) as filled by pgr_datarow.
# Every function takes the output position in rdi and returns the new end in rax; callers guarantee space.
.include "defs.inc"
.include "app.inc"

.section .rodata
lit_p_user: .ascii "{\"username\":"
ENDLIT lit_p_user
lit_p_bio: .ascii ",\"bio\":"
ENDLIT lit_p_bio
lit_p_image: .ascii ",\"image\":"
ENDLIT lit_p_image
lit_p_following: .ascii ",\"following\":"
ENDLIT lit_p_following
lit_created: .ascii ",\"createdAt\":"
ENDLIT lit_created
lit_updated: .ascii ",\"updatedAt\":"
ENDLIT lit_updated
lit_a_slug: .ascii "{\"slug\":"
ENDLIT lit_a_slug
lit_a_title: .ascii ",\"title\":"
ENDLIT lit_a_title
lit_a_desc: .ascii ",\"description\":"
ENDLIT lit_a_desc
lit_a_body: .ascii ",\"body\":"
ENDLIT lit_a_body
lit_a_tags: .ascii ",\"tagList\":"
ENDLIT lit_a_tags
lit_a_fav: .ascii ",\"favorited\":"
ENDLIT lit_a_fav
lit_a_count: .ascii ",\"favoritesCount\":"
ENDLIT lit_a_count
lit_a_author: .ascii ",\"author\":"
ENDLIT lit_a_author
lit_c_id: .ascii "{\"id\":"
ENDLIT lit_c_id
lit_c_body: .ascii ",\"body\":"
ENDLIT lit_c_body
lit_u_email: .ascii "{\"user\":{\"email\":"
ENDLIT lit_u_email
lit_u_token: .ascii ",\"token\":"
ENDLIT lit_u_token
lit_u_username: .ascii ",\"username\":"
ENDLIT lit_u_username
lit_err_open: .ascii "{\"errors\":{\"body\":[\""
ENDLIT lit_err_open
lit_err_close: .ascii "\"]}}"
ENDLIT lit_err_close
lit_h_http: .ascii "HTTP/1.1 "
ENDLIT lit_h_http
lit_h_ok: .ascii " OK\r\nContent-Type: application/json\r\n"
ENDLIT lit_h_ok
lit_h_cl: .ascii "Content-Length: "
ENDLIT lit_h_cl
lit_h_gzip: .ascii "Content-Encoding: gzip\r\n"
ENDLIT lit_h_gzip
lit_h_close: .ascii "Connection: close\r\n"
ENDLIT lit_h_close


.text

# r_profile(dst, cols, k, following): {"username":..,"bio":..,"image":..,"following":..} from cols k..k+2.
.globl r_profile
r_profile:
    push rbx
    push r12
    push r13
    shl rdx, 4
    lea rbx, [rsi + rdx]
    mov r12, rcx
    PUTL lit_p_user
    mov rsi, [rbx]
    mov rdx, [rbx + 8]
    call jw_str
    mov rdi, rax
    PUTL lit_p_bio
    mov rsi, [rbx + 16]
    mov rdx, [rbx + 24]
    call jw_str_or_null
    mov rdi, rax
    PUTL lit_p_image
    mov rsi, [rbx + 32]
    mov rdx, [rbx + 40]
    call jw_str_or_null
    mov rdi, rax
    PUTL lit_p_following
    mov rsi, r12
    call jw_bool
    mov byte ptr [rax], '}'
    inc rax
    pop r13
    pop r12
    pop rbx
    ret

# r_tags(dst, ptr, len): a binary text[] (one dimension, or empty) as a JSON array of strings.
.globl r_tags
r_tags:
    push rbx
    push r12
    sub rsp, PAIT_SIZE + 8
    mov byte ptr [rdi], '['
    lea rbx, [rdi + 1]
    xor r12d, r12d                       # elements written
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rsp
    call pgd_array_first
.Lrt_loop:
    test rax, rax
    jz .Lrt_end
    test r12, r12
    jz 1f
    mov byte ptr [rbx], ','
    inc rbx
1:  inc r12
    mov rdi, rbx
    mov rsi, rax
    call jw_str                          # rdx = element length
    mov rbx, rax
    mov rdi, rsp
    call pgd_array_next
    jmp .Lrt_loop
.Lrt_end:
    mov byte ptr [rbx], ']'
    lea rax, [rbx + 1]
    add rsp, PAIT_SIZE + 8
    pop r12
    pop rbx
    ret

# r_times(dst, created_ptr, updated_ptr): ,"createdAt":"..","updatedAt":".." from two binary timestamptz values;
# equal values reuse the bytes already written (Rust json::times).
.globl r_times
r_times:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rsi
    mov r13, rdx
    PUTL lit_created
    mov r14, rdi                         # start of the createdAt value
    mov rbx, rdi
    mov rdi, r12
    call pgd_ts
    mov rdi, rbx
    mov rsi, rax
    call jw_ts
    mov rbx, rax                         # end of the createdAt value
    mov rdi, rax
    PUTL lit_updated
    mov rax, [r12]
    cmp rax, [r13]
    jne 1f
    mov rsi, r14
    mov rdx, rbx
    sub rdx, r14
    call rt_memcpy
    jmp 2f
1:  mov rbx, rdi
    mov rdi, r13
    call pgd_ts
    mov rdi, rbx
    mov rsi, rax
    call jw_ts
2:  add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# r_article(dst, cols, b, with_body, favorited, following): an Article from the sql.s column layout starting at
# column b (the id): id, slug, title, description, [body], created_at, updated_at, tags, count, (fav), username,
# bio, image, (following).
.globl r_article
r_article:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    shl rdx, 4
    lea rbx, [rsi + rdx]                 # column b
    mov r12, rcx
    mov r13, r8
    mov r14, r9
    PUTL lit_a_slug
    mov rsi, [rbx + 16]
    mov rdx, [rbx + 24]
    call jw_str
    mov rdi, rax
    PUTL lit_a_title
    mov rsi, [rbx + 32]
    mov rdx, [rbx + 40]
    call jw_str
    mov rdi, rax
    PUTL lit_a_desc
    mov rsi, [rbx + 48]
    mov rdx, [rbx + 56]
    call jw_str
    mov rdi, rax
    lea rbp, [rbx + 64]                  # k = b + 4
    test r12, r12
    jz 1f
    PUTL lit_a_body
    mov rsi, [rbp]
    mov rdx, [rbp + 8]
    call jw_str
    mov rdi, rax
    add rbp, 16
1:  PUTL lit_a_tags
    mov rsi, [rbp + 32]
    mov rdx, [rbp + 40]
    call r_tags
    mov rdi, rax
    mov rsi, [rbp]
    mov rdx, [rbp + 16]
    call r_times
    mov rdi, rax
    PUTL lit_a_fav
    mov rsi, r13
    call jw_bool
    mov rdi, rax
    PUTL lit_a_count
    mov rbx, rdi
    mov rdi, [rbp + 48]
    call pgd_int8
    mov rdi, rbx
    mov rsi, rax
    call jw_int
    mov rdi, rax
    PUTL lit_a_author
    mov rsi, rbp
    mov edx, 5
    mov rcx, r14
    call r_profile
    mov byte ptr [rax], '}'
    inc rax
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# r_article_row(dst, cols, b, with_body): r_article with favorited/following read from the row.
.globl r_article_row
r_article_row:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rax, [rdx + rcx + 4]             # k
    shl rax, 4
    lea rbp, [rsi + rax]
    mov rdi, [rbp + 64]                  # k + 4: favorited
    call pgd_bool
    mov [rsp], rax
    mov rdi, [rbp + 128]                 # k + 8: following
    call pgd_bool
    mov r9, rax
    mov r8, [rsp]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call r_article
    add rsp, 16
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# r_comment(dst, cols, b, following): {"id":..,"createdAt":..,"updatedAt":..,"body":..,"author":Profile} from
# (id, body, created_at, updated_at, username, bio, image) at column b. A NULL updated_at reads as created_at.
.globl r_comment
r_comment:
    push rbx
    push r12
    push r13
    shl rdx, 4
    lea rbx, [rsi + rdx]
    mov r12, rcx
    PUTL lit_c_id
    mov r13, rdi
    mov rdi, [rbx]
    call pgd_int8
    mov rdi, r13
    mov rsi, rax
    call jw_int
    mov rdi, rax
    mov rsi, [rbx + 32]
    mov rdx, [rbx + 48]
    cmp qword ptr [rbx + 56], 0
    jge 1f
    mov rdx, rsi                         # NULL updated_at (the SQL's NULLIF): same as created_at
1:  call r_times
    mov rdi, rax
    PUTL lit_c_body
    mov rsi, [rbx + 16]
    mov rdx, [rbx + 24]
    call jw_str
    mov rdi, rax
    PUTL lit_a_author
    mov rsi, rbx
    mov edx, 4
    mov rcx, r12
    call r_profile
    mov byte ptr [rax], '}'
    inc rax
    pop r13
    pop r12
    pop rbx
    ret

# r_user(dst, cols, tok, toklen): {"user":{"email","token","username","bio","image"}} from (id, username, email,
# bio, image).
.globl r_user
r_user:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    PUTL lit_u_email
    mov rsi, [rbx + 32]
    mov rdx, [rbx + 40]
    call jw_str
    mov rdi, rax
    PUTL lit_u_token
    mov rsi, r12
    mov rdx, r13
    call jw_str
    mov rdi, rax
    PUTL lit_u_username
    mov rsi, [rbx + 16]
    mov rdx, [rbx + 24]
    call jw_str
    mov rdi, rax
    PUTL lit_p_bio
    mov rsi, [rbx + 48]
    mov rdx, [rbx + 56]
    call jw_str_or_null
    mov rdi, rax
    PUTL lit_p_image
    mov rsi, [rbx + 64]
    mov rdx, [rbx + 72]
    call jw_str_or_null
    mov word ptr [rax], 0x7d7d           # "}}"
    add rax, 2
    pop r13
    pop r12
    pop rbx
    ret

# r_error(dst, msg, len): {"errors":{"body":["<msg>"]}} (messages need no escaping).
.globl r_error
r_error:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    PUTL lit_err_open
    mov rsi, r12
    mov rdx, r13
    call rt_memcpy
    mov rdi, rax
    PUTL lit_err_close
    mov rax, rdi
    pop r13
    pop r12
    pop rbx
    ret

# r_head(dst, status, content_len, flags) -> end: the Rust response head (flags: HW_CLOSE | HW_GZIP). 204 has no
# Content-Length.
.globl r_head
r_head:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    mov rbx, rcx
    PUTL lit_h_http
    mov rsi, r12
    call rt_utoa
    mov rdi, rax
    PUTL lit_h_ok
    test bl, HW_GZIP
    jz 3f
    PUTL lit_h_gzip
3:  cmp r12, 204
    je 1f
    PUTL lit_h_cl
    mov rsi, r13
    call rt_utoa
    mov rdi, rax
    mov word ptr [rdi], 0x0a0d
    add rdi, 2
1:  test bl, HW_CLOSE
    jz 2f
    PUTL lit_h_close
2:  mov word ptr [rdi], 0x0a0d
    lea rax, [rdi + 2]
    pop r13
    pop r12
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits
