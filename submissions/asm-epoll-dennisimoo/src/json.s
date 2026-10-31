# json.s: JSON request-body reader (validate / find / decode / array iteration) and response writer (strings,
# ints, timestamps, bools). Reader semantics match serde_json 1.0.154 parsing into a Value, as the Rust reference
# does (`serde_json::from_slice::<Value>`); writer output is byte-identical to the Rust escape.rs / json.rs.
#
# Reader (json_validate first, then json_find / json_arr_* / json_str_decode on its pieces):
#   json_validate(ptr, len) -> 1 | 0           exactly what serde_json accepts:
#       RFC 8259 grammar, whitespace = space \t \n \r, one value then only whitespace;
#       nesting depth <= 127 (serde's recursion limit 128 fails on the 128th open bracket);
#       strings: no raw byte < 0x20, valid UTF-8 (std::str::from_utf8 rules), escapes " \ / b f n r t uXXXX,
#       \uD800-\uDBFF must be followed by \uDC00-\uDFFF, a lone \uDC00-\uDFFF is invalid;
#       numbers: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)? and serde's f64 overflow check (1e309, 1e400,
#       a 1 followed by 310 zeros, ... are rejected as "number out of range"; underflow to 0 is fine).
#   json_find(obj, len, key, keylen) -> rax = value ptr | 0, rdx = value len, rcx = JT_* type
#       top-level member of an object whose decoded key equals key; the LAST duplicate wins (serde's Map).
#   json_str_decode(tok, toklen, dst) -> decoded length | -1     dst needs toklen bytes of room
#   json_arr_first(ptr, len, it) / json_arr_next(it) -> rax = elem ptr | 0, rdx = elem len, rcx = JT_* type
# The finders assume json_validate accepted the body: on other input they never read outside it, but what they
# return is unspecified.
#
# Writer (each returns the advanced dst in rax; dst needs 6 * len + 2 bytes for jw_str, 26 for jw_ts, 20 for
# jw_int, 5 for jw_bool; jw_str may leave scratch bytes between the returned end and that bound, the others write
# exactly their output):
#   jw_str(dst, ptr, len)    "..." escaping " \ \n \r \t as two characters and every other byte < 0x20 as
#                            \u00xx (lowercase hex; so \b and \f become \u0008 and \u000c, as escape.rs does);
#                            '/', DEL and non-ASCII bytes are copied as they are. SSE2, AVX2 or AVX-512BW+BMI2.
#   jw_str_or_null(dst, ptr, len)   len < 0 -> null
#   jw_int(dst, i64)  jw_bool(dst, v)  jw_ts(dst, micros since 2000-01-01) -> "YYYY-MM-DDTHH:MM:SS.mmmZ" quoted

.include "defs.inc"

# ---------------------------------------------------------------- helpers shared by the reader

# Skip JSON whitespace at rsi (bounded by rdx). Clobbers eax.
.macro SKIPWS
.Lws_loop\@:
    cmp rsi, rdx
    jae .Lws_done\@
    movzx eax, byte ptr [rsi]
    cmp eax, 0x20
    ja .Lws_done\@
    je .Lws_skip\@
    cmp eax, 0x09
    jb .Lws_done\@
    cmp eax, 0x0a
    jbe .Lws_skip\@
    cmp eax, 0x0d
    jne .Lws_done\@
.Lws_skip\@:
    inc rsi
    jmp .Lws_loop\@
.Lws_done\@:
.endm

# eax = bitmask of the bytes in xmm0 that are '"', '\' (xmm5, xmm6 hold those bytes) or < 0x20 or >= 0x80
# (xmm7 = 0x20 bytes: a signed compare catches both). Clobbers xmm1-xmm3.
.macro STRMASK
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm5
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm6
    movdqa xmm3, xmm7
    pcmpgtb xmm3, xmm0
    por xmm1, xmm2
    por xmm1, xmm3
    pmovmskb eax, xmm1
.endm

.text

# .Lhex_u: rsi at "\uXXXX" (bounded by rdx) -> eax = the code unit, rsi += 6. CF = 1 if malformed.
# Clobbers rcx, r8.
.Lhex_u:
    lea rcx, [rsi + 6]
    cmp rcx, rdx
    ja .Lhx_bad
    cmp word ptr [rsi], 0x755c          # "\u"
    jne .Lhx_bad
    lea r8, [rip + .Lhexv]
    movzx ecx, byte ptr [rsi + 2]
    mov eax, [r8 + rcx * 4]
    shl eax, 4
    movzx ecx, byte ptr [rsi + 3]
    or eax, [r8 + rcx * 4]
    shl eax, 4
    movzx ecx, byte ptr [rsi + 4]
    or eax, [r8 + rcx * 4]
    shl eax, 4
    movzx ecx, byte ptr [rsi + 5]
    or eax, [r8 + rcx * 4]
    test eax, 0xffff0000
    jnz .Lhx_bad
    add rsi, 6
    clc
    ret
.Lhx_bad:
    stc
    ret

# .Ldec_esc: rsi at a backslash inside a string (bounded by rdx) -> eax = the decoded UTF-8 bytes (little-endian
# packed), ecx = their count (1..4), rsi past the escape (a surrogate pair is one escape). CF = 1 if invalid
# (unknown escape, bad hex, lone or reversed surrogate: serde_json rejects all of them). Clobbers r8, r9.
.Ldec_esc:
    lea rcx, [rsi + 2]
    cmp rcx, rdx
    ja .Lde_bad
    movzx eax, byte ptr [rsi + 1]
    cmp eax, 0x75                       # 'u'
    je .Lde_u
    lea rcx, [rip + .Lesc_dec]
    movzx eax, byte ptr [rcx + rax]
    test eax, eax
    jz .Lde_bad
    add rsi, 2
    mov ecx, 1
    clc
    ret
.Lde_u:
    call .Lhex_u
    jc .Lde_bad
    cmp eax, 0x80
    jae 1f
    mov ecx, 1
    clc
    ret
1:  cmp eax, 0x800
    jae 2f
    mov ecx, eax                        # 2 bytes: 110xxxxx 10xxxxxx
    shr ecx, 6
    or ecx, 0xc0
    and eax, 0x3f
    or eax, 0x80
    shl eax, 8
    or eax, ecx
    mov ecx, 2
    clc
    ret
2:  lea ecx, [rax - 0xd800]
    cmp ecx, 0x800
    jae 3f
    cmp ecx, 0x400                      # a trailing surrogate first
    jae .Lde_bad
    mov r9d, ecx                        # leading surrogate - 0xd800
    call .Lhex_u                        # must be followed by \u + a trailing surrogate
    jc .Lde_bad
    sub eax, 0xdc00
    cmp eax, 0x400
    jae .Lde_bad
    shl r9d, 10
    add eax, r9d
    add eax, 0x10000                    # code point
    mov ecx, eax                        # 4 bytes: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    shr ecx, 18
    or ecx, 0xf0
    mov r8d, eax
    shr r8d, 12
    and r8d, 0x3f
    or r8d, 0x80
    shl r8d, 8
    or ecx, r8d
    mov r8d, eax
    shr r8d, 6
    and r8d, 0x3f
    or r8d, 0x80
    shl r8d, 16
    or ecx, r8d
    and eax, 0x3f
    or eax, 0x80
    shl eax, 24
    or eax, ecx
    mov ecx, 4
    clc
    ret
3:  mov ecx, eax                        # 3 bytes: 1110xxxx 10xxxxxx 10xxxxxx
    shr ecx, 12
    or ecx, 0xe0
    mov r8d, eax
    shr r8d, 6
    and r8d, 0x3f
    or r8d, 0x80
    shl r8d, 8
    or ecx, r8d
    and eax, 0x3f
    or eax, 0x80
    shl eax, 16
    or eax, ecx
    mov ecx, 3
    clc
    ret
.Lde_bad:
    stc
    ret

# .Lutf8_seq: rsi at a byte >= 0x80 (bounded by rdx): one well-formed UTF-8 sequence (no overlongs, surrogates
# or code points above U+10FFFF), rsi past it. CF = 1 if invalid. Clobbers eax, ecx.
.Lutf8_seq:
    movzx eax, byte ptr [rsi]
    cmp eax, 0xc2
    jb .Lu8_bad
    cmp eax, 0xe0
    jae .Lu8_3
    lea rcx, [rsi + 2]
    cmp rcx, rdx
    ja .Lu8_bad
    movzx ecx, byte ptr [rsi + 1]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu8_bad
    add rsi, 2
    clc
    ret
.Lu8_3:
    cmp eax, 0xf0
    jae .Lu8_4
    lea rcx, [rsi + 3]
    cmp rcx, rdx
    ja .Lu8_bad
    movzx ecx, byte ptr [rsi + 1]
    cmp eax, 0xe0
    je .Lu8_e0
    cmp eax, 0xed
    je .Lu8_ed
    sub ecx, 0x80                       # 80..bf
    cmp ecx, 0x3f
    ja .Lu8_bad
    jmp .Lu8_3b
