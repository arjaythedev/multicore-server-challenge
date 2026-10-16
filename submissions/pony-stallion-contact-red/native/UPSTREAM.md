The bcrypt core in `crypt_blowfish.c` and `crypt_blowfish.h` comes from [Openwall crypt_blowfish](https://github.com/openwall/crypt_blowfish), commit `3354bb81eea489e972b0a7c63231514ab34f73a0`. The original source is public domain with a permissive fallback license, stated at the top of each file.

Local changes add an explicit password length to key setup and hashing so embedded NUL bytes have the same meaning as in the previous byte-oriented bcrypt implementation. The original C-string entry point remains available. A decoder entry point lets the password shim compare decoded hash payloads.
