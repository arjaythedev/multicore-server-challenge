`crypt-bcrypt.c` is copied without changes from libxcrypt 4.4.36, `lib/crypt-bcrypt.c`
(https://github.com/besser82/libxcrypt/releases/tag/v4.4.36). It is Solar Designer's public-domain Openwall bcrypt;
its full licence and attribution are at the top of the file.

`bcrypt-batch-impl.h`, `crypt-port.h` and `byteorder.h` are copied from the MIT-licensed
`submissions/rust-tokio-Scooter1337/native` in this repository (see the repository's LICENSE): the 2-4 lane
interleaving of independent hashes, and the minimal definitions the core needs to build on its own.

`bcrypt_nif.c` is this submission's NIF wrapper: `hash_many/1` (dirty CPU scheduler) and `gensalt/1`.