.Lu8_e0:
    sub ecx, 0xa0                       # a0..bf
    cmp ecx, 0x1f
    ja .Lu8_bad
    jmp .Lu8_3b
.Lu8_ed:
    sub ecx, 0x80                       # 80..9f
    cmp ecx, 0x1f
    ja .Lu8_bad
.Lu8_3b:
    movzx ecx, byte ptr [rsi + 2]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu8_bad
    add rsi, 3
    clc
    ret
.Lu8_4:
    cmp eax, 0xf4
    ja .Lu8_bad
    lea rcx, [rsi + 4]
    cmp rcx, rdx
    ja .Lu8_bad
    movzx ecx, byte ptr [rsi + 1]
    cmp eax, 0xf0
    je .Lu8_f0
    cmp eax, 0xf4
    je .Lu8_f4
    sub ecx, 0x80                       # 80..bf
    cmp ecx, 0x3f
    ja .Lu8_bad
    jmp .Lu8_4b
.Lu8_f0:
    sub ecx, 0x90                       # 90..bf
    cmp ecx, 0x2f
    ja .Lu8_bad
    jmp .Lu8_4b
.Lu8_f4:
    sub ecx, 0x80                       # 80..8f
    cmp ecx, 0x0f
    ja .Lu8_bad
.Lu8_4b:
    movzx ecx, byte ptr [rsi + 2]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu8_bad
    movzx ecx, byte ptr [rsi + 3]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu8_bad
    add rsi, 4
    clc
    ret
.Lu8_bad:
    stc
    ret

# .Lvstr: validate a string body; rsi just past the opening quote (bounded by rdx), xmm5-7 = STRMASK constants.
# rsi past the closing quote; CF = 1 if invalid. Clobbers rax, rcx, r8, r9, xmm0-xmm3.
.Lvstr:
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, 16
    jb .Lvs_short
    movdqu xmm0, [rsi]
    STRMASK
    test eax, eax
    jnz .Lvs_hit
    add rsi, 16
    jmp .Lvstr
.Lvs_hit:
    bsf eax, eax
    add rsi, rax
.Lvs_special:
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Lvs_end
    cmp eax, 0x5c
    je .Lvs_esc
    cmp eax, 0x80
    jb .Lvs_bad                         # raw control character
    call .Lutf8_seq
    jc .Lvs_bad
    jmp .Lvstr
.Lvs_esc:
    call .Ldec_esc
    jc .Lvs_bad
    jmp .Lvstr
.Lvs_short:
    test rcx, rcx
    jz .Lvs_bad                         # no closing quote
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Lvs_end
    cmp eax, 0x5c
    je .Lvs_esc
    lea ecx, [rax - 0x20]
    cmp ecx, 0x5f                       # 0x20..0x7f are themselves
    ja .Lvs_special
    inc rsi
    jmp .Lvstr
.Lvs_end:
    inc rsi
    clc
    ret
.Lvs_bad:
    stc
    ret

# .Lskip_str: rsi just past the opening quote of a valid string (bounded by rdx), xmm5/xmm6 = '"' / '\' bytes.
# rsi past the closing quote, r9d = 1 if the string has a backslash. CF = 1 if unterminated. Clobbers eax, ecx,
# xmm0, xmm1.
.Lskip_str:
    xor r9d, r9d
.Lss_loop:
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, 16
    jb .Lss_short
    movdqu xmm0, [rsi]
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm5
    pcmpeqb xmm0, xmm6
    por xmm0, xmm1
    pmovmskb eax, xmm0
    test eax, eax
    jnz .Lss_hit
    add rsi, 16
    jmp .Lss_loop
.Lss_hit:
    bsf eax, eax
    add rsi, rax
.Lss_at:
    cmp byte ptr [rsi], 0x22
    je .Lss_end
    mov r9d, 1                          # a backslash: skip it and the byte it escapes
    add rsi, 2
    cmp rsi, rdx
    ja .Lss_bad
    jmp .Lss_loop
.Lss_short:
    test rcx, rcx
    jz .Lss_bad
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Lss_end
    cmp eax, 0x5c
    je .Lss_at
    inc rsi
    jmp .Lss_loop
.Lss_end:
    inc rsi
    clc
    ret
.Lss_bad:
    stc
    ret

# .Lskip_val: rsi at the first byte of a valid value (bounded by rdx), xmm5/xmm6 as for .Lskip_str.
# rsi past the value, eax = JT_* type (0 if malformed). Clobbers rcx, r8, r9, r10, xmm0, xmm1.
.Lskip_val:
    cmp rsi, rdx
    jae .Lsv_bad
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Lsv_str
    cmp eax, 0x7b
    je .Lsv_obj
    cmp eax, 0x5b
    je .Lsv_arr
    cmp eax, 0x74                       # t
    je .Lsv_true
    cmp eax, 0x66                       # f
    je .Lsv_false
    cmp eax, 0x6e                       # n
    je .Lsv_null
    cmp eax, 0x2d
    je .Lsv_num
    lea ecx, [rax - 0x30]
    cmp ecx, 9
    jbe .Lsv_num
.Lsv_bad:
    xor eax, eax
    ret
.Lsv_str:
    inc rsi
    call .Lskip_str
    jc .Lsv_bad
    mov eax, JT_STRING
    ret
.Lsv_true:
    mov r10d, JT_TRUE
    mov ecx, 4
    jmp .Lsv_lit
.Lsv_false:
    mov r10d, JT_FALSE
    mov ecx, 5
    jmp .Lsv_lit
.Lsv_null:
    mov r10d, JT_NULL
    mov ecx, 4
.Lsv_lit:
    add rsi, rcx
    cmp rsi, rdx
    ja .Lsv_bad
    mov eax, r10d
    ret
.Lsv_num:
    inc rsi
.Lsv_num_loop:
    cmp rsi, rdx
    jae .Lsv_num_end
    movzx eax, byte ptr [rsi]
    lea ecx, [rax - 0x30]
    cmp ecx, 9
    jbe .Lsv_num_next
    cmp eax, 0x2e                       # .
    je .Lsv_num_next
    cmp eax, 0x2b                       # +
    je .Lsv_num_next
    cmp eax, 0x2d                       # -
    je .Lsv_num_next
    or eax, 0x20
    cmp eax, 0x65                       # e E
    jne .Lsv_num_end
.Lsv_num_next:
    inc rsi
    jmp .Lsv_num_loop
.Lsv_num_end:
    mov eax, JT_NUMBER
    ret
.Lsv_obj:
    mov r10d, JT_OBJECT
    jmp .Lsv_nest
.Lsv_arr:
    mov r10d, JT_ARRAY
.Lsv_nest:
    inc rsi
    mov r8d, 1                          # open brackets
.Lsn_loop:
    cmp rsi, rdx
    jae .Lsv_bad
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp eax, 0x22
    je .Lsn_str
    or eax, 0x20                        # [ ] -> { }
    cmp eax, 0x7b
    je .Lsn_open
    cmp eax, 0x7d
    jne .Lsn_loop
    dec r8d
    jnz .Lsn_loop
    mov eax, r10d
    ret
.Lsn_open:
    inc r8d
    jmp .Lsn_loop
.Lsn_str:
    call .Lskip_str
    jc .Lsv_bad
    jmp .Lsn_loop

# ---------------------------------------------------------------- json_validate

.globl json_validate
.type json_validate, @function
json_validate:
    sub rsp, 136                        # [rsp + depth] = 1 for an object, 0 for an array
    lea rdx, [rdi + rsi]
    mov rsi, rdi
    xor r11d, r11d                      # depth
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    movdqa xmm7, [rip + .Lc_20]
.Lv_value:
    SKIPWS
    cmp rsi, rdx
    jae .Lv_fail
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Lv_str
    cmp eax, 0x7b
    je .Lv_obj
    cmp eax, 0x5b
    je .Lv_arr
    cmp eax, 0x74
    je .Lv_true
    cmp eax, 0x66
    je .Lv_false
    cmp eax, 0x6e
    je .Lv_null
    cmp eax, 0x2d
    je .Lv_num
    lea ecx, [rax - 0x30]
    cmp ecx, 9
    jbe .Lv_num
    jmp .Lv_fail

.Lv_true:
    lea rcx, [rsi + 4]
    cmp rcx, rdx
    ja .Lv_fail
    cmp dword ptr [rsi], 0x65757274     # "true"
    jne .Lv_fail
    mov rsi, rcx
    jmp .Lv_after
.Lv_false:
    lea rcx, [rsi + 5]
    cmp rcx, rdx
    ja .Lv_fail
    cmp dword ptr [rsi + 1], 0x65736c61 # "alse"
    jne .Lv_fail
    mov rsi, rcx
    jmp .Lv_after
.Lv_null:
    lea rcx, [rsi + 4]
    cmp rcx, rdx
    ja .Lv_fail
    cmp dword ptr [rsi], 0x6c6c756e     # "null"
    jne .Lv_fail
    mov rsi, rcx
    jmp .Lv_after

.Lv_obj:
    inc r11
    cmp r11, 128                        # serde_json's recursion limit
    jae .Lv_fail
    mov byte ptr [rsp + r11], 1
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .Lv_fail
    cmp byte ptr [rsi], 0x7d
    je .Lv_close
