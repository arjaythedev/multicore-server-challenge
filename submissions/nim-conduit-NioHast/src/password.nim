## bcrypt cost-10 via the system libxcrypt.
##
## The server is single-threaded per worker process, so libcrypt's classic
## `crypt()` entry point is safe here.  A production multi-threaded variant
## should use `crypt_rn` with a per-thread `crypt_data` buffer instead.

{.passL: "-lcrypt".}

import std/sysrand

proc crypt(key, salt: cstring): cstring
  {.importc, header: "<crypt.h>".}
proc crypt_gensalt_rn(prefix: cstring; count: culong; rbytes: pointer;
                      nrbytes: cint; output: cstring; outputSize: cint): cstring
  {.importc, header: "<crypt.h>".}

proc hashPassword*(password: string): string =
  var entropy: array[16, byte]
  if not urandom(entropy):
    raise newException(ValueError, "secure random source unavailable")
  var salt: array[64, char]
  let saltPtr = crypt_gensalt_rn("$2b$", 10, addr entropy[0], 16,
                                 addr salt[0], 64)
  if saltPtr == nil:
    raise newException(ValueError, "bcrypt salt generation failed")
  let hashed = crypt(password.cstring, saltPtr)
  if hashed == nil:
    raise newException(ValueError, "bcrypt hashing failed")
  $hashed

proc verifyPassword*(password, storedHash: string): bool =
  if storedHash.len == 0: return false
  let hashed = crypt(password.cstring, storedHash.cstring)
  hashed != nil and $hashed == storedHash
