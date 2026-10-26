# JSON: escaping writer, and a small validating parser for request bodies and JWT segments. Strings decode into a
# per-request arena; nothing allocates.

# 0: copy as is; otherwise the byte to put after '\' ('u' = \u00XX)
const JESC = let t = zeros(UInt8, 256)
    for c in 0x00:0x1f
        t[c+1] = UInt8('u')
    end
    t[UInt8('\n')+1] = UInt8('n')
    t[UInt8('\r')+1] = UInt8('r')
    t[UInt8('\t')+1] = UInt8('t')
    t[0x08+1] = UInt8('b')
    t[0x0c+1] = UInt8('f')
    t[UInt8('"')+1] = UInt8('"')
    t[UInt8('\\')+1] = UInt8('\\')
    t
end
const HEXD = b"0123456789abcdef"

# a quoted, escaped JSON string from v[off, off+n)
function wr_jstr!(b::Buf, v::Vector{UInt8}, off::Integer, n::Integer)
    reserve!(b, n + 2)
    d = b.data
    j = b.len + 1
    @inbounds d[j] = UInt8('"')
    i = off + 1
    stop = off + n
    run = i
    @inbounds while i <= stop
        e = JESC[v[i]+1]
        if e == 0x00
            i += 1
            continue
        end
        k = i - run
        if k > 0
            b.len = j
            reserve!(b, k + 8 + (stop - i))
            d = b.data
            copyto!(d, j + 1, v, run, k)
            j += k
        else
            b.len = j
            reserve!(b, 8 + (stop - i))
            d = b.data
        end
        if e == UInt8('u')
            c = v[i]
            d[j+1] = UInt8('\\'); d[j+2] = UInt8('u'); d[j+3] = UInt8('0'); d[j+4] = UInt8('0')
            d[j+5] = HEXD[(c>>4)+1]; d[j+6] = HEXD[(c&0x0f)+1]
            j += 6
        else
            d[j+1] = UInt8('\\'); d[j+2] = e
            j += 2
        end
        i += 1
        run = i
    end
    k = stop + 1 - run
    b.len = j
    reserve!(b, k + 1)
    d = b.data
    k > 0 && @inbounds copyto!(d, j + 1, v, run, k)
    j += k
    @inbounds d[j+1] = UInt8('"')
    b.len = j + 1
    nothing
end

# a field that may be SQL NULL (len < 0)
@inline function wr_jstr_or_null!(b::Buf, v::Vector{UInt8}, off::Integer, n::Integer)
    n < 0 ? wr!(b, "null") : wr_jstr!(b, v, off, n)
end

wr_jstr!(b::Buf, s::String) = wr_jstr!(b, Vector{UInt8}(s), 0, sizeof(s))

# ---------------- parser (1-based positions, inclusive stop) ----------------

@inline isws(c::UInt8) = c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09

@inline function skipws(v::Vector{UInt8}, i::Int, stop::Int)
    @inbounds while i <= stop && isws(v[i])
        i += 1
    end
    i
end

@inline function hexval(c::UInt8)
    UInt8('0') <= c <= UInt8('9') && return Int(c - UInt8('0'))
    UInt8('a') <= c <= UInt8('f') && return Int(c - UInt8('a') + 10)
    UInt8('A') <= c <= UInt8('F') && return Int(c - UInt8('A') + 10)
    -1
end

function hex4(v::Vector{UInt8}, i::Int, stop::Int)
    i + 3 > stop && return -1
    x = 0
    @inbounds for k in 0:3
        h = hexval(v[i+k])
        h < 0 && return -1
        x = (x << 4) | h
    end
    x
end