.Lv_key:                                # rsi < rdx, at a non-whitespace byte
    cmp byte ptr [rsi], 0x22
    jne .Lv_fail
    inc rsi
    call .Lvstr
    jc .Lv_fail
    SKIPWS
    cmp rsi, rdx
    jae .Lv_fail
    cmp byte ptr [rsi], 0x3a            # :
    jne .Lv_fail
    inc rsi
    jmp .Lv_value
.Lv_arr:
    inc r11
    cmp r11, 128
    jae .Lv_fail
    mov byte ptr [rsp + r11], 0
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .Lv_fail
    cmp byte ptr [rsi], 0x5d
    jne .Lv_value
.Lv_close:
    inc rsi
    dec r11
    jmp .Lv_after
.Lv_str:
    inc rsi
    call .Lvstr
    jc .Lv_fail
.Lv_after:
    SKIPWS
    test r11, r11
    jz .Lv_top
    cmp rsi, rdx
    jae .Lv_fail
    movzx eax, byte ptr [rsi]
    cmp eax, 0x2c
    je .Lv_comma
    cmp byte ptr [rsp + r11], 0
    jne .Lv_in_obj
    cmp eax, 0x5d
    je .Lv_close
    jmp .Lv_fail
.Lv_in_obj:
    cmp eax, 0x7d
    je .Lv_close
    jmp .Lv_fail
.Lv_comma:
    inc rsi
    cmp byte ptr [rsp + r11], 0
    je .Lv_value
    SKIPWS
    cmp rsi, rdx
    jae .Lv_fail
    jmp .Lv_key
.Lv_top:
    cmp rsi, rdx
    jne .Lv_fail                        # trailing characters
    mov eax, 1
    add rsp, 136
    ret
.Lv_fail:
    xor eax, eax
    add rsp, 136
    ret

# Numbers, exactly as serde_json's parse_integer / parse_decimal / parse_exponent / f64_from_parts (default
# features): r8 = significand (u64), r9 = decimal exponent. The only rejection beyond the grammar is a result
# that overflows f64.
.Lv_num:
    cmp eax, 0x2d
    jne 1f
    inc rsi
    cmp rsi, rdx
    jae .Lv_fail
    movzx eax, byte ptr [rsi]
1:  xor r9d, r9d
    sub eax, 0x30
    cmp eax, 9
    ja .Lv_fail
    inc rsi
    mov r8, rax
    mov r10, 1844674407370955161        # u64::MAX / 10
    test eax, eax
    jnz .Lv_int
    cmp rsi, rdx                        # a leading 0 can't be followed by a digit
    jae .Lv_num_end
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    jbe .Lv_fail
    jmp .Lv_frac_or_exp
.Lv_int:
    cmp rsi, rdx
    jae .Lv_num_end
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    ja .Lv_frac_or_exp
    cmp r8, r10                         # significand * 10 + digit would overflow u64
    ja .Lv_long
    jb 2f
    cmp eax, 5
    ja .Lv_long
2:  lea r8, [r8 + r8 * 4]
    lea r8, [rax + r8 * 2]
    inc rsi
    jmp .Lv_int
.Lv_long:                               # parse_long_integer: the remaining digits only raise the exponent
    inc rsi
    inc r9
    cmp rsi, rdx
    jae .Lv_num_end
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    jbe .Lv_long
.Lv_frac_or_exp:                        # rsi < rdx, at a non-digit
    movzx eax, byte ptr [rsi]
    cmp eax, 0x2e
    je .Lv_frac
    or eax, 0x20
    cmp eax, 0x65
    je .Lv_exp
    jmp .Lv_num_end
.Lv_frac:
    inc rsi
    xor ecx, ecx                        # fraction digits taken into the significand
.Lv_frac_loop:
    cmp rsi, rdx
    jae .Lv_frac_end
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    ja .Lv_frac_end
    cmp r8, r10
    ja .Lv_frac_ovf
    jb 3f
    cmp eax, 5
    ja .Lv_frac_ovf
3:  lea r8, [r8 + r8 * 4]
    lea r8, [rax + r8 * 2]
    inc rsi
    inc ecx
    jmp .Lv_frac_loop
.Lv_frac_ovf:                           # parse_decimal_overflow: ignore the remaining digits
    sub r9, rcx
4:  inc rsi
    cmp rsi, rdx
    jae .Lv_num_end
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    jbe 4b
    jmp .Lv_maybe_exp
.Lv_frac_end:
    test ecx, ecx                       # at least one digit after the point
    jz .Lv_fail
    sub r9, rcx
.Lv_maybe_exp:
    cmp rsi, rdx
    jae .Lv_num_end
    movzx eax, byte ptr [rsi]
    or eax, 0x20
    cmp eax, 0x65
    jne .Lv_num_end
.Lv_exp:
    inc rsi
    cmp rsi, rdx
    jae .Lv_fail
    movzx eax, byte ptr [rsi]
    xor edi, edi                        # 1 = negative exponent
    cmp eax, 0x2b
    je 5f
    cmp eax, 0x2d
    jne 6f
    mov edi, 1
5:  inc rsi
    cmp rsi, rdx
    jae .Lv_fail
    movzx eax, byte ptr [rsi]
6:  sub eax, 0x30
    cmp eax, 9
    ja .Lv_fail
    inc rsi
    mov ecx, eax                        # exponent digits (i32)
.Lv_exp_loop:
    cmp rsi, rdx
    jae .Lv_exp_done
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    ja .Lv_exp_done
    inc rsi
    cmp ecx, 214748364                  # i32::MAX / 10
    ja .Lv_exp_ovf
    jb 7f
    cmp eax, 7
    ja .Lv_exp_ovf
7:  lea ecx, [rcx + rcx * 4]
    lea ecx, [rax + rcx * 2]
    jmp .Lv_exp_loop
.Lv_exp_ovf:                            # parse_exponent_overflow: +inf is an error, the rest is 0
    test edi, edi
    jnz 8f
    test r8, r8
    jnz .Lv_fail
8:  cmp rsi, rdx
    jae .Lv_after
    movzx eax, byte ptr [rsi]
    sub eax, 0x30
    cmp eax, 9
    ja .Lv_after
    inc rsi
    jmp 8b
.Lv_exp_done:
    test edi, edi
    jz 9f
    neg rcx
9:  add r9, rcx                         # saturating i32 add, as serde does
    mov rax, 0x7fffffff
    cmp r9, rax
    cmovg r9, rax
    mov rax, -0x80000000
    cmp r9, rax
    cmovl r9, rax
.Lv_num_end:                            # f64_from_parts(r8, r9): only a positive exponent can overflow
    test r9, r9
    js .Lv_after
    test r8, r8
    jz .Lv_after
    cmp r9, 308
    ja .Lv_fail                         # beyond POW10 with a nonzero significand
    pxor xmm0, xmm0
    test r8, r8
    js 10f
    cvtsi2sd xmm0, r8
    jmp 11f
10: mov rax, r8                         # u64 -> f64, round to nearest even
    shr rax, 1
    and r8d, 1
    or rax, r8
    cvtsi2sd xmm0, rax
    addsd xmm0, xmm0
11: lea rax, [rip + .Lpow10]
    mulsd xmm0, [rax + r9 * 8]
    movq rax, xmm0
    mov rcx, 0x7ff0000000000000
    cmp rax, rcx
    je .Lv_fail                         # infinite
    jmp .Lv_after
.size json_validate, .-json_validate

# ---------------------------------------------------------------- json_find

.globl json_find
.type json_find, @function
json_find:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdx                        # key
    mov r13, rcx                        # key length
    lea rdx, [rdi + rsi]
    mov rsi, rdi
    xor r14d, r14d                      # best match: ptr, len, type
    xor r15d, r15d
    xor ebx, ebx
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    SKIPWS
    cmp rsi, rdx
    jae .Lf_none
    cmp byte ptr [rsi], 0x7b
    jne .Lf_none
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .Lf_none
    cmp byte ptr [rsi], 0x7d
    je .Lf_done
.Lf_member:
    cmp byte ptr [rsi], 0x22
    jne .Lf_none
    inc rsi
    mov rdi, rsi                        # raw key
    call .Lskip_str
    jc .Lf_none
    lea rcx, [rsi - 1]
    sub rcx, rdi                        # raw key length
    xor r11d, r11d                      # 1 = this key matches
    test r9d, r9d
    jnz .Lf_cmp_esc
    cmp rcx, r13
    jne .Lf_key_done
    xor r8d, r8d
.Lf_cmp8:
    lea rax, [r8 + 8]
    cmp rax, rcx
    ja .Lf_cmp1
    mov rax, [rdi + r8]
    cmp rax, [r12 + r8]
    jne .Lf_key_done
    add r8, 8
    jmp .Lf_cmp8
.Lf_cmp1:
    cmp r8, rcx
    jae .Lf_match
    movzx eax, byte ptr [rdi + r8]
    cmp al, byte ptr [r12 + r8]
    jne .Lf_key_done
    inc r8
    jmp .Lf_cmp1
