# bcrypt ($2a$/$2b$/$2y$) in Julia, running up to four hashes in lockstep. A Blowfish round is a chain of dependent
# table loads, so one hash leaves most of a core's load ports idle; interleaving four independent hashes in the same
# loop body lets the out-of-order core overlap them. Every hash still runs all 2^cost rounds of its own.

# Blowfish's initial P-array and S-boxes are the hexadecimal digits of π after the point: 18 + 4 × 256 words
const BF_WORDS = 18 + 1024
const BF_INIT = let
    setprecision(BigFloat, 32 * BF_WORDS + 64) do
        x = BigFloat(π) - 3
        w = Vector{UInt32}(undef, BF_WORDS)
        for i in 1:BF_WORDS
            x *= 4294967296
            d = floor(x)
            w[i] = UInt32(d)
            x -= d
        end
        w
    end
end
@assert BF_INIT[1] == 0x243f6a88 && BF_INIT[19] == 0xd1310ba6 && BF_INIT[end] == 0x3ac372e6

const BCRYPT_ALPHA = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const BCRYPT_DEC = b64_table(BCRYPT_ALPHA)
const ORPHEAN = b"OrpheanBeholderScryDoubt"

@inline function bf_f(S::Vector{UInt32}, o::Int, x::UInt32)
    @inbounds ((S[o+19+(x>>24)] + S[o+275+((x>>16)&0xff)]) ⊻ S[o+531+((x>>8)&0xff)]) + S[o+787+(x&0xff)]
end

# lane-wise helpers: closures here never capture a variable that is reassigned (which would box it)
@inline xor_p(S::Vector{UInt32}, o::NTuple{N,Int}, A::NTuple{N,UInt32}, i::Int) where {N} =
    ntuple(j -> @inbounds(A[j] ⊻ S[o[j]+i]), Val(N))
@inline xor_fp(S::Vector{UInt32}, o::NTuple{N,Int}, A::NTuple{N,UInt32}, B::NTuple{N,UInt32}, i::Int) where {N} =
    ntuple(j -> @inbounds(A[j] ⊻ bf_f(S, o[j], B[j]) ⊻ S[o[j]+i]), Val(N))
@inline xor_salt(A::NTuple{N,UInt32}, salt::Vector{UInt32}, so::NTuple{N,Int}, k::Int) where {N} =
    ntuple(j -> @inbounds(A[j] ⊻ salt[so[j]+(k&3)+1]), Val(N))
@inline zero_lanes(::Val{N}) where {N} = ntuple(_ -> UInt32(0), Val(N))
@inline ct_lanes(ct::Vector{UInt32}, i::Int, ::Val{N}) where {N} = ntuple(j -> ct[6(j-1)+i], Val(N))

# one Blowfish block per lane; lane j's state is S[o[j]+1 : o[j]+BF_WORDS]
@inline function bf_encipher(S::Vector{UInt32}, o::NTuple{N,Int}, L::NTuple{N,UInt32}, R::NTuple{N,UInt32}) where {N}
    L = xor_p(S, o, L, 1)
    for i in 1:2:16
        R = xor_fp(S, o, R, L, i + 1)
        L = xor_fp(S, o, L, R, i + 2)
    end
    R = xor_p(S, o, R, 18)
    (R, L)
end

# P ⊻= key schedule; then the whole state is re-encrypted in place, chaining from a zero block. With `salt`, each
# block is first XORed with the next two words of the salt stream (16 bytes, so period 4).
@inline function bf_expand!(S::Vector{UInt32}, o::NTuple{N,Int}, key::Vector{UInt32}, ko::NTuple{N,Int},
    salt::Vector{UInt32}, so::NTuple{N,Int}, withsalt::Bool) where {N}
    @inbounds begin
        for i in 1:18
            for j in 1:N
                S[o[j]+i] ⊻= key[ko[j]+i]
            end
        end
        L = zero_lanes(Val(N))
        R = L
        k = 0
        for i in 1:2:BF_WORDS
            if withsalt
                L = xor_salt(L, salt, so, k)
                R = xor_salt(R, salt, so, k + 1)
                k += 2
            end
            L, R = bf_encipher(S, o, L, R)
            for j in 1:N
                S[o[j]+i] = L[j]
                S[o[j]+i+1] = R[j]
            end
        end
    end
    nothing
end

mutable struct BcryptLanes
    S::Vector{UInt32}      # 4 states
    key::Vector{UInt32}    # 4 × 18 password key schedules
    skey::Vector{UInt32}   # 4 × 18 salt-as-key schedules
    salt::Vector{UInt32}   # 4 × 4 salt words
    ct::Vector{UInt32}     # 4 × 6 ciphertext words
end
BcryptLanes() = BcryptLanes(zeros(UInt32, 4BF_WORDS), zeros(UInt32, 72), zeros(UInt32, 72), zeros(UInt32, 16), zeros(UInt32, 24))

# 18 words cycling through bytes (big-endian words)
function key_schedule!(dst::Vector{UInt32}, off::Int, bytes::Vector{UInt8}, n::Int)
    j = 0
    for i in 1:18
        w = UInt32(0)
        for _ in 1:4
            w = (w << 8) | bytes[j+1]
            j = j + 1 == n ? 0 : j + 1
        end
        dst[off+i] = w
    end
end