function wr_utf8!(a::Buf, cp::Int)
    if cp < 0x80
        wr!(a, UInt8(cp))
    elseif cp < 0x800
        wr!(a, UInt8(0xc0 | (cp >> 6))); wr!(a, UInt8(0x80 | (cp & 0x3f)))
    elseif cp < 0x10000
        wr!(a, UInt8(0xe0 | (cp >> 12))); wr!(a, UInt8(0x80 | ((cp >> 6) & 0x3f))); wr!(a, UInt8(0x80 | (cp & 0x3f)))
    else
        wr!(a, UInt8(0xf0 | (cp >> 18))); wr!(a, UInt8(0x80 | ((cp >> 12) & 0x3f)))
        wr!(a, UInt8(0x80 | ((cp >> 6) & 0x3f))); wr!(a, UInt8(0x80 | (cp & 0x3f)))
    end
end

# v[i] == '"'. Decodes into arena a. Returns the position after the closing quote (or -1); the string is
# a.data[start+1 : a.len] with start = the arena length on entry.
function parse_str!(a::Buf, v::Vector{UInt8}, i::Int, stop::Int)
    i += 1
    run = i
    @inbounds while i <= stop
        c = v[i]
        if c == UInt8('"')
            wr!(a, v, run - 1, i - run)
            return i + 1
        elseif c == UInt8('\\')
            wr!(a, v, run - 1, i - run)
            i + 1 > stop && return -1
            e = v[i+1]
            if e == UInt8('"') || e == UInt8('\\') || e == UInt8('/')
                wr!(a, e)
            elseif e == UInt8('n')
                wr!(a, 0x0a)
            elseif e == UInt8('t')
                wr!(a, 0x09)
            elseif e == UInt8('r')
                wr!(a, 0x0d)
            elseif e == UInt8('b')
                wr!(a, 0x08)
            elseif e == UInt8('f')
                wr!(a, 0x0c)
            elseif e == UInt8('u')
                cp = hex4(v, i + 2, stop)
                cp < 0 && return -1
                i += 6
                if 0xd800 <= cp <= 0xdbff && i + 1 <= stop && v[i] == UInt8('\\') && v[i+1] == UInt8('u')
                    lo = hex4(v, i + 2, stop)
                    if 0xdc00 <= lo <= 0xdfff
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                        i += 6
                    else
                        cp = 0xfffd
                    end
                elseif 0xd800 <= cp <= 0xdfff
                    cp = 0xfffd
                end
                wr_utf8!(a, cp)
                run = i
                continue
            else
                return -1
            end
            i += 2
            run = i
        elseif c < 0x20
            return -1
        else
            i += 1
        end
    end
    -1
end

function skip_num(v::Vector{UInt8}, i::Int, stop::Int)
    s = i
    @inbounds begin
        i <= stop && v[i] == UInt8('-') && (i += 1)
        d = i
        while i <= stop && UInt8('0') <= v[i] <= UInt8('9')
            i += 1
        end
        i == d && return -1
        if i <= stop && v[i] == UInt8('.')
            i += 1
            d = i
            while i <= stop && UInt8('0') <= v[i] <= UInt8('9')
                i += 1
            end
            i == d && return -1
        end
        if i <= stop && (v[i] == UInt8('e') || v[i] == UInt8('E'))
            i += 1
            i <= stop && (v[i] == UInt8('+') || v[i] == UInt8('-')) && (i += 1)
            d = i
            while i <= stop && UInt8('0') <= v[i] <= UInt8('9')
                i += 1
            end
            i == d && return -1
        end
    end
    i
end

@inline function lit(v::Vector{UInt8}, i::Int, stop::Int, s::String)
    n = sizeof(s)
    i + n - 1 <= stop && bytes_eq(v, i - 1, n, s) ? i + n : -1
end

