# Response compression is application middleware until Rayo exposes gzip.
@[Link("deflate")]
lib ConduitDeflate
  fun alloc = libdeflate_alloc_compressor(level : Int32) : Void*
  fun compress = libdeflate_gzip_compress(compressor : Void*, input : Void*, length : LibC::SizeT, output : Void*, capacity : LibC::SizeT) : LibC::SizeT
  fun bound = libdeflate_gzip_compress_bound(compressor : Void*, length : LibC::SizeT) : LibC::SizeT
end

module Conduit::Compression
  @@compressor = Pointer(Void).null
  @@output = Rayo::Buf.new(4096)

  # Respect an explicit q=0 for gzip, including zero with fractional zeros.
  def self.accepted?(header : Bytes)
    start = 0
    while start < header.size
      stop = start
      while stop < header.size && header[stop] != 44
        stop += 1
      end
      first = start
      while first < stop && (header[first] == 32 || header[first] == 9)
        first += 1
      end
      last = first
      while last < stop && header[last] != 59 && header[last] != 32 && header[last] != 9
        last += 1
      end
      if Rayo::HTTP.equal(header[first, last - first], "gzip", true)
        q = last
        while q < stop
          if (header[q] == 113 || header[q] == 81) && q + 1 < stop && header[q + 1] == 61
            q += 2
            nonzero = false
            while q < stop && header[q] != 59 && header[q] != 32 && header[q] != 9
              nonzero = true if 49 <= header[q] <= 57
              q += 1
            end
            return nonzero
          end
          q += 1
        end
        return true
      end
      start = stop + 1
    end
    false
  end

  def self.apply(ctx)
    return unless ctx.output.len >= 1024 && ctx.status != 204
    ctx.header "Vary", "Accept-Encoding"
    return unless accepted?(ctx.header("Accept-Encoding"))
    @@compressor = ConduitDeflate.alloc(1) if @@compressor.null?
    return if @@compressor.null?
    bound = ConduitDeflate.bound(@@compressor, ctx.output.len).to_i32
    @@output.clear
    @@output.reserve(bound)
    n = ConduitDeflate.compress(@@compressor, ctx.output.ptr, ctx.output.len, @@output.ptr, @@output.cap).to_i32
    return if n == 0 || n >= ctx.output.len
    ctx.output.clear
    ctx.output.write(@@output.ptr, n)
    ctx.header "Content-Encoding", "gzip"
  end
end
