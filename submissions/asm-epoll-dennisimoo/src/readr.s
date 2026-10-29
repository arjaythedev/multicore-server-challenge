# readr.s: response bodies for batched reads (Rust api.rs article_list / get_article / comments over the rows
# read_batch::demux hands one request), byte-identical to Rust. readb.s demuxes; these only render.
#
# rows = array of u64 DataRow message pointers (each at the 'D' type byte), n = how many. Rows are only read, and
# a shared row may appear in many requests' arrays. Each returns the body end in rax (dst needs readr_bound bytes):
#   readr_list(dst, rows, n) -> end      {"articles":[...],"articlesCount":N}
#       rows[0] with LIST_PACKED_COLS (19) columns: the packed header (count col 0, favorited ids col 16, followed
#       ids col 17), then the page's articles at column 1 (favorited = id col 1 in the favorited ids, following =
#       author id col 14 in the followed ids). Otherwise every row is (count, Article at column 1), and rows whose
#       column 1 is NULL (an empty page's padding row) are skipped.
#   readr_article(dst, rows, n) -> end | 0 (404: no rows) | -1 (500: unexpected shape)      {"article":...}
#       one row: the article with its own flags; two rows whose first has ARTICLE_PACKED_COLS (16) columns: the
#       header's flags (cols 9, 13), then the shared article row.
#   readr_comments(dst, rows, n) -> end | 0 (404)      {"comments":[...]}
#       rows[0] with COMMENTS_PACKED_COLS (12) columns: the packed header (article id col 0, NULL = no such
#       article; followed ids col 10), then comments at column 1 (following = author id col 9 in the followed ids).
#       Otherwise every row is (article id, Comment at column 1, following col 8). Rows with NULL column 1 are
#       skipped either way.
#   readr_bound(rows, n) -> bytes      6 * the rows' message bytes + 320 per row + 64: enough for any of the above.
.include "defs.inc"
.include "app.inc"

.equ RR_COLS, 24                        # columns decoded per row (the widest shape has 19)
.equ RR_LIST_PACKED, 19
.equ RR_COMMENTS_PACKED, 12
.equ RR_ARTICLE_PACKED, 16

# frame (after 5 pushes): [rsp] i, [rsp+8] count, [rsp+16] first, [rsp+24/32] ids ptr/len, cols at rsp+64
.equ RF_I, 0
.equ RF_COUNT, 8
.equ RF_FIRST, 16
.equ RF_IDS, 24
.equ RF_IDSLEN, 32
.equ RF_IDS2, 40
.equ RF_IDS2LEN, 48
.equ RF_COLS, 64
.equ RF_SIZE, RF_COLS + RR_COLS * 16

.section .rodata
rr_articles_open: .ascii "{\"articles\":["
ENDLIT rr_articles_open
rr_articles_count: .ascii "],\"articlesCount\":"
ENDLIT rr_articles_count
rr_article_open: .ascii "{\"article\":"
ENDLIT rr_article_open
rr_comments_open: .ascii "{\"comments\":["
ENDLIT rr_comments_open

.text

# .Lrr_row: rdi = DataRow message -> eax = its column count; decodes up to RR_COLS columns into the frame's
# cols (called from the frame owners below, so the frame is at rsp + 8).
.Lrr_row:
    lea rsi, [rsp + 8 + RF_COLS]
    mov edx, RR_COLS
    jmp pgr_datarow

# .Lrr_has(ids ptr, ids len, v) -> eax = 1 if the binary int8[] holds v. NULL or malformed arrays hold nothing.
# Clobbers rcx, rdx, r8-r10.
.Lrr_has:
    xor eax, eax
    cmp rsi, 20
    jl 3f                               # NULL, or an empty (0-dimension) array
    mov ecx, [rdi + 12]
    bswap ecx                           # element count
    lea r8, [rdi + 20]
    lea r9, [rdi + rsi]
    bswap rdx                           # compare in the array's byte order
1:  test ecx, ecx
    jle 3f
    lea r10, [r8 + 12]                  # {int32 length = 8, int64 value}
    cmp r10, r9
    ja 3f
    cmp [r8 + 4], rdx
    je 2f
    mov r8, r10
    dec ecx
    jmp 1b
