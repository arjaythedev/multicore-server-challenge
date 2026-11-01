# native: bcrypt

- `crypt-bcrypt.c`: Solar Designer's public-domain Openwall bcrypt implementation, copied without changes from
  libxcrypt 4.4.36 (`lib/crypt-bcrypt.c`, https://github.com/besser82/libxcrypt/releases/tag/v4.4.36). Its license
  and attribution are at the top of the file.
- `crypt-port.h`, `byteorder.h`: the few types, byte-order helpers and constants that file needs outside libxcrypt.
- `bcrypt-batch-impl.h`: interleaves independent Blowfish states round by round, from
  [PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) (rust-tokio-Scooter1337, MIT). It uses
  the original key and salt handling and runs every iteration of the cost for every password.
  These four files are as in that submission.
- `bcrypt.c`, `bcrypt.h`: this submission's C wrapper: `bc_hash()` for 1–6 hashes (2–6 lanes instantiated from the
  header above, 1 with the original code), `bc_selftest()` checking a known answer and comparing every lane count with
  the original single-hash code, and `bc_calibrate()` used at startup to pick the fastest lane count on the CPU it
  runs on.
