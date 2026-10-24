# Attribution

This submission starts from `submissions/go-epoll-o7livetype` at challenge commit
`c301225`, by o7LiveType and the challenge contributors, under the repository's
MIT license. Its reactor, HTTP parser, original SQL and API handlers, binary JSON
encoder, JWT implementation, reconnect logic, and interleaved pure Go bcrypt
form the baseline. The copyright and MIT license are retained in LICENSE.

The shared-read SQL design adapts ideas and query structure from
`submissions/rust-tokio-Scooter1337/src/read_batch.rs`, by Scooter1337 and the
challenge contributors, also under the same MIT license. The Go scheduler,
array encoder, streaming ordinal reader, timer wheel, additional validation,
and benchmark helpers are implemented here.

The Blowfish constants in `src/internal/bcryptx/tables.go` were copied by the
baseline from `golang.org/x/crypto/blowfish` 0.58.0. Its Go Authors copyright is
retained, and the corresponding BSD license is supplied in
`src/internal/bcryptx/LICENSE`.

The four-lane C++ bcrypt implementation in `src/internal/bcryptx/native/` and
`native.cc` adapts `submissions/cpp-asio-c-hatton/src/bcrypt.hpp` and
`bcrypt_tables.cpp` from this challenge repository, under the repository MIT
license. The optimized path accepts ordinary ASCII passwords; all other inputs
continue through the retained Go implementation.
