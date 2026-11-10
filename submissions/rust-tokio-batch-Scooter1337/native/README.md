`crypt-bcrypt.c` is copied without changes from libxcrypt 4.4.36, `lib/crypt-bcrypt.c`:
https://github.com/besser82/libxcrypt/releases/tag/v4.4.36

Source archive SHA-256: e5e1f4caee0a01de2aee26e3138807d6d3ca2b8e67287966d1fefd65e1fd8943

The file is Solar Designer's public-domain/Openwall bcrypt implementation. Its full license and attribution are retained at the top of the file. The two local headers supply only the types, byte-order operations and compile-time constants required to build this file independently of libxcrypt. The runtime self-tests are retained. No system libcrypt dependency is needed.

`bcrypt-batch.c` includes that unchanged source and adds `bcrypt-batch-impl.h`, which interleaves two, three or four independent Blowfish states. It uses the original key/salt handling and runs every cost-10 iteration for each password. There is no hash reuse. A startup self-test compares all lane counts against the original implementation; differential tests also check the portable Rust backend, variants, UTF-8 and 72-byte passwords. The queue and worker count are bounded; individual hashes retain independent random salts.