.Lf_match:
    mov r11d, 1
.Lf_key_done:
    SKIPWS
    cmp rsi, rdx
    jae .Lf_none
    cmp byte ptr [rsi], 0x3a
    jne .Lf_none
    inc rsi
    SKIPWS
    mov rdi, rsi                        # value
    call .Lskip_val
    test eax, eax
    jz .Lf_none
    test r11d, r11d
    jz 1f
    mov r14, rdi                        # later duplicates replace earlier ones
    mov r15, rsi
    sub r15, rdi
    mov ebx, eax
1:  SKIPWS
    cmp rsi, rdx
    jae .Lf_none
    movzx eax, byte ptr [rsi]
    cmp eax, 0x2c
    jne 2f
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .Lf_none
    jmp .Lf_member
2:  cmp eax, 0x7d
    jne .Lf_none
.Lf_done:
    mov rax, r14
    mov rdx, r15
    mov ecx, ebx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lf_none:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# A key with escapes: decode it as it is compared.
.Lf_cmp_esc:
    push rsi
    push rdx
    lea rdx, [rsi - 1]                  # the closing quote
    mov rsi, rdi
    xor r10d, r10d                      # index into key
.Lfe_loop:
    cmp rsi, rdx
    jae .Lfe_end
    movzx eax, byte ptr [rsi]
    cmp eax, 0x5c
    je .Lfe_esc
    cmp r10, r13
    jae .Lfe_no
    cmp al, byte ptr [r12 + r10]
    jne .Lfe_no
    inc rsi
    inc r10
    jmp .Lfe_loop
.Lfe_esc:
    call .Ldec_esc
    jc .Lfe_no
    lea r8, [r10 + rcx]
    cmp r8, r13
    ja .Lfe_no
.Lfe_byte:
    cmp al, byte ptr [r12 + r10]
    jne .Lfe_no
    inc r10
    shr eax, 8
    dec ecx
    jnz .Lfe_byte
    jmp .Lfe_loop
.Lfe_end:
    cmp r10, r13
    jne .Lfe_no
    mov r11d, 1
.Lfe_no:
    pop rdx
    pop rsi
    jmp .Lf_key_done
.size json_find, .-json_find

# ---------------------------------------------------------------- json_arr_first / json_arr_next
# Iterator (JIT_SIZE bytes): [0] = position after the last element, [8] = end of the array text.

.globl json_arr_first
.type json_arr_first, @function
json_arr_first:
    mov r11, rdx
    lea rdx, [rdi + rsi]
    mov rsi, rdi
    mov [r11 + 8], rdx
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    SKIPWS
    cmp rsi, rdx
    jae .La_none
    cmp byte ptr [rsi], 0x5b
    jne .La_none
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .La_none
    cmp byte ptr [rsi], 0x5d
    je .La_none
.La_elem:
    mov rdi, rsi
    call .Lskip_val
    test eax, eax
    jz .La_none
    mov [r11], rsi
    mov ecx, eax
    mov rax, rdi
    mov rdx, rsi
    sub rdx, rdi
    ret
.La_none:
    mov [r11], rdx                      # every later json_arr_next ends too
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret
.size json_arr_first, .-json_arr_first

.globl json_arr_next
.type json_arr_next, @function
json_arr_next:
    mov r11, rdi
    mov rsi, [r11]
    mov rdx, [r11 + 8]
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    SKIPWS
    cmp rsi, rdx
    jae .La_none
    cmp byte ptr [rsi], 0x2c
    jne .La_none
    inc rsi
    SKIPWS
    cmp rsi, rdx
    jae .La_none
    jmp .La_elem
.size json_arr_next, .-json_arr_next

# ---------------------------------------------------------------- json_str_decode
# Copies 16 bytes per step as it scans (the stores stay inside dst + toklen: output never runs ahead of input).

.globl json_str_decode
.type json_str_decode, @function
json_str_decode:
    cmp rsi, 2
    jb .Ld_fail
    cmp byte ptr [rdi], 0x22
    jne .Ld_fail
    lea r11, [rdi + rsi]                # token end
    lea rsi, [rdi + 1]
    mov rdi, rdx                        # output
    mov r10, rdx                        # output start
    mov rdx, r11
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    movdqa xmm7, [rip + .Lc_20]
.Ld_loop:
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, 16
    jb .Ld_short
    movdqu xmm0, [rsi]
    movdqu [rdi], xmm0
    STRMASK
    test eax, eax
    jnz .Ld_hit
    add rsi, 16
    add rdi, 16
    jmp .Ld_loop
.Ld_hit:
    bsf eax, eax
    add rsi, rax
    add rdi, rax
.Ld_special:
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Ld_end
    cmp eax, 0x5c
    je .Ld_esc
    cmp eax, 0x80
    jb .Ld_fail                         # raw control character
    mov r9, rsi
    call .Lutf8_seq
    jc .Ld_fail
    mov rcx, rsi                        # copy the 2..4 bytes
    sub rcx, r9
    movzx eax, word ptr [r9]
    mov [rdi], ax
    cmp ecx, 2
    je 1f
    movzx eax, byte ptr [r9 + 2]
    mov [rdi + 2], al
    cmp ecx, 3
    je 1f
    movzx eax, byte ptr [r9 + 3]
    mov [rdi + 3], al
1:  add rdi, rcx
    jmp .Ld_loop
.Ld_esc:
    call .Ldec_esc
    jc .Ld_fail
    cmp rsi, rdx                        # no closing quote left: fail before the store
    jae .Ld_fail
    mov [rdi], eax                      # in bounds: output lags input by >= 1, an escape is >= 2 bytes
    add rdi, rcx
    jmp .Ld_loop
.Ld_short:
    test rcx, rcx
    jz .Ld_fail
    movzx eax, byte ptr [rsi]
    cmp eax, 0x22
    je .Ld_end
    cmp eax, 0x5c
    je .Ld_esc
    lea ecx, [rax - 0x20]
    cmp ecx, 0x5f
    ja .Ld_special
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .Ld_loop
.Ld_end:
    inc rsi
    cmp rsi, rdx                        # the closing quote must end the token
    jne .Ld_fail
    mov rax, rdi
    sub rax, r10
    ret
.Ld_fail:
    mov rax, -1
    ret
.size json_str_decode, .-json_str_decode

# ---------------------------------------------------------------- jw_str
# rsi = input, r8 = input end, rdi = output, r10 = .Lesc_tab. Invariant: output <= 1 + 6 * input consumed, so
# with 6 * len + 2 bytes of room every store below (16/32 bytes only while that many input bytes remain, 6
# bytes per escape) stays inside it.

# Write the escape of the byte at rsi and step past it. Clobbers rax.
.macro ESCAPE
    movzx eax, byte ptr [rsi]
    inc rsi
    mov rax, [r10 + rax * 8]
    mov [rdi], eax
    shr rax, 32
    mov [rdi + 4], ax
    shr eax, 24
    add rdi, rax
.endm

# eax = bitmask of the bytes in xmm0 to escape (xmm5 = '"', xmm6 = '\', xmm7 = 0x1f). Clobbers xmm1-xmm3.
.macro ESCMASK
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm5
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm6
    movdqa xmm3, xmm0
    pminub xmm3, xmm7
    pcmpeqb xmm3, xmm0
    por xmm1, xmm2
    por xmm1, xmm3
    pmovmskb eax, xmm1
.endm

.globl jw_str
.type jw_str, @function
jw_str:
    mov eax, [rip + cpu_features]
    mov ecx, eax
    and ecx, CPU_AVX512 | CPU_BMI2
    cmp ecx, CPU_AVX512 | CPU_BMI2
    je jw_str_avx512
    test eax, CPU_AVX2
    jnz jw_str_avx2
    jmp jw_str_sse2
.size jw_str, .-jw_str

.globl jw_str_or_null
.type jw_str_or_null, @function
jw_str_or_null:
    test rdx, rdx
    jns jw_str
    mov dword ptr [rdi], 0x6c6c756e     # null
    lea rax, [rdi + 4]
    ret
.size jw_str_or_null, .-jw_str_or_null

# SSE2: 16 bytes per step, stored as they are checked (like escape.rs utf8_sse2). r9 = how many output bytes
# just before rdi are a verbatim copy of the input just before rsi (lets the last partial block be the input's
# last 16 bytes, stored over that copy).
.globl jw_str_sse2
.type jw_str_sse2, @function
jw_str_sse2:
    mov byte ptr [rdi], 0x22
    inc rdi
    lea r8, [rsi + rdx]
    xor r9d, r9d
    lea r10, [rip + .Lesc_tab]
.Ls_body:
    movdqa xmm5, [rip + .Lc_quote]
    movdqa xmm6, [rip + .Lc_bslash]
    movdqa xmm7, [rip + .Lc_1f]
.Ls_next:
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 16
    jb .Ls_tail
.Ls_loop:
    movdqu xmm0, [rsi]
    movdqu [rdi], xmm0
    ESCMASK
    test eax, eax
    jnz .Ls_esc
    add rsi, 16
    add rdi, 16
    add r9, 16
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 16
    jae .Ls_loop
    jmp .Ls_tail