# skips (and validates) one value; a is scratch for strings (restored)
function skip_value(a::Buf, v::Vector{UInt8}, i::Int, stop::Int, depth::Int=0)
    depth > 64 && return -1
    i > stop && return -1
    @inbounds c = v[i]
    if c == UInt8('"')
        l = a.len
        j = parse_str!(a, v, i, stop)
        a.len = l
        return j
    elseif c == UInt8('{')
        i = skipws(v, i + 1, stop)
        i <= stop && @inbounds(v[i]) == UInt8('}') && return i + 1
        while true
            (i > stop || @inbounds(v[i]) != UInt8('"')) && return -1
            l = a.len
            i = parse_str!(a, v, i, stop)
            a.len = l
            i < 0 && return -1
            i = skipws(v, i, stop)
            (i > stop || @inbounds(v[i]) != UInt8(':')) && return -1
            i = skip_value(a, v, skipws(v, i + 1, stop), stop, depth + 1)
            i < 0 && return -1
            i = skipws(v, i, stop)
            i > stop && return -1
            @inbounds c = v[i]
            c == UInt8('}') && return i + 1
            c != UInt8(',') && return -1
            i = skipws(v, i + 1, stop)
        end
    elseif c == UInt8('[')
        i = skipws(v, i + 1, stop)
        i <= stop && @inbounds(v[i]) == UInt8(']') && return i + 1
        while true
            i = skip_value(a, v, i, stop, depth + 1)
            i < 0 && return -1
            i = skipws(v, i, stop)
            i > stop && return -1
            @inbounds c = v[i]
            c == UInt8(']') && return i + 1
            c != UInt8(',') && return -1
            i = skipws(v, i + 1, stop)
        end
    elseif c == UInt8('t')
        return lit(v, i, stop, "true")
    elseif c == UInt8('f')
        return lit(v, i, stop, "false")
    elseif c == UInt8('n')
        return lit(v, i, stop, "null")
    else
        return skip_num(v, i, stop)
    end
end

# ---------------- request bodies: {"<wrapper>": {<fields>}} ----------------

const F_ABSENT = 0x00
const F_NULL = 0x01
const F_STR = 0x02
const F_BAD = 0x03 # wrong type (or a tagList that isn't an array of non-empty strings)
const F_ARR = 0x04

const MAXF = 6

mutable struct Fields
    state::Vector{UInt8}
    off::Vector{Int}      # 0-based in the arena
    len::Vector{Int}
    toff::Vector{Int}     # tagList items
    tlen::Vector{Int}
    ntags::Int
end
Fields() = Fields(zeros(UInt8, MAXF), zeros(Int, MAXF), zeros(Int, MAXF), zeros(Int, 16), zeros(Int, 16), 0)

function add_tag!(f::Fields, off::Int, len::Int)
    if f.ntags == length(f.toff)
        resize!(f.toff, 2 * f.ntags)
        resize!(f.tlen, 2 * f.ntags)
    end
    f.ntags += 1
    @inbounds f.toff[f.ntags] = off
    @inbounds f.tlen[f.ntags] = len
end

@inline fstr(f::Fields, k::Int) = f.state[k] == F_STR
@inline fnonempty(f::Fields, k::Int) = f.state[k] == F_STR && f.len[k] > 0

# array field `arrk` (0 = none) must be an array of non-empty strings
function parse_fields!(f::Fields, a::Buf, v::Vector{UInt8}, i::Int, stop::Int, names::Vector{String}, arrk::Int)
    i = skipws(v, i + 1, stop)
    i <= stop && @inbounds(v[i]) == UInt8('}') && return i + 1
    while true
        (i > stop || @inbounds(v[i]) != UInt8('"')) && return -1
        kstart = a.len
        i = parse_str!(a, v, i, stop)
        i < 0 && return -1
        k = 0
        for (n, name) in enumerate(names)
            if bytes_eq(a.data, kstart, a.len - kstart, name)
                k = n
                break
            end
        end
        a.len = kstart
        i = skipws(v, i, stop)
        (i > stop || @inbounds(v[i]) != UInt8(':')) && return -1
        i = skipws(v, i + 1, stop)
        i > stop && return -1
        @inbounds c = v[i]
        if k == 0
            i = skip_value(a, v, i, stop)
        elseif k == arrk
            if c == UInt8('[')
                f.state[k] = F_ARR
                f.ntags = 0
                i = skipws(v, i + 1, stop)
                if i <= stop && @inbounds(v[i]) == UInt8(']')
                    i += 1
                else
                    while true
                        i > stop && return -1
                        if @inbounds(v[i]) == UInt8('"')
                            s = a.len
                            i = parse_str!(a, v, i, stop)
                            i < 0 && return -1
                            a.len == s && (f.state[k] = F_BAD)
                            add_tag!(f, s, a.len - s)
                        else
                            f.state[k] = F_BAD
                            i = skip_value(a, v, i, stop)
                            i < 0 && return -1
                        end
                        i = skipws(v, i, stop)
                        i > stop && return -1
                        @inbounds c = v[i]
                        if c == UInt8(']')
                            i += 1
                            break
                        end
                        c != UInt8(',') && return -1
                        i = skipws(v, i + 1, stop)
                    end
                end
            elseif c == UInt8('n')
                i = lit(v, i, stop, "null")
                f.state[k] = F_NULL
            else
                f.state[k] = F_BAD
                i = skip_value(a, v, i, stop)
            end
        elseif c == UInt8('"')
            s = a.len
            i = parse_str!(a, v, i, stop)
            f.state[k] = F_STR
            f.off[k] = s
            f.len[k] = a.len - s
        elseif c == UInt8('n')
            i = lit(v, i, stop, "null")
            f.state[k] = F_NULL
        else
            f.state[k] = F_BAD
            i = skip_value(a, v, i, stop)
        end
        i < 0 && return -1
        i = skipws(v, i, stop)
        i > stop && return -1
        @inbounds c = v[i]
        c == UInt8('}') && return i + 1
        c != UInt8(',') && return -1
        i = skipws(v, i + 1, stop)
    end
