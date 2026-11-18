# A growable byte buffer with explicit lifetime. The event loop owns every buffer and frees it itself, the way a C
# server would; there is no destructor, so copies are just aliases.

from std.memory import unsafe_memcpy, unsafe_memmove
from std.memory.alloc import unsafe_alloc

comptime BytePtr = Pointer[UInt8, MutUntrackedOrigin]


@inline(.always)
def null_bytes() -> BytePtr:
    return BytePtr.unsafe_dangling()


def to_string(p: BytePtr, n: Int) -> String:
    """Copies `n` bytes into a new String. For logs and tests, not the request path."""
    return String(unsafe_from_utf8=Span[UInt8, MutUntrackedOrigin](unsafe_ptr=p, length=n))


@inline(.always)
def copy_bytes(dst: BytePtr, src: BytePtr, n: Int):
    unsafe_memcpy(dest=dst, src=src, count=n)


@inline(.always)
def move_bytes(dst: BytePtr, src: BytePtr, n: Int):
    unsafe_memmove(dest=dst, src=src, count=n)


struct ByteBuf(ImplicitlyCopyable):
    var ptr: BytePtr
    var len: Int
    var cap: Int

    def __init__(out self):
        self.ptr = null_bytes()
        self.len = 0
        self.cap = 0

    def __init__(out self, cap: Int):
        self.ptr = unsafe_alloc[UInt8](cap)
        self.len = 0
        self.cap = cap

    def free(mut self):
        if self.cap > 0:
            self.ptr.unsafe_free()
        self.ptr = null_bytes()
        self.len = 0
        self.cap = 0

    def reserve(mut self, extra: Int):
        """Makes room for `extra` more bytes."""
        var need = self.len + extra
        if need <= self.cap:
            return
        var cap = self.cap * 2 if self.cap > 0 else 256
        while cap < need:
            cap *= 2
        var p = unsafe_alloc[UInt8](cap)
        if self.len > 0:
            copy_bytes(p, self.ptr, self.len)
        if self.cap > 0:
            self.ptr.unsafe_free()
        self.ptr = p
        self.cap = cap

    @inline(.always)
    def tail(self) -> BytePtr:
        return self.ptr.unsafe_offset(self.len)

    @inline(.always)
    def put(mut self, b: UInt8):
        self.reserve(1)
        self.ptr[unsafe_offset=self.len] = b
        self.len += 1

    @inline(.always)
    def put_bytes(mut self, p: BytePtr, n: Int):
        self.reserve(n)
        copy_bytes(self.tail(), p, n)
        self.len += n

    @inline(.always)
    def put_str(mut self, s: StringSlice):
        var n = s.byte_length()
        self.reserve(n)
        copy_bytes(self.tail(), BytePtr(unsafe_from_address=Int(s.unsafe_ptr())), n)
        self.len += n

    def put_int(mut self, v: Int):
        if v < 0:
            self.put(UInt8(ord("-")))
            self.put_uint(-v)
        else:
            self.put_uint(v)

    def put_uint(mut self, v: Int):
        var digits = Array[UInt8, 20](fill=0)
        var n = 0
        var x = v
        while True:
            digits[n] = UInt8(48 + x % 10)
            x //= 10
            n += 1
            if x == 0:
                break
        self.reserve(n)
        for i in range(n):
            self.ptr[unsafe_offset=self.len + i] = digits[n - 1 - i]
        self.len += n

    def consume(mut self, n: Int):
        """Drops the first `n` bytes."""
        if n >= self.len:
            self.len = 0
            return
        move_bytes(self.ptr, self.ptr.unsafe_offset(n), self.len - n)
        self.len -= n
