use @pony_os_stderr[Pointer[U8]]()
use @fprintf[I32](stream: Pointer[U8] tag, fmt: Pointer[U8] tag, ...)
use @exit[None](status: I32)

primitive _Unreachable
  fun apply(loc: SourceLoc = __loc) =>
    @fprintf(@pony_os_stderr(),
      "Unreachable code at %s:%lu in %s.%s\n".cstring(),
      loc.file().cstring(), loc.line(), loc.type_name().cstring(),
      loc.method_name().cstring())
    @exit(1)