.Ls_esc:                                # the block is stored; walk its mask instead of reloading per escape
    mov edx, eax
.Ls_esc_loop:                           # rdx = mask relative to rsi; the bytes before its first bit are in place
    bsf ecx, edx
    add rsi, rcx
    add rdi, rcx
    shr edx, cl
    ESCAPE
    shr edx, 1
    jz .Ls_esc_out
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 16
    jb .Ls_esc_out
    movdqu xmm0, [rsi]                  # the next escape is within these 16
    movdqu [rdi], xmm0
    jmp .Ls_esc_loop
.Ls_esc_out:
    xor r9d, r9d
    jmp .Ls_next
.Ls_tail:                               # rcx = bytes left, < 16
    test rcx, rcx
    jz .Ls_done
    mov r11d, 16
    sub r11, rcx                        # bytes of the last 16 already copied
    cmp r9, r11
    jb .Ls_small
    movdqu xmm0, [r8 - 16]
    mov rdx, rdi
    sub rdx, r11
    movdqu [rdx], xmm0
    ESCMASK
    mov ecx, r11d
    shr eax, cl
    test eax, eax
    jnz .Ls_tail_esc
    add rdi, r8
    sub rdi, rsi
    jmp .Ls_done
.Ls_tail_esc:
    bsf ecx, eax
    add rsi, rcx
    add rdi, rcx
    ESCAPE
    xor r9d, r9d
    mov rcx, r8
    sub rcx, rsi
    jmp .Ls_tail
.Ls_small:                              # 1..15 bytes: two overlapping 8- or 4-byte loads, else byte by byte
    cmp rcx, 8
    jb .Ls_4
    movq xmm0, [rsi]
    movq xmm1, [r8 - 8]
    punpcklqdq xmm0, xmm1
    ESCMASK
    test eax, eax
    jnz .Ls_bytes
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [r8 - 8]
    mov [rdi + rcx - 8], rax
    add rdi, rcx
    jmp .Ls_done
.Ls_4:
    cmp rcx, 4
    jb .Ls_bytes
    movd xmm0, [rsi]
    movd xmm1, [r8 - 4]
    punpckldq xmm0, xmm1
    ESCMASK
    test al, al
    jnz .Ls_bytes
    mov eax, [rsi]
    mov [rdi], eax
    mov eax, [r8 - 4]
    mov [rdi + rcx - 4], eax
    add rdi, rcx
    jmp .Ls_done
.Ls_bytes:
    cmp rsi, r8
    jae .Ls_done
    movzx eax, byte ptr [rsi]
    cmp eax, 0x5c
    je 1f
    cmp eax, 0x22
    je 1f
    cmp eax, 0x20
    jb 1f
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .Ls_bytes
1:  ESCAPE
    jmp .Ls_bytes
.Ls_done:
    mov byte ptr [rdi], 0x22
    lea rax, [rdi + 1]
    ret
.size jw_str_sse2, .-jw_str_sse2

# AVX2: 64 bytes per step (two ymm), one 32-byte step, then the SSE2 code for the last < 32.
.globl jw_str_avx2
.type jw_str_avx2, @function
jw_str_avx2:
    mov byte ptr [rdi], 0x22
    inc rdi
    lea r8, [rsi + rdx]
    xor r9d, r9d
    lea r10, [rip + .Lesc_tab]
    cmp rdx, 32
    jb .Ls_body
    vmovdqa ymm5, [rip + .Lc_quote]
    vmovdqa ymm6, [rip + .Lc_bslash]
    vmovdqa ymm7, [rip + .Lc_1f]
.La2_next:
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 64
    jb .La2_one
.La2_loop:
    vmovdqu ymm0, [rsi]
    vmovdqu ymm8, [rsi + 32]
    vmovdqu [rdi], ymm0
    vmovdqu [rdi + 32], ymm8
    vpcmpeqb ymm1, ymm0, ymm5
    vpcmpeqb ymm2, ymm0, ymm6
    vpminub ymm3, ymm0, ymm7
    vpcmpeqb ymm3, ymm3, ymm0
    vpor ymm1, ymm1, ymm2
    vpor ymm1, ymm1, ymm3
    vpcmpeqb ymm9, ymm8, ymm5
    vpcmpeqb ymm2, ymm8, ymm6
    vpminub ymm3, ymm8, ymm7
    vpcmpeqb ymm3, ymm3, ymm8
    vpor ymm9, ymm9, ymm2
    vpor ymm9, ymm9, ymm3
    vpor ymm2, ymm1, ymm9
    vptest ymm2, ymm2
    jnz .La2_esc64
    add rsi, 64
    add rdi, 64
    add r9, 64
    sub rcx, 64
    cmp rcx, 64
    jae .La2_loop
.La2_one:                               # rcx = bytes left, < 64
    cmp rcx, 32
    jb .La2_out
    vmovdqu ymm0, [rsi]
    vmovdqu [rdi], ymm0
    vpcmpeqb ymm1, ymm0, ymm5
    vpcmpeqb ymm2, ymm0, ymm6
    vpminub ymm3, ymm0, ymm7
    vpcmpeqb ymm3, ymm3, ymm0
    vpor ymm1, ymm1, ymm2
    vpor ymm1, ymm1, ymm3
    vpmovmskb edx, ymm1
    test edx, edx
    jnz .La2_esc_loop
    add rsi, 32
    add rdi, 32
    add r9, 32
.La2_out:
    vzeroupper
    jmp .Ls_body
.La2_esc64:
    vpmovmskb eax, ymm1
    vpmovmskb edx, ymm9
    shl rdx, 32
    or rdx, rax
.La2_esc_loop:                          # rdx = mask relative to rsi; the bytes before its first bit are in place
    bsf rcx, rdx
    add rsi, rcx
    add rdi, rcx
    shr rdx, cl
    ESCAPE
    shr rdx, 1
    jz .La2_esc_out
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 32
    jb .La2_esc_out
    vmovdqu ymm0, [rsi]
    vmovdqu [rdi], ymm0
    mov rax, rdx
    shr rax, 32
    jz .La2_esc_loop                    # the next escape is within these 32
    cmp rcx, 64
    jb .La2_esc_out
    vmovdqu ymm0, [rsi + 32]
    vmovdqu [rdi + 32], ymm0
    jmp .La2_esc_loop
.La2_esc_out:
    xor r9d, r9d
    jmp .La2_next
.size jw_str_avx2, .-jw_str_avx2

# AVX-512BW/VL + BMI2: 64 bytes per step (two ymm, masks in k registers), masked loads and stores for the last
# partial step (like escape.rs utf8_avx512), so it reads and writes only its own bytes.
.globl jw_str_avx512
.type jw_str_avx512, @function
jw_str_avx512:
    mov byte ptr [rdi], 0x22
    inc rdi
    lea r8, [rsi + rdx]
    lea r10, [rip + .Lesc_tab]
    vmovdqa ymm5, [rip + .Lc_quote]
    vmovdqa ymm6, [rip + .Lc_bslash]
    vmovdqa ymm7, [rip + .Lc_20]
    vmovdqa ymm4, [rip + .Lc_1f]
.Lx_loop:
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 64
    jb .Lx_lt64
.Lx_loop64:                             # vector compares (k-register compares all go to one port)
    vmovdqu ymm0, [rsi]
    vmovdqu ymm8, [rsi + 32]
    vmovdqu [rdi], ymm0
    vmovdqu [rdi + 32], ymm8
    vpcmpeqb ymm1, ymm0, ymm5
    vpcmpeqb ymm2, ymm0, ymm6
    vpminub ymm3, ymm0, ymm4
    vpcmpeqb ymm3, ymm3, ymm0
    vpor ymm1, ymm1, ymm2
    vpor ymm1, ymm1, ymm3
    vpcmpeqb ymm9, ymm8, ymm5
    vpcmpeqb ymm2, ymm8, ymm6
    vpminub ymm3, ymm8, ymm4
    vpcmpeqb ymm3, ymm3, ymm8
    vpor ymm9, ymm9, ymm2
    vpor ymm9, ymm9, ymm3
    vpor ymm2, ymm1, ymm9
    vptest ymm2, ymm2
    jnz .Lx_esc64
    add rsi, 64
    add rdi, 64
    sub rcx, 64
    cmp rcx, 64
    jae .Lx_loop64
.Lx_lt64:                               # rcx = bytes left, < 64
    test rcx, rcx
    jz .Lx_done
    cmp rcx, 32
    jb .Lx_tail
    vmovdqu8 ymm0, [rsi]
    vmovdqu8 [rdi], ymm0
    vpcmpub k1, ymm0, ymm7, 1
    vpcmpeqb k2, ymm0, ymm5
    vpcmpeqb k3, ymm0, ymm6
    kord k1, k1, k2
    kord k1, k1, k3
    kmovd edx, k1
    test edx, edx
    jnz .Lx_esc_loop
    add rsi, 32
    add rdi, 32
    sub rcx, 32
    jmp .Lx_lt64
