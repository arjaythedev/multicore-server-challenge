# cider-iouring-pomilon

Front: direct

High-performance, modular multicore HTTP/1.1 Conduit server implemented in pure [Cider](https://github.com/Pomilon/Cider) with Linux `io_uring` direct descriptors, SO_REUSEPORT core pinning, and PostgreSQL 18 in pipelined mode.

## Architecture

- **Language:** Pure Cider (compiled via Cider's native codegen).
- **Core Architecture:**
  - Zero C wrapper files.
  - Multi-process pre-forked architecture with kernel-distributed connections via `SO_REUSEPORT`.
  - Core pinning via native `sched_setaffinity` syscalls.
  - Each worker process drives its own dedicated Linux `io_uring` completion loop on its assigned CPU core.
- **Freestanding Native Routines:**
  - Direct Linux x86-64 syscalls (`sys_socket`, `sys_bind`, `sys_listen`, `sys_accept4`, `sys_read`, `sys_write`, `sys_mmap`, `sys_sched_setaffinity`, `sys_io_uring_setup`, `sys_io_uring_enter`).
  - Native Cider memory & string manipulation (`native_memcpy`, `native_memset`, `native_memcmp`, `native_strlen`, `native_strncmp`, `native_itoa`, `native_atoi`).
  - Pure Cider SHA-256, HMAC-SHA256, Base64URL, and JWT HS256 verify & sign.
  - Pure Cider Blowfish key expansion and bcrypt password hashing & verification.
  - Zero-allocation streaming HTTP/1.1 request parser and JSON properties extractor.
- **Database:**
  - Non-blocking PostgreSQL 18 client multiplexing queries in pipeline mode via `libpq`.