2:  mov eax, 1
3:  ret

# RR_COMMA: a ',' before every element but the first (frame's first flag); rbx = output cursor.
.macro RR_COMMA
    cmp byte ptr [rsp + RF_FIRST], 0
    jne .Lrr_c\@
    mov byte ptr [rbx], ','
    inc rbx
.Lrr_c\@:
    mov byte ptr [rsp + RF_FIRST], 0
.endm

.macro RR_ENTER
    push rbx
    push r12
    push r13
    push r14
    push rbp
    sub rsp, RF_SIZE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.endm

.macro RR_LEAVE
    add rsp, RF_SIZE
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.endm

# ---------------------------------------------------------------- readr_list
.globl readr_list
.type readr_list, @function
readr_list:
    RR_ENTER
    PUTL_R rbx, rr_articles_open
    mov qword ptr [rsp + RF_COUNT], 0
    mov byte ptr [rsp + RF_FIRST], 1
    xor r14d, r14d                      # row index
    test r13, r13
    jz .Lrl_end
    mov rdi, [r12]
    call .Lrr_row
    cmp eax, RR_LIST_PACKED
    jne .Lrl_plain
    mov rdi, [rsp + RF_COLS]            # header: count, favorited ids, followed ids
    call pgd_int8
    mov [rsp + RF_COUNT], rax
    mov rax, [rsp + RF_COLS + 16*16]
    mov rcx, [rsp + RF_COLS + 16*16 + 8]
    mov [rsp + RF_IDS], rax
    mov [rsp + RF_IDSLEN], rcx
    mov rax, [rsp + RF_COLS + 17*16]
    mov rcx, [rsp + RF_COLS + 17*16 + 8]
    mov [rsp + RF_IDS2], rax
    mov [rsp + RF_IDS2LEN], rcx
    mov r14d, 1
.Lrl_packed:
    cmp r14, r13
    jae .Lrl_end
    mov rdi, [r12 + r14 * 8]
    call .Lrr_row
    inc r14
    mov rdi, [rsp + RF_COLS + 1*16]     # article id
    call pgd_int8
    mov rdi, [rsp + RF_IDS]
    mov rsi, [rsp + RF_IDSLEN]
    mov rdx, rax
    call .Lrr_has
    mov ebp, eax                        # favorited
    mov rdi, [rsp + RF_COLS + 14*16]    # author id
    call pgd_int8
    mov rdi, [rsp + RF_IDS2]
    mov rsi, [rsp + RF_IDS2LEN]
    mov rdx, rax
    call .Lrr_has
    mov r9d, eax                        # following
    RR_COMMA
    mov rdi, rbx
    lea rsi, [rsp + RF_COLS]
    mov edx, 1
    xor ecx, ecx                        # no body
    mov r8d, ebp
    call r_article
    mov rbx, rax
    jmp .Lrl_packed
.Lrl_plain:                             # rows[0] is already decoded
    inc r14
    mov rdi, [rsp + RF_COLS]
    call pgd_int8
    mov [rsp + RF_COUNT], rax
    cmp qword ptr [rsp + RF_COLS + 1*16 + 8], 0
    jl 1f                               # NULL id: padding row
    RR_COMMA
    mov rdi, rbx
    lea rsi, [rsp + RF_COLS]
    mov edx, 1
    xor ecx, ecx
    call r_article_row
    mov rbx, rax
1:  cmp r14, r13
    jae .Lrl_end
    mov rdi, [r12 + r14 * 8]
    call .Lrr_row
    jmp .Lrl_plain
.Lrl_end:
    PUTL_R rbx, rr_articles_count
    mov rdi, rbx
    mov rsi, [rsp + RF_COUNT]
    call jw_int
    mov byte ptr [rax], '}'
    inc rax
    RR_LEAVE
.size readr_list, .-readr_list