.Lx_tail:                               # 1..31 bytes
    mov eax, -1
    bzhi eax, eax, ecx
    kmovd k4, eax
    vmovdqu8 ymm0{k4}{z}, [rsi]
    vmovdqu8 [rdi]{k4}, ymm0
    vpcmpub k1{k4}, ymm0, ymm7, 1
    vpcmpeqb k2{k4}, ymm0, ymm5
    vpcmpeqb k3{k4}, ymm0, ymm6
    kord k1, k1, k2
    kord k1, k1, k3
    kmovd edx, k1
    test edx, edx
    jnz .Lx_esc_loop
    add rdi, rcx
    jmp .Lx_done
.Lx_esc64:
    vpmovmskb eax, ymm1
    vpmovmskb edx, ymm9
    shl rdx, 32
    or rdx, rax
.Lx_esc_loop:                           # rdx = mask relative to rsi (bits only inside the input); the bytes
    bsf rcx, rdx                        # before its first bit are in place
    add rsi, rcx
    add rdi, rcx
    shrx rdx, rdx, rcx
    ESCAPE
    shr rdx, 1
    jz .Lx_loop
    mov rcx, r8
    sub rcx, rsi
    cmp rcx, 32
    jb .Lx_re_tail
    vmovdqu8 ymm0, [rsi]
    vmovdqu8 [rdi], ymm0
    mov rax, rdx
    shr rax, 32
    jz .Lx_esc_loop                     # the next escape is within these 32
    cmp rcx, 64
    jb .Lx_loop
    vmovdqu8 ymm0, [rsi + 32]
    vmovdqu8 [rdi + 32], ymm0
    jmp .Lx_esc_loop
.Lx_re_tail:                            # < 32 bytes left: copy all of them
    mov eax, -1
    bzhi eax, eax, ecx
    kmovd k4, eax
    vmovdqu8 ymm0{k4}{z}, [rsi]
    vmovdqu8 [rdi]{k4}, ymm0
    jmp .Lx_esc_loop
.Lx_done:
    vzeroupper
    mov byte ptr [rdi], 0x22
    lea rax, [rdi + 1]
    ret
.size jw_str_avx512, .-jw_str_avx512

# ---------------------------------------------------------------- jw_int, jw_bool

.globl jw_int
.type jw_int, @function
jw_int:
    mov rax, rsi
    test rax, rax
    jns 1f
    mov byte ptr [rdi], 0x2d
    inc rdi
    neg rax                             # i64::MIN stays 2^63 as unsigned
1:  cmp rax, 10
    jae 2f
    add eax, 0x30
    mov [rdi], al
    lea rax, [rdi + 1]
    ret
2:  bsr rcx, rax                        # digits = t or t + 1, t = bits * 1233 >> 12
    inc ecx
    imul ecx, ecx, 1233
    shr ecx, 12
    lea rdx, [rip + .Lp10]
    cmp rax, [rdx + rcx * 8]
    sbb rcx, -1
    lea r8, [rdi + rcx]                 # end
    mov rsi, r8
    lea r9, [rip + .Lpairs]
    mov r10, 0x28f5c28f5c28f5c3         # x / 100 = ((x >> 2) * this) >> 66
3:  cmp rax, 100
    jb 4f
    mov rcx, rax
    shr rax, 2
    mul r10
    shr rdx, 2
    imul rax, rdx, 100
    sub rcx, rax
    movzx eax, word ptr [r9 + rcx * 2]
    sub rsi, 2
    mov [rsi], ax
    mov rax, rdx
    jmp 3b
4:  cmp rax, 10
    jb 5f
    movzx eax, word ptr [r9 + rax * 2]
    mov [rsi - 2], ax
    mov rax, r8
    ret
5:  add eax, 0x30
    mov [rsi - 1], al
    mov rax, r8
    ret
.size jw_int, .-jw_int

.globl jw_bool
.type jw_bool, @function
jw_bool:
    test rsi, rsi
    jz 1f
    mov dword ptr [rdi], 0x65757274     # true
    lea rax, [rdi + 4]
    ret
1:  mov dword ptr [rdi], 0x736c6166     # fals
    mov byte ptr [rdi + 4], 0x65
    lea rax, [rdi + 5]
    ret
.size jw_bool, .-jw_bool

# ---------------------------------------------------------------- jw_ts
# micros since 2000-01-01 UTC -> "YYYY-MM-DDTHH:MM:SS.mmmZ" (quoted, milliseconds truncated toward -inf), as
# escape.rs ts_raw: Neri–Schneider in u32 for 0000-03-01..9999-12-31, Hinnant's civil_from_days otherwise
# (and its four-low-digit year text outside 0..9999). Divisions by constants are multiply-shifts, each exact
# over its input range (checked exhaustively by test/json).

.globl jw_ts
.type jw_ts, @function
jw_ts:
    mov rax, 63108720000000000          # (719468 + 10957) days in µs: u = µs since 0000-03-01
    add rax, rsi
    mov rcx, 315564336000000000         # 3652365 days: the fast range
    cmp rax, rcx
    jae .Lts_far
    mov r8, rax
    mov rcx, 114624077711609285
    mul rcx
    shr rdx, 29                         # day number since 0000-03-01 = u / 86400000000
    mov r9, rdx
    mov rcx, 86400000000
    imul rcx, rdx
    sub r8, rcx                         # µs into the day
    mov rax, r8
    mov rcx, 18446744073709552
    mul rcx
    mov r11, rdx                        # ms into the day = µs / 1000
    lea eax, [r9 + 11979954]            # n = days + 82 eras (Neri–Schneider, as escape.rs)
    lea eax, [rax * 4 + 3]              # n1
    imul rcx, rax, 15051803
    shr rcx, 41                         # century = n1 / 146097
    imul r8d, ecx, 146097
    mov edx, eax
    sub edx, r8d
    or edx, 3                           # n2
    imul rdx, rdx, 2939745              # p2
    mov r8, rdx
    shr r8, 32                          # year of century
    mov edx, edx
    imul rdx, rdx, 1531969483
    shr rdx, 54                         # day of year = (u32)p2 / 2939745 / 4
    imul r9d, edx, 2141
    add r9d, 197913                     # n3
    xor r10d, r10d
    cmp edx, 306
    setae r10b                          # January or February
    imul ecx, ecx, 100
    add ecx, r8d
    sub ecx, 32800
    add ecx, r10d                       # year
    mov r8d, r9d
    shr r8d, 16
    imul r10d, r10d, 12
    sub r8d, r10d                       # month
    movzx r9d, r9w
    imul r9d, r9d, 31345
    shr r9d, 26
    inc r9d                             # day = (n3 & 0xffff) / 2141 + 1
# ecx = year (0..9999), r8d = month, r9d = day, r11 = ms into the day
.Lts_digits:
    lea r10, [rip + .Lpairs]
    mov byte ptr [rdi], 0x22
    imul eax, ecx, 5243
    shr eax, 19                         # year / 100
    imul edx, eax, 100
    sub ecx, edx
    movzx eax, word ptr [r10 + rax * 2]
    mov [rdi + 1], ax
    movzx eax, word ptr [r10 + rcx * 2]
    mov [rdi + 3], ax
.Lts_rest:                              # r10 = .Lpairs
    mov byte ptr [rdi + 5], 0x2d
    movzx eax, word ptr [r10 + r8 * 2]
    mov [rdi + 6], ax
    mov byte ptr [rdi + 8], 0x2d
    movzx eax, word ptr [r10 + r9 * 2]
    mov [rdi + 9], ax
    mov byte ptr [rdi + 11], 0x54       # T
    imul rax, r11, 39093747
    shr rax, 47                         # hours = ms / 3600000
    imul edx, eax, 3600000
    sub r11d, edx
    movzx eax, word ptr [r10 + rax * 2]
    mov [rdi + 12], ax
    mov byte ptr [rdi + 14], 0x3a
    imul rax, r11, 4581299
    shr rax, 38                         # minutes = ms / 60000
    imul edx, eax, 60000
    sub r11d, edx
    movzx eax, word ptr [r10 + rax * 2]
    mov [rdi + 15], ax
    mov byte ptr [rdi + 17], 0x3a
    imul eax, r11d, 67109
    shr eax, 26                         # seconds = ms / 1000
    imul edx, eax, 1000
    sub r11d, edx
    movzx eax, word ptr [r10 + rax * 2]
    mov [rdi + 18], ax
    mov byte ptr [rdi + 20], 0x2e
    imul eax, r11d, 5243
    shr eax, 19                         # ms / 100
    imul edx, eax, 100
    sub r11d, edx
    add eax, 0x30
    mov [rdi + 21], al
    movzx eax, word ptr [r10 + r11 * 2]
    mov [rdi + 22], ax
    mov word ptr [rdi + 24], 0x225a     # Z"
    lea rax, [rdi + 26]
    ret

.Lts_far:                               # cold: escape.rs ts_far / ts_wide with i64 division
    mov rax, rsi
    cqo
    mov rcx, 1000
    idiv rcx
    test rdx, rdx
    jns 1f
    dec rax
