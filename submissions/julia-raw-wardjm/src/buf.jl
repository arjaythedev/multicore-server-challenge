# Growable byte buffer with an explicit length: the storage is kept and reused, so steady-state appends don't allocate.

mutable struct Buf
    data::Vector{UInt8}
    len::Int
end
Buf(cap::Integer) = Buf(Vector{UInt8}(undef, cap), 0)

@inline function reserve!(b::Buf, extra::Integer)
    need = b.len + extra
    if need > length(b.data)
        resize!(b.data, max(need, 2 * length(b.data)))
    end
    nothing
end

@inline reset!(b::Buf) = (b.len = 0; nothing)

@inline function wr!(b::Buf, x::UInt8)
    reserve!(b, 1)
    @inbounds b.data[b.len+1] = x
    b.len += 1
    nothing
end

@inline function wr!(b::Buf, p::Ptr{UInt8}, n::Integer)
    reserve!(b, n)
    GC.@preserve b unsafe_copyto!(pointer(b.data, b.len + 1), p, n)
    b.len += n
    nothing
end

# bytes [off, off+n) of v (0-based off)
@inline function wr!(b::Buf, v::Vector{UInt8}, off::Integer, n::Integer)
    n <= 0 && return nothing
    reserve!(b, n)
    @inbounds copyto!(b.data, b.len + 1, v, off + 1, n)
    b.len += n
    nothing
end

@inline function wr!(b::Buf, s::String)
    n = sizeof(s)
    reserve!(b, n)
    GC.@preserve s b unsafe_copyto!(pointer(b.data, b.len + 1), pointer(s), n)
    b.len += n
    nothing
end

# decimal integer
function put_int!(b::Buf, x::Integer)
    x = Int64(x)
    reserve!(b, 20)
    if x < 0
        @inbounds b.data[b.len+1] = UInt8('-')
        b.len += 1
        x = -x
    end
    if x == 0
        @inbounds b.data[b.len+1] = UInt8('0')
        b.len += 1
        return nothing
    end
    n = ndigits(x)
    i = b.len + n
    @inbounds while x > 0
        q, r = divrem(x, 10)
        b.data[i] = UInt8('0') + UInt8(r)
        x = q
        i -= 1
    end
    b.len += n
    nothing
end

# big-endian integers (Postgres wire format)
@inline function put_be!(b::Buf, x::Union{Int16,Int32,Int64,UInt16,UInt32})
    n = sizeof(x)
    reserve!(b, n)
    GC.@preserve b unsafe_store!(Ptr{typeof(x)}(pointer(b.data, b.len + 1)), hton(x))
    b.len += n
    nothing
end

@inline function patch_be32!(b::Buf, pos::Integer, x::Integer)
    GC.@preserve b unsafe_store!(Ptr{Int32}(pointer(b.data, pos + 1)), hton(Int32(x)))
    nothing
end

@inline load_be(::Type{T}, v::Vector{UInt8}, off::Integer) where {T} =
    GC.@preserve v ntoh(unsafe_load(Ptr{T}(pointer(v, off + 1))))

# memcmp of v[off, off+n) against a String
@inline function bytes_eq(v::Vector{UInt8}, off::Integer, n::Integer, s::String)
    n == sizeof(s) || return false
    GC.@preserve v s ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), pointer(v, off + 1), pointer(s), n) == 0
end

@inline function bytes_eq(a::Vector{UInt8}, aoff::Integer, an::Integer, b::Vector{UInt8}, boff::Integer, bn::Integer)
    an == bn || return false
    GC.@preserve a b ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), pointer(a, aoff + 1), pointer(b, boff + 1), an) == 0
end

# lexicographic byte comparison: <0, 0, >0
@inline function bytes_cmp(a::Vector{UInt8}, aoff::Integer, an::Integer, b::Vector{UInt8}, boff::Integer, bn::Integer)
    c = GC.@preserve a b ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), pointer(a, aoff + 1), pointer(b, boff + 1), min(an, bn))
    c != 0 ? Int(c) : an - bn
end