function bcrypt_run!(z::BcryptLanes, ::Val{N}, cost::Int) where {N}
    S = z.S
    o = ntuple(j -> (j - 1) * BF_WORDS, Val(N))
    k18 = ntuple(j -> (j - 1) * 18, Val(N))
    s4 = ntuple(j -> (j - 1) * 4, Val(N))
    for j in 1:N
        copyto!(S, o[j] + 1, BF_INIT, 1, BF_WORDS)
    end
    bf_expand!(S, o, z.key, k18, z.salt, s4, true)
    for _ in 1:(1<<cost)
        bf_expand!(S, o, z.key, k18, z.salt, s4, false)
        bf_expand!(S, o, z.skey, k18, z.salt, s4, false)
    end
    ct = z.ct
    for j in 1:N, i in 1:6
        p = 4(i - 1)
        ct[6(j-1)+i] = (UInt32(ORPHEAN[p+1]) << 24) | (UInt32(ORPHEAN[p+2]) << 16) | (UInt32(ORPHEAN[p+3]) << 8) | ORPHEAN[p+4]
    end
    for _ in 1:64, b in 0:2
        L, R = bf_encipher(S, o, ct_lanes(ct, 2b + 1, Val(N)), ct_lanes(ct, 2b + 2, Val(N)))
        for j in 1:N
            ct[6(j-1)+2b+1] = L[j]
            ct[6(j-1)+2b+2] = R[j]
        end
    end
    nothing
end

# bcrypt's base64 (own alphabet, no padding)
function bcrypt_b64!(b::Buf, src::Vector{UInt8}, n::Int)
    i = 0
    while i < n
        c1 = src[i+1]
        wr!(b, BCRYPT_ALPHA[(c1>>2)+1])
        c1 = (c1 & 0x03) << 4
        if i + 1 >= n
            wr!(b, BCRYPT_ALPHA[c1+1])
            break
        end
        c2 = src[i+2]
        wr!(b, BCRYPT_ALPHA[(c1|(c2>>4))+1])
        c1 = (c2 & 0x0f) << 2
        if i + 2 >= n
            wr!(b, BCRYPT_ALPHA[c1+1])
            break
        end
        c2 = src[i+3]
        wr!(b, BCRYPT_ALPHA[(c1|(c2>>6))+1])
        wr!(b, BCRYPT_ALPHA[(c2&0x3f)+1])
        i += 3
    end
end

# decodes 22 chars -> 16 salt bytes; false if invalid
function bcrypt_salt!(out::Vector{UInt8}, v::Vector{UInt8}, off::Int)
    acc = UInt32(0)
    bits = 0
    j = 0
    for i in off+1:off+22
        d = BCRYPT_DEC[v[i]+1]
        d == 0xff && return false
        acc = (acc << 6) | d
        bits += 6
        if bits >= 8
            bits -= 8
            j < 16 && (out[j+1] = UInt8((acc >> bits) & 0xff))
            j += 1
        end
    end
    true
end

# a job for one lane: the password, and either a stored hash (verify) or nothing (new hash with a fresh salt)
mutable struct BcryptJob
    pw::Vector{UInt8}
    pwlen::Int
    setting::Vector{UInt8}  # "$2b$10$" + 22 salt chars (+ hash when verifying)
    cost::Int
    saltb::Vector{UInt8}
    out::Buf                # the full 60-char hash
end
BcryptJob() = BcryptJob(zeros(UInt8, 128), 0, zeros(UInt8, 64), 10, zeros(UInt8, 16), Buf(64))

# parses "$2?$NN$<22 salt>" from v[off, off+n); returns the cost or -1
function bcrypt_parse!(saltb::Vector{UInt8}, v::Vector{UInt8}, off::Int, n::Int)
    n < 29 && return -1
    (v[off+1] == UInt8('$') && v[off+2] == UInt8('2') && v[off+4] == UInt8('$') && v[off+7] == UInt8('$')) || return -1
    m = v[off+3]
    (m == UInt8('a') || m == UInt8('b') || m == UInt8('y')) || return -1
    d1 = v[off+5] - UInt8('0')
    d2 = v[off+6] - UInt8('0')
    (d1 <= 9 && d2 <= 9) || return -1
    cost = 10Int(d1) + Int(d2)
    (4 <= cost <= 31) || return -1
    bcrypt_salt!(saltb, v, off + 7) || return -1
    cost
end

# runs up to four jobs with the same cost; each job's `out` gets "$2?$NN$" + salt + hash (the prefix and salt
# copied from its setting)
function bcrypt_lanes!(z::BcryptLanes, jobs::Vector{BcryptJob}, n::Int)
    for j in 1:n
        jb = jobs[j]
        # key: password + NUL, at most 72 bytes used
        kl = min(jb.pwlen, 72)
        key = jb.pw
        key[kl+1] = 0x00
        key_schedule!(z.key, 18(j - 1), key, min(kl + 1, 72))
        key_schedule!(z.skey, 18(j - 1), jb.saltb, 16)
        for i in 1:4
            p = 4(i - 1)
            s = jb.saltb
            z.salt[4(j-1)+i] = (UInt32(s[p+1]) << 24) | (UInt32(s[p+2]) << 16) | (UInt32(s[p+3]) << 8) | s[p+4]
        end
    end
    cost = jobs[1].cost
    n == 4 ? bcrypt_run!(z, Val(4), cost) : n == 3 ? bcrypt_run!(z, Val(3), cost) :
    n == 2 ? bcrypt_run!(z, Val(2), cost) : bcrypt_run!(z, Val(1), cost)
    raw = zeros(UInt8, 24)
    for j in 1:n
        jb = jobs[j]
        for i in 1:6
            w = z.ct[6(j-1)+i]
            raw[4i-3] = UInt8(w >> 24)
            raw[4i-2] = UInt8((w >> 16) & 0xff)
            raw[4i-1] = UInt8((w >> 8) & 0xff)
            raw[4i] = UInt8(w & 0xff)
        end
        o = jb.out
        o.len = 0
        wr!(o, jb.setting, 0, 29)
        bcrypt_b64!(o, raw, 23)
    end
    nothing
end