end

# parses body v[i:stop]; false when it isn't JSON, or has no object under `wrapper`
function parse_body!(f::Fields, a::Buf, v::Vector{UInt8}, i::Int, stop::Int, wrapper::String, names::Vector{String}, arrk::Int=0)
    fill!(f.state, F_ABSENT)
    f.ntags = 0
    found = false
    i = skipws(v, i, stop)
    (i > stop || @inbounds(v[i]) != UInt8('{')) && return false
    i = skipws(v, i + 1, stop)
    if i <= stop && @inbounds(v[i]) == UInt8('}')
        i += 1
    else
        while true
            (i > stop || @inbounds(v[i]) != UInt8('"')) && return false
            kstart = a.len
            i = parse_str!(a, v, i, stop)
            i < 0 && return false
            isw = bytes_eq(a.data, kstart, a.len - kstart, wrapper)
            a.len = kstart
            i = skipws(v, i, stop)
            (i > stop || @inbounds(v[i]) != UInt8(':')) && return false
            i = skipws(v, i + 1, stop)
            i > stop && return false
            if isw
                @inbounds(v[i]) != UInt8('{') && return false
                fill!(f.state, F_ABSENT)
                i = parse_fields!(f, a, v, i, stop, names, arrk)
                found = true
            else
                i = skip_value(a, v, i, stop)
            end
            i < 0 && return false
            i = skipws(v, i, stop)
            i > stop && return false
            @inbounds c = v[i]
            if c == UInt8('}')
                i += 1
                break
            end
            c != UInt8(',') && return false
            i = skipws(v, i + 1, stop)
        end
    end
    skipws(v, i, stop) > stop && found
end

# ---------------- JWT segments ----------------

# {"alg": "HS256", ...}: true when alg is exactly HS256
function jwt_header_ok(a::Buf, v::Vector{UInt8}, n::Int)
    i = skipws(v, 1, n)
    (i > n || v[i] != UInt8('{')) && return false
    ok = false
    i = skipws(v, i + 1, n)
    i <= n && v[i] == UInt8('}') && return false
    while true
        (i > n || v[i] != UInt8('"')) && return false
        ks = a.len
        i = parse_str!(a, v, i, n)
        i < 0 && return false
        isalg = bytes_eq(a.data, ks, a.len - ks, "alg")
        a.len = ks
        i = skipws(v, i, n)
        (i > n || v[i] != UInt8(':')) && return false
        i = skipws(v, i + 1, n)
        if isalg
            (i > n || v[i] != UInt8('"')) && return false
            vs = a.len
            i = parse_str!(a, v, i, n)
            i < 0 && return false
            ok = bytes_eq(a.data, vs, a.len - vs, "HS256")
            a.len = vs
        else
            i = skip_value(a, v, i, n)
            i < 0 && return false
        end
        i = skipws(v, i, n)
        i > n && return false
        v[i] == UInt8('}') && return ok && skipws(v, i + 1, n) > n
        v[i] != UInt8(',') && return false
        i = skipws(v, i + 1, n)
    end
