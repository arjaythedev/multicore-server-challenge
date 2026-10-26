# base64url (JWT, no padding) and standard base64 (SCRAM).

const B64URL = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const B64STD = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function b64_table(alpha)
    t = fill(0xff, 256)
    for (i, c) in enumerate(alpha)
        t[c+1] = UInt8(i - 1)
    end
    t
end
const B64URL_DEC = b64_table(B64URL)
const B64STD_DEC = b64_table(B64STD)

# encodes src[soff, soff+n) onto b without padding
function b64url_encode!(b::Buf, src::Vector{UInt8}, soff::Integer, n::Integer)
    reserve!(b, (n * 4 + 2) ÷ 3)
    d = b.data
    j = b.len
    i = soff
    stop = soff + n
    @inbounds begin
        while i + 3 <= stop
            x = (UInt32(src[i+1]) << 16) | (UInt32(src[i+2]) << 8) | UInt32(src[i+3])
            d[j+1] = B64URL[(x>>18)+1]
            d[j+2] = B64URL[((x>>12)&0x3f)+1]
            d[j+3] = B64URL[((x>>6)&0x3f)+1]
            d[j+4] = B64URL[(x&0x3f)+1]
            i += 3
            j += 4
        end
        r = stop - i
        if r == 1
            x = UInt32(src[i+1]) << 16
            d[j+1] = B64URL[(x>>18)+1]
            d[j+2] = B64URL[((x>>12)&0x3f)+1]
            j += 2
        elseif r == 2
            x = (UInt32(src[i+1]) << 16) | (UInt32(src[i+2]) << 8)
            d[j+1] = B64URL[(x>>18)+1]
            d[j+2] = B64URL[((x>>12)&0x3f)+1]
            d[j+3] = B64URL[((x>>6)&0x3f)+1]
            j += 3
        end
    end
    b.len = j
    nothing
end

# decodes unpadded base64url src[soff, soff+n) into out (resized if needed); returns the length or -1
function b64url_decode!(out::Vector{UInt8}, src::Vector{UInt8}, soff::Integer, n::Integer)
    n % 4 == 1 && return -1
    need = (n * 3) >> 2
    length(out) < need && resize!(out, need)
    j = 0
    acc = UInt32(0)
    bits = 0
    @inbounds for i in soff+1:soff+n
        v = B64URL_DEC[src[i]+1]
        v == 0xff && return -1
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8
            bits -= 8
            j += 1
            out[j] = UInt8((acc >> bits) & 0xff)
        end
    end
    j
end

function b64std_encode(src::Vector{UInt8})
    b = Buf(64)
    b64url_encode!(b, src, 0, length(src))
    s = b.data[1:b.len]
    for i in eachindex(s)
        s[i] == UInt8('-') && (s[i] = UInt8('+'))
        s[i] == UInt8('_') && (s[i] = UInt8('/'))
    end
    while length(s) % 4 != 0
        push!(s, UInt8('='))
    end
    String(s)
end

function b64std_decode(s::AbstractString)
    out = UInt8[]
    acc = UInt32(0)
    bits = 0
    for c in codeunits(s)
        c == UInt8('=') && break
        v = B64STD_DEC[c+1]
        v == 0xff && error("bad base64")
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8
            bits -= 8
            push!(out, UInt8((acc >> bits) & 0xff))
        end
    end
    out
end