1:  mov rcx, 946684800000
    add rax, rcx                        # ms since 1970
    cqo
    mov rcx, 86400000
    idiv rcx
    test rdx, rdx
    jns 2f
    dec rax
    add rdx, rcx
2:  mov r11, rdx                        # ms into the day
    add rax, 719468                     # z
    cqo
    mov rcx, 146097
    idiv rcx
    test rdx, rdx
    jns 3f
    dec rax
    add rdx, rcx
3:  mov r9, rax                         # era
    mov r10, rdx                        # day of era
    mov rax, r10
    xor edx, edx
    mov ecx, 1460
    div rcx
    mov r8, r10
    sub r8, rax
    mov rax, r10
    xor edx, edx
    mov ecx, 36524
    div rcx
    add r8, rax
    mov rax, r10
    xor edx, edx
    mov ecx, 146096
    div rcx
    sub r8, rax
    mov rax, r8
    xor edx, edx
    mov ecx, 365
    div rcx
    mov r8, rax                         # year of era
    imul rcx, r8, 365
    mov rax, r8
    shr rax, 2
    add rcx, rax
    mov rax, r8
    xor edx, edx
    mov esi, 100
    div rsi
    sub rcx, rax
    sub r10, rcx                        # day of year
    lea rax, [r10 + r10 * 4 + 2]
    xor edx, edx
    mov esi, 153
    div rsi
    mov rcx, rax                        # mp
    imul rax, rcx, 153
    add rax, 2
    xor edx, edx
    mov esi, 5
    div rsi
    sub r10, rax
    inc r10                             # day
    lea rax, [rcx + 3]
    lea rdx, [rcx - 9]
    cmp rcx, 10
    cmovae rax, rdx                     # month
    imul r9, r9, 400
    add r9, r8
    cmp rax, 2
    ja 4f
    inc r9                              # year
4:  mov r8, rax
    mov rcx, r9
    mov r9, r10
    cmp rcx, 9999
    jbe .Lts_digits
    mov byte ptr [rdi], 0x22            # ts_wide: (y / 10^k) % 10 per digit, truncating, as a wrapping byte
    mov r10, rcx
    mov rax, r10
    cqo
    mov esi, 1000
    idiv rsi
    cqo
    mov esi, 10
    idiv rsi
    add dl, 0x30
    mov [rdi + 1], dl
    mov rax, r10
    cqo
    mov esi, 100
    idiv rsi
    cqo
    mov esi, 10
    idiv rsi
    add dl, 0x30
    mov [rdi + 2], dl
    mov rax, r10
    cqo
    mov esi, 10
    idiv rsi
    cqo
    idiv rsi
    add dl, 0x30
    mov [rdi + 3], dl
    mov rax, r10
    cqo
    idiv rsi
    add dl, 0x30
    mov [rdi + 4], dl
    lea r10, [rip + .Lpairs]
    jmp .Lts_rest
.size jw_ts, .-jw_ts

# ---------------------------------------------------------------- constants
.section .rodata
.balign 32
.Lc_quote:  .fill 32, 1, 0x22
.Lc_bslash: .fill 32, 1, 0x5c
.Lc_20:     .fill 32, 1, 0x20
.Lc_1f:     .fill 32, 1, 0x1f

# ---- generated by test/json/gen_tables.py: do not edit by hand ----
.section .rodata
.balign 64
# jw_str: the escape of each byte below 0x5d (bytes 0..5 = text, byte 7 = length; 0 = not escaped)
.Lesc_tab:
    .quad 0x060030303030755c, 0x060031303030755c, 0x060032303030755c, 0x060033303030755c
    .quad 0x060034303030755c, 0x060035303030755c, 0x060036303030755c, 0x060037303030755c
    .quad 0x060038303030755c, 0x020000000000745c, 0x0200000000006e5c, 0x060062303030755c
    .quad 0x060063303030755c, 0x020000000000725c, 0x060065303030755c, 0x060066303030755c
    .quad 0x060030313030755c, 0x060031313030755c, 0x060032313030755c, 0x060033313030755c
    .quad 0x060034313030755c, 0x060035313030755c, 0x060036313030755c, 0x060037313030755c
    .quad 0x060038313030755c, 0x060039313030755c, 0x060061313030755c, 0x060062313030755c
    .quad 0x060063313030755c, 0x060064313030755c, 0x060065313030755c, 0x060066313030755c
    .quad 0x0000000000000000, 0x0000000000000000, 0x020000000000225c, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000
    .quad 0x0200000000005c5c
# json_str_decode: decoded byte for the character after a backslash (0 = not a short escape)
.Lesc_dec:
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5c, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00
    .byte 0x00, 0x00, 0x0d, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
# hex digit values (0xffff0000 = not a hex digit, so a combined code unit gets high bits set)
.Lhexv:
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x00000004, 0x00000005, 0x00000006, 0x00000007
    .long 0x00000008, 0x00000009, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0x0000000a, 0x0000000b, 0x0000000c, 0x0000000d, 0x0000000e, 0x0000000f, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0x0000000a, 0x0000000b, 0x0000000c, 0x0000000d, 0x0000000e, 0x0000000f, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
    .long 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000
