# HS256 JWTs. Every request verifies the signature, the header's alg and exp; nothing is remembered between requests.

# base64url of {"alg":"HS256","typ":"JWT"}: what we issue and what most libraries emit
const JWT_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
const TOKEN_TTL = 30 * 24 * 3600

mutable struct JwtScratch
    mac::Hmac
    sig::Vector{UInt8}   # computed MAC
    dec::Vector{UInt8}   # base64url decode target
    tmp::Buf             # string scratch for the JSON parser / payload builder
end
JwtScratch() = JwtScratch(Hmac(), zeros(UInt8, 32), zeros(UInt8, 256), Buf(256))

# the token in v[off, off+n) -> user id, or -1 when it doesn't verify
function jwt_verify(s::JwtScratch, key::HmacKey, v::Vector{UInt8}, off::Int, n::Int, now::Int64)
    d1 = 0
    d2 = 0
    @inbounds for i in off+1:off+n
        if v[i] == UInt8('.')
            if d1 == 0
                d1 = i
            elseif d2 == 0
                d2 = i
            else
                return Int64(-1)
            end
        end
    end
    (d1 == 0 || d2 == 0) && return Int64(-1)
    # header
    hlen = d1 - 1 - off
    if !bytes_eq(v, off, hlen, JWT_HEADER)
        m = b64url_decode!(s.dec, v, off, hlen)
        m < 0 && return Int64(-1)
        s.tmp.len = 0
        jwt_header_ok(s.tmp, s.dec, m) || return Int64(-1)
    end
    # signature over header.payload
    slen = off + n - d2
    m = b64url_decode!(s.dec, v, d2, slen)
    m == 32 || return Int64(-1)
    hmac_start!(s.mac, key)
    hmac_update!(s.mac, v, off, d2 - 1 - off)
    hmac_final!(s.mac, key, s.sig)
    diff = 0x00
    @inbounds for i in 1:32
        diff |= s.sig[i] ⊻ s.dec[i]
    end
    diff == 0x00 || return Int64(-1)
    # claims
    m = b64url_decode!(s.dec, v, d1, d2 - 1 - d1)
    m < 0 && return Int64(-1)
    s.tmp.len = 0
    sub, exp = jwt_claims(s.tmp, s.dec, m)
    (sub <= 0 || exp <= now) && return Int64(-1)
    sub
end

# appends a fresh token for user id to b
function jwt_issue!(b::Buf, s::JwtScratch, key::HmacKey, id::Int64, now::Int64)
    start = b.len
    wr!(b, JWT_HEADER)
    wr!(b, UInt8('.'))
    p = s.tmp
    p.len = 0
    wr!(p, "{\"sub\":\"")
    put_int!(p, id)
    wr!(p, "\",\"iat\":")
    put_int!(p, now)
    wr!(p, ",\"exp\":")
    put_int!(p, now + TOKEN_TTL)
    wr!(p, UInt8('}'))
    b64url_encode!(b, p.data, 0, p.len)
    hmac_start!(s.mac, key)
    hmac_update!(s.mac, b.data, start, b.len - start)
    hmac_final!(s.mac, key, s.sig)
    wr!(b, UInt8('.'))
    b64url_encode!(b, s.sig, 0, 32)
    nothing
end
