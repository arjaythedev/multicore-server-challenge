# native: bcrypt and JSON rendering NIFs

| File | Origin | License |
|---|---|---|
| `crypt-bcrypt.c` | [libxcrypt 4.4.36](https://github.com/besser82/libxcrypt/releases/tag/v4.4.36), `lib/crypt-bcrypt.c`, **unchanged** (SHA-256 `c6166e3d3d42d23bdc8c151e22e6aa60f33a4b4eeb008de54cf0243881fa1413`, checked against the `v4.4.36` tag). Solar Designer's Openwall crypt_blowfish | Public domain, with a permissive fallback license; full text at the top of the file |
| `crypt-port.h`, `byteorder.h`, `bcrypt-batch.c`, `bcrypt-batch-impl.h` | The [rust-tokio-Scooter1337](../../rust-tokio-Scooter1337/native) submission by @Scooter1337, **unchanged**: standalone build headers for the core, and the interleaving of 2-4 independent Blowfish states | MIT (this repository's [LICENSE](../LICENSE)) |
| `conduit_bcrypt_nif.c` | This submission: the Erlang NIF around the two above | MIT |
| `conduit_render_nif.c` | This submission: JSON response bodies from Postgres binary rows (see the main README) | MIT |

`conduit_bcrypt_nif.c` includes `bcrypt-batch.c` (which includes `crypt-bcrypt.c`) as one translation unit, and exposes
`hash/2` (1 to 4 passwords with their settings; a single hash goes through the original `crypt_bcrypt_rn` with its
built-in self-test, 2 to 4 through the interleaved path) on a dirty CPU scheduler, and `salt/1` (the original
`gensalt_bcrypt_rn`, cost 10, prefix `$2b$`). Every hash runs all 2^cost iterations with its own salt; interleaving
only overlaps independent computations. Password-derived buffers are wiped before returning.

Checks: at startup, every lane count must reproduce the single-hash results (as in rust-tokio-Scooter1337);
`test/bcrypt_test.exs` checks against bcrypt_elixir (an independent implementation) in both directions on random
passwords, the seed's real hashes, and all batch sizes.

Measured on one core of the local machine, cost 10: bcrypt_elixir 30.3 hashes/s; this NIF 29.8 (1 lane), 58.0 (2),
81.8 (3), 106.9 (4).