# serde_json's POW10: 1e0..1e308 as f64
.Lpow10:
    .quad 0x3ff0000000000000, 0x4024000000000000, 0x4059000000000000, 0x408f400000000000
    .quad 0x40c3880000000000, 0x40f86a0000000000, 0x412e848000000000, 0x416312d000000000
    .quad 0x4197d78400000000, 0x41cdcd6500000000, 0x4202a05f20000000, 0x42374876e8000000
    .quad 0x426d1a94a2000000, 0x42a2309ce5400000, 0x42d6bcc41e900000, 0x430c6bf526340000
    .quad 0x4341c37937e08000, 0x4376345785d8a000, 0x43abc16d674ec800, 0x43e158e460913d00
    .quad 0x4415af1d78b58c40, 0x444b1ae4d6e2ef50, 0x4480f0cf064dd592, 0x44b52d02c7e14af6
    .quad 0x44ea784379d99db4, 0x45208b2a2c280291, 0x4554adf4b7320335, 0x4589d971e4fe8402
    .quad 0x45c027e72f1f1281, 0x45f431e0fae6d721, 0x46293e5939a08cea, 0x465f8def8808b024
    .quad 0x4693b8b5b5056e17, 0x46c8a6e32246c99c, 0x46fed09bead87c03, 0x4733426172c74d82
    .quad 0x476812f9cf7920e3, 0x479e17b84357691b, 0x47d2ced32a16a1b1, 0x48078287f49c4a1d
    .quad 0x483d6329f1c35ca5, 0x48725dfa371a19e7, 0x48a6f578c4e0a061, 0x48dcb2d6f618c879
    .quad 0x4911efc659cf7d4c, 0x49466bb7f0435c9e, 0x497c06a5ec5433c6, 0x49b18427b3b4a05c
    .quad 0x49e5e531a0a1c873, 0x4a1b5e7e08ca3a8f, 0x4a511b0ec57e649a, 0x4a8561d276ddfdc0
    .quad 0x4ababa4714957d30, 0x4af0b46c6cdd6e3e, 0x4b24e1878814c9ce, 0x4b5a19e96a19fc41
    .quad 0x4b905031e2503da9, 0x4bc4643e5ae44d13, 0x4bf97d4df19d6057, 0x4c2fdca16e04b86d
    .quad 0x4c63e9e4e4c2f344, 0x4c98e45e1df3b015, 0x4ccf1d75a5709c1b, 0x4d03726987666191
    .quad 0x4d384f03e93ff9f5, 0x4d6e62c4e38ff872, 0x4da2fdbb0e39fb47, 0x4dd7bd29d1c87a19
    .quad 0x4e0dac74463a989f, 0x4e428bc8abe49f64, 0x4e772ebad6ddc73d, 0x4eacfa698c95390c
    .quad 0x4ee21c81f7dd43a7, 0x4f16a3a275d49491, 0x4f4c4c8b1349b9b5, 0x4f81afd6ec0e1411
    .quad 0x4fb61bcca7119916, 0x4feba2bfd0d5ff5b, 0x502145b7e285bf99, 0x50559725db272f7f
    .quad 0x508afcef51f0fb5f, 0x50c0de1593369d1b, 0x50f5159af8044462, 0x512a5b01b605557b
    .quad 0x516078e111c3556d, 0x5194971956342ac8, 0x51c9bcdfabc1357a, 0x5200160bcb58c16c
    .quad 0x52341b8ebe2ef1c7, 0x526922726dbaae39, 0x529f6b0f092959c7, 0x52d3a2e965b9d81d
    .quad 0x53088ba3bf284e24, 0x533eae8caef261ad, 0x53732d17ed577d0c, 0x53a7f85de8ad5c4f
    .quad 0x53ddf67562d8b363, 0x5412ba095dc7701e, 0x5447688bb5394c25, 0x547d42aea2879f2e
    .quad 0x54b249ad2594c37d, 0x54e6dc186ef9f45c, 0x551c931e8ab87173, 0x5551dbf316b346e8
    .quad 0x558652efdc6018a2, 0x55bbe7abd3781eca, 0x55f170cb642b133f, 0x5625ccfe3d35d80e
    .quad 0x565b403dcc834e12, 0x569108269fd210cb, 0x56c54a3047c694fe, 0x56fa9cbc59b83a3d
    .quad 0x5730a1f5b8132466, 0x5764ca732617ed80, 0x5799fd0fef9de8e0, 0x57d03e29f5c2b18c
    .quad 0x58044db473335def, 0x583961219000356b, 0x586fb969f40042c5, 0x58a3d3e2388029bb
    .quad 0x58d8c8dac6a0342a, 0x590efb1178484135, 0x59435ceaeb2d28c1, 0x59783425a5f872f1
    .quad 0x59ae412f0f768fad, 0x59e2e8bd69aa19cc, 0x5a17a2ecc414a03f, 0x5a4d8ba7f519c84f
    .quad 0x5a827748f9301d32, 0x5ab7151b377c247e, 0x5aecda62055b2d9e, 0x5b22087d4358fc82
    .quad 0x5b568a9c942f3ba3, 0x5b8c2d43b93b0a8c, 0x5bc19c4a53c4e697, 0x5bf6035ce8b6203d
    .quad 0x5c2b843422e3a84d, 0x5c6132a095ce4930, 0x5c957f48bb41db7c, 0x5ccadf1aea12525b
    .quad 0x5d00cb70d24b7379, 0x5d34fe4d06de5057, 0x5d6a3de04895e46d, 0x5da066ac2d5daec4
    .quad 0x5dd4805738b51a75, 0x5e09a06d06e26112, 0x5e400444244d7cab, 0x5e7405552d60dbd6
    .quad 0x5ea906aa78b912cc, 0x5edf485516e7577f, 0x5f138d352e5096af, 0x5f48708279e4bc5b
    .quad 0x5f7e8ca3185deb72, 0x5fb317e5ef3ab327, 0x5fe7dddf6b095ff1, 0x601dd55745cbb7ed
    .quad 0x6052a5568b9f52f4, 0x60874eac2e8727b1, 0x60bd22573a28f19d, 0x60f2357684599702
    .quad 0x6126c2d4256ffcc3, 0x615c73892ecbfbf4, 0x6191c835bd3f7d78, 0x61c63a432c8f5cd6
    .quad 0x61fbc8d3f7b3340c, 0x62315d847ad00087, 0x6265b4e5998400a9, 0x629b221effe500d4
    .quad 0x62d0f5535fef2084, 0x630532a837eae8a5, 0x633a7f5245e5a2cf, 0x63708f936baf85c1
    .quad 0x63a4b378469b6732, 0x63d9e056584240fe, 0x64102c35f729689f, 0x6444374374f3c2c6
    .quad 0x647945145230b378, 0x64af965966bce056, 0x64e3bdf7e0360c36, 0x6518ad75d8438f43
    .quad 0x654ed8d34e547314, 0x6583478410f4c7ec, 0x65b819651531f9e8, 0x65ee1fbe5a7e7861
    .quad 0x6622d3d6f88f0b3d, 0x665788ccb6b2ce0c, 0x668d6affe45f818f, 0x66c262dfeebbb0f9
    .quad 0x66f6fb97ea6a9d38, 0x672cba7de5054486, 0x6761f48eaf234ad4, 0x679671b25aec1d89
    .quad 0x67cc0e1ef1a724eb, 0x680188d357087713, 0x6835eb082cca94d7, 0x686b65ca37fd3a0d
    .quad 0x68a11f9e62fe4448, 0x68d56785fbbdd55a, 0x690ac1677aad4ab1, 0x6940b8e0acac4eaf
    .quad 0x6974e718d7d7625a, 0x69aa20df0dcd3af1, 0x69e0548b68a044d6, 0x6a1469ae42c8560c
    .quad 0x6a498419d37a6b8f, 0x6a7fe52048590673, 0x6ab3ef342d37a408, 0x6ae8eb0138858d0a
    .quad 0x6b1f25c186a6f04c, 0x6b537798f4285630, 0x6b88557f31326bbb, 0x6bbe6adefd7f06aa
    .quad 0x6bf302cb5e6f642a, 0x6c27c37e360b3d35, 0x6c5db45dc38e0c82, 0x6c9290ba9a38c7d1
    .quad 0x6cc734e940c6f9c6, 0x6cfd022390f8b837, 0x6d3221563a9b7323, 0x6d66a9abc9424feb
    .quad 0x6d9c5416bb92e3e6, 0x6dd1b48e353bce70, 0x6e0621b1c28ac20c, 0x6e3baa1e332d728f
    .quad 0x6e714a52dffc6799, 0x6ea59ce797fb817f, 0x6edb04217dfa61df, 0x6f10e294eebc7d2c
    .quad 0x6f451b3a2a6b9c76, 0x6f7a6208b5068394, 0x6fb07d457124123d, 0x6fe49c96cd6d16cc
    .quad 0x7019c3bc80c85c7f, 0x70501a55d07d39cf, 0x708420eb449c8843, 0x70b9292615c3aa54
    .quad 0x70ef736f9b3494e9, 0x7123a825c100dd11, 0x7158922f31411456, 0x718eb6bafd91596b
    .quad 0x71c33234de7ad7e3, 0x71f7fec216198ddc, 0x722dfe729b9ff153, 0x7262bf07a143f6d4
    .quad 0x72976ec98994f489, 0x72cd4a7bebfa31ab, 0x73024e8d737c5f0b, 0x7336e230d05b76cd
    .quad 0x736c9abd04725481, 0x73a1e0b622c774d0, 0x73d658e3ab795204, 0x740bef1c9657a686
    .quad 0x74417571ddf6c814, 0x7475d2ce55747a18, 0x74ab4781ead1989e, 0x74e10cb132c2ff63
    .quad 0x75154fdd7f73bf3c, 0x754aa3d4df50af0b, 0x7580a6650b926d67, 0x75b4cffe4e7708c0
    .quad 0x75ea03fde214caf1, 0x7620427ead4cfed6, 0x7654531e58a03e8c, 0x768967e5eec84e2f
    .quad 0x76bfc1df6a7a61bb, 0x76f3d92ba28c7d15, 0x7728cf768b2f9c5a, 0x775f03542dfb8370
    .quad 0x779362149cbd3226, 0x77c83a99c3ec7eb0, 0x77fe494034e79e5c, 0x7832edc82110c2f9
    .quad 0x7867a93a2954f3b8, 0x789d9388b3aa30a5, 0x78d27c35704a5e67, 0x79071b42cc5cf601
    .quad 0x793ce2137f743382, 0x79720d4c2fa8a031, 0x79a6909f3b92c83d, 0x79dc34c70a777a4d
    .quad 0x7a11a0fc668aac70, 0x7a46093b802d578c, 0x7a7b8b8a6038ad6f, 0x7ab137367c236c65
    .quad 0x7ae585041b2c477f, 0x7b1ae64521f7595e, 0x7b50cfeb353a97db, 0x7b8503e602893dd2
    .quad 0x7bba44df832b8d46, 0x7bf06b0bb1fb384c, 0x7c2485ce9e7a065f, 0x7c59a742461887f6
    .quad 0x7c9008896bcf54fa, 0x7cc40aabc6c32a38, 0x7cf90d56b873f4c7, 0x7d2f50ac6690f1f8
    .quad 0x7d63926bc01a973b, 0x7d987706b0213d0a, 0x7dce94c85c298c4c, 0x7e031cfd3999f7b0
    .quad 0x7e37e43c8800759c, 0x7e6ddd4baa009303, 0x7ea2aa4f4a405be2, 0x7ed754e31cd072da
    .quad 0x7f0d2a1be4048f90, 0x7f423a516e82d9ba, 0x7f76c8e5ca239029, 0x7fac7b1f3cac7433
    .quad 0x7fe1ccf385ebc8a0
# 10^0..10^19 (jw_int digit count)
.Lp10:
    .quad 0x0000000000000001, 0x000000000000000a, 0x0000000000000064, 0x00000000000003e8
    .quad 0x0000000000002710, 0x00000000000186a0, 0x00000000000f4240, 0x0000000000989680
    .quad 0x0000000005f5e100, 0x000000003b9aca00, 0x00000002540be400, 0x000000174876e800
    .quad 0x000000e8d4a51000, 0x000009184e72a000, 0x00005af3107a4000, 0x00038d7ea4c68000
    .quad 0x002386f26fc10000, 0x016345785d8a0000, 0x0de0b6b3a7640000, 0x8ac7230489e80000
# "00".."99"
.Lpairs:
    .ascii "00010203040506070809"
    .ascii "10111213141516171819"
    .ascii "20212223242526272829"
    .ascii "30313233343536373839"
    .ascii "40414243444546474849"
    .ascii "50515253545556575859"
    .ascii "60616263646566676869"
    .ascii "70717273747576777879"
    .ascii "80818283848586878889"
    .ascii "90919293949596979899"

.section .note.GNU-stack,"",@progbits
