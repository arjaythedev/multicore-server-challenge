# SHA-256 and HMAC-SHA256 without allocation. HMAC keys are absorbed once: the inner and outer states after the
# padded key block are kept, so a MAC over a short message costs two or three compressions.

const K256 = UInt32[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

const H256 = UInt32[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

mutable struct Sha256
    h::Vector{UInt32}      # 8
    w::Vector{UInt32}      # 64, message schedule scratch
    blk::Vector{UInt8}     # 64, partial block
    nblk::Int
    total::Int
end
Sha256() = Sha256(copy(H256), zeros(UInt32, 64), zeros(UInt8, 64), 0, 0)

@inline rotr(x::UInt32, n) = (x >>> n) | (x << (32 - n))

function compress!(h::Vector{UInt32}, w::Vector{UInt32}, p::Ptr{UInt8})
    @inbounds begin
        for t in 1:16
            w[t] = ntoh(unsafe_load(Ptr{UInt32}(p + 4 * (t - 1))))
        end
        for t in 17:64
            x = w[t-15]
            y = w[t-2]
            s0 = rotr(x, 7) ⊻ rotr(x, 18) ⊻ (x >>> 3)
            s1 = rotr(y, 17) ⊻ rotr(y, 19) ⊻ (y >>> 10)
            w[t] = w[t-16] + s0 + w[t-7] + s1
        end
        a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for t in 1:64
            S1 = rotr(e, 6) ⊻ rotr(e, 11) ⊻ rotr(e, 25)
            ch = (e & f) ⊻ (~e & g)
            t1 = hh + S1 + ch + K256[t] + w[t]
            S0 = rotr(a, 2) ⊻ rotr(a, 13) ⊻ rotr(a, 22)
            mj = (a & b) ⊻ (a & c) ⊻ (b & c)
            t2 = S0 + mj
            hh = g; g = f; f = e; e = d + t1
            d = c; c = b; b = a; a = t1 + t2
        end
        h[1] += a; h[2] += b; h[3] += c; h[4] += d
        h[5] += e; h[6] += f; h[7] += g; h[8] += hh
    end
    nothing
end

function sha_init!(s::Sha256)
    copyto!(s.h, H256)
    s.nblk = 0
    s.total = 0
    s
end

function sha_update!(s::Sha256, p::Ptr{UInt8}, n::Integer)
    s.total += n
    blk = s.blk
    GC.@preserve blk begin
        if s.nblk > 0
            k = min(64 - s.nblk, n)
            unsafe_copyto!(pointer(blk, s.nblk + 1), p, k)
            s.nblk += k
            p += k
            n -= k
            if s.nblk == 64
                compress!(s.h, s.w, pointer(blk))
                s.nblk = 0
            end
        end
        while n >= 64
            compress!(s.h, s.w, p)
            p += 64
            n -= 64
        end
        if n > 0
            unsafe_copyto!(pointer(blk), p, n)
            s.nblk = n
        end
    end
    nothing
end

sha_update!(s::Sha256, v::Vector{UInt8}, off::Integer, n::Integer) = GC.@preserve v sha_update!(s, pointer(v, off + 1), n)
sha_update!(s::Sha256, v::Vector{UInt8}) = sha_update!(s, v, 0, length(v))
sha_update!(s::Sha256, x::String) = GC.@preserve x sha_update!(s, pointer(x), sizeof(x))

# writes the 32-byte digest to out[off+1 : off+32]
function sha_final!(s::Sha256, out::Vector{UInt8}, off::Integer=0)
    bits = UInt64(s.total) * 8
    blk = s.blk
    @inbounds begin
        blk[s.nblk+1] = 0x80
        for i in s.nblk+2:64
            blk[i] = 0x00
        end
        if s.nblk + 1 > 56
            GC.@preserve blk compress!(s.h, s.w, pointer(blk))
            fill!(blk, 0x00)
        end
        for i in 0:7
            blk[64-i] = UInt8((bits >> (8 * i)) & 0xff)
        end
        GC.@preserve blk compress!(s.h, s.w, pointer(blk))
        for i in 1:8
            x = s.h[i]
            out[off+4i-3] = UInt8(x >> 24)
            out[off+4i-2] = UInt8((x >> 16) & 0xff)
            out[off+4i-1] = UInt8((x >> 8) & 0xff)
            out[off+4i] = UInt8(x & 0xff)
        end
    end
    nothing
end

function sha256(data::Vector{UInt8})
    s = Sha256()
    sha_update!(s, data)
    out = zeros(UInt8, 32)
    sha_final!(s, out)
    out
end

# HMAC with the key absorbed: istate/ostate are the hash states after the (key ⊻ ipad) and (key ⊻ opad) blocks
struct HmacKey
    istate::Vector{UInt32}
    ostate::Vector{UInt32}
end

function HmacKey(key::Vector{UInt8})
    k = length(key) > 64 ? sha256(key) : key
    pad = zeros(UInt8, 64)
    copyto!(pad, k)
    s = Sha256()
    sha_update!(s, pad .⊻ 0x36)
    istate = copy(s.h)
    sha_init!(s)
    sha_update!(s, pad .⊻ 0x5c)
    HmacKey(istate, copy(s.h))
end

# scratch state for one thread
mutable struct Hmac
    s::Sha256
    inner::Vector{UInt8} # 32
end
Hmac() = Hmac(Sha256(), zeros(UInt8, 32))

function hmac_start!(m::Hmac, k::HmacKey)
    s = m.s
    copyto!(s.h, k.istate)
    s.nblk = 0
    s.total = 64
    nothing
end

hmac_update!(m::Hmac, p::Ptr{UInt8}, n::Integer) = sha_update!(m.s, p, n)
hmac_update!(m::Hmac, v::Vector{UInt8}, off::Integer, n::Integer) = sha_update!(m.s, v, off, n)

function hmac_final!(m::Hmac, k::HmacKey, out::Vector{UInt8}, off::Integer=0)
    s = m.s
    sha_final!(s, m.inner)
    copyto!(s.h, k.ostate)
    s.nblk = 0
    s.total = 64
    sha_update!(s, m.inner)
    sha_final!(s, out, off)
    nothing
end

# one-shot, allocating (SCRAM at startup)
function hmac_sha256(key::Vector{UInt8}, msg::Vector{UInt8})
    k = HmacKey(key)
    m = Hmac()
    hmac_start!(m, k)
    hmac_update!(m, msg, 0, length(msg))
    out = zeros(UInt8, 32)
    hmac_final!(m, k, out)
    out
end