# ---------------------------------------------------------------- readr_article
.globl readr_article
.type readr_article, @function
readr_article:
    RR_ENTER
    xor eax, eax
    test r13, r13
    jz .Lra_ret                         # 404
    cmp r13, 1
    je .Lra_one
    cmp r13, 2
    jne .Lra_bad
    mov rdi, [r12]
    call .Lrr_row
    cmp eax, RR_ARTICLE_PACKED
    jne .Lra_bad
    mov rdi, [rsp + RF_COLS + 9*16]
    call pgd_bool
    mov ebp, eax                        # favorited
    mov rdi, [rsp + RF_COLS + 13*16]
    call pgd_bool
    mov r14d, eax                       # following
    mov rdi, [r12 + 8]
    call .Lrr_row
    PUTL_R rbx, rr_article_open
    mov rdi, rbx
    lea rsi, [rsp + RF_COLS]
    xor edx, edx
    mov ecx, 1                          # with body
    mov r8d, ebp
    mov r9d, r14d
    call r_article
    jmp .Lra_close
.Lra_one:
    mov rdi, [r12]
    call .Lrr_row
    PUTL_R rbx, rr_article_open
    mov rdi, rbx
    lea rsi, [rsp + RF_COLS]
    xor edx, edx
    mov ecx, 1
    call r_article_row
.Lra_close:
    mov byte ptr [rax], '}'
    inc rax
.Lra_ret:
    RR_LEAVE
.Lra_bad:
    mov rax, -1
    jmp .Lra_ret
.size readr_article, .-readr_article

# ---------------------------------------------------------------- readr_comments
.globl readr_comments
.type readr_comments, @function
readr_comments:
    RR_ENTER
    xor eax, eax
    test r13, r13
    jz .Lrc_ret                         # 404
    mov rdi, [r12]
    call .Lrr_row
    xor ebp, ebp                        # 1 = packed
    cmp eax, RR_COMMENTS_PACKED
    jne 1f
    xor eax, eax
    cmp qword ptr [rsp + RF_COLS + 8], 0
    jl .Lrc_ret                         # header without an article id: 404
    mov ebp, 1
    mov rax, [rsp + RF_COLS + 10*16]
    mov rcx, [rsp + RF_COLS + 10*16 + 8]
    mov [rsp + RF_IDS], rax
    mov [rsp + RF_IDSLEN], rcx
1:  PUTL_R rbx, rr_comments_open
    mov byte ptr [rsp + RF_FIRST], 1
    mov r14, rbp                        # packed: the comments start after the header
    test ebp, ebp
    jnz .Lrc_next
    jmp .Lrc_have                       # unpacked: rows[0] is already decoded
.Lrc_next:
    cmp r14, r13
    jae .Lrc_end
    mov rdi, [r12 + r14 * 8]
    call .Lrr_row
.Lrc_have:
    inc r14
    cmp qword ptr [rsp + RF_COLS + 1*16 + 8], 0
    jl .Lrc_next                        # NULL comment id: padding row
    test ebp, ebp
    jz 2f
    mov rdi, [rsp + RF_COLS + 9*16]     # author id
    call pgd_int8
    mov rdi, [rsp + RF_IDS]
    mov rsi, [rsp + RF_IDSLEN]
    mov rdx, rax
    call .Lrr_has
    jmp 3f
2:  mov rdi, [rsp + RF_COLS + 8*16]
    call pgd_bool
3:  mov ecx, eax                        # following
    RR_COMMA
    mov rdi, rbx
    lea rsi, [rsp + RF_COLS]
    mov edx, 1
    call r_comment
    mov rbx, rax
    jmp .Lrc_next
.Lrc_end:
    mov word ptr [rbx], 0x7d5d          # "]}"
    lea rax, [rbx + 2]
.Lrc_ret:
    RR_LEAVE
.size readr_comments, .-readr_comments

# ---------------------------------------------------------------- readr_bound
.globl readr_bound
.type readr_bound, @function
readr_bound:
    xor eax, eax                        # message bytes
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    mov rdx, [rdi + rcx * 8]
    mov edx, [rdx + 1]
    bswap edx
    lea rax, [rax + rdx + 1]
    inc rcx
    jmp 1b
2:  lea rax, [rax + rax * 2]
    add rax, rax                        # * 6
    imul rcx, rsi, 320
    lea rax, [rax + rcx + 64]
    ret
.size readr_bound, .-readr_bound

.section .note.GNU-stack,"",@progbits