end

# parses an integer (or a number with a fraction/exponent, truncated) at v[i:j-1]
function num_value(v::Vector{UInt8}, i::Int, j::Int)
    x = Int64(0)
    neg = v[i] == UInt8('-')
    k = neg ? i + 1 : i
    simple = true
    @inbounds for p in k:j-1
        c = v[p]
        if UInt8('0') <= c <= UInt8('9') && simple
            x > 92233720368547758 && return typemax(Int64)
            x = x * 10 + (c - UInt8('0'))
        else
            simple = false
        end
    end
    simple && return neg ? -x : x
    f = tryparse(Float64, String(v[i:j-1]))
    f === nothing && return Int64(0)
    isfinite(f) || return f > 0 ? typemax(Int64) : typemin(Int64)
    abs(f) > 9.0e18 && return f > 0 ? typemax(Int64) : typemin(Int64)
    trunc(Int64, f)
end

# {"sub": "<decimal>", "exp": <number>, ...} -> (user id, exp); id = -1 when sub isn't a decimal string,
# exp = typemin when missing
function jwt_claims(a::Buf, v::Vector{UInt8}, n::Int)
    sub = Int64(-1)
    exp = typemin(Int64)
    i = skipws(v, 1, n)
    (i > n || v[i] != UInt8('{')) && return (Int64(-1), exp)
    i = skipws(v, i + 1, n)
    i <= n && v[i] == UInt8('}') && return (Int64(-1), exp)
    while true
        (i > n || v[i] != UInt8('"')) && return (Int64(-1), exp)
        ks = a.len
        i = parse_str!(a, v, i, n)
        i < 0 && return (Int64(-1), exp)
        key = bytes_eq(a.data, ks, a.len - ks, "sub") ? 1 : bytes_eq(a.data, ks, a.len - ks, "exp") ? 2 : 0
        a.len = ks
        i = skipws(v, i, n)
        (i > n || v[i] != UInt8(':')) && return (Int64(-1), exp)
        i = skipws(v, i + 1, n)
        i > n && return (Int64(-1), exp)
        if key == 1
            if v[i] == UInt8('"')
                vs = a.len
                i = parse_str!(a, v, i, n)
                i < 0 && return (Int64(-1), exp)
                sub = parse_id(a.data, vs, a.len - vs)
                a.len = vs
            else
                sub = Int64(-1)
                i = skip_value(a, v, i, n)
            end
        elseif key == 2
            c = v[i]
            if c == UInt8('-') || UInt8('0') <= c <= UInt8('9')
                j = skip_num(v, i, n)
                j < 0 && return (Int64(-1), exp)
                exp = num_value(v, i, j)
                i = j
            else
                exp = typemin(Int64)
                i = skip_value(a, v, i, n)
            end
        else
            i = skip_value(a, v, i, n)
        end
        i < 0 && return (Int64(-1), exp)
        i = skipws(v, i, n)
        i > n && return (Int64(-1), exp)
        v[i] == UInt8('}') && return skipws(v, i + 1, n) > n ? (sub, exp) : (Int64(-1), exp)
        v[i] != UInt8(',') && return (Int64(-1), exp)
        i = skipws(v, i + 1, n)
    end
end

# a positive decimal id in v[off, off+n): digits only, no sign, fits int64; else -1
function parse_id(v::Vector{UInt8}, off::Integer, n::Integer)
    (n <= 0 || n > 18) && return Int64(-1)
    x = Int64(0)
    @inbounds for i in off+1:off+n
        c = v[i]
        (c < UInt8('0') || c > UInt8('9')) && return Int64(-1)
        x = x * 10 + (c - UInt8('0'))
    end
    x
end
