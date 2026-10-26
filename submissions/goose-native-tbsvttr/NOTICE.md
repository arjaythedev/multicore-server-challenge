# Source attribution

This submission combines our native primitives from the single-core challenge
with an existing asynchronous Conduit implementation. It is a derivative work,
not a claim that all of its code was written here.

- The PostgreSQL wire client, asynchronous HTTP/Conduit implementation, SQL,
  bcrypt and supporting Goose modules start from XeonFX's MIT-licensed
  [multicore PR #31](https://github.com/arjaythedev/multicore-server-challenge/pull/31),
  commit `43e0919ae5b693c1d3c1e8828b74bb774ef92ee0`.
- The SIMD JSON writer and prepared OpenSSL HMAC strategy come from our
  [single-core Goose PR #143](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/143),
  commit `1454fa62e7c4e273d978b7ad93a492148079edae`.
- XeonFX credits compatible overlapping read batching and shared article
  enrichment to Scooter1337's
  [multicore Rust PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7).
  That attribution is retained here.
- Goose itself is built from pinned source at
  `f605b5a07dd2aa3a5cb3f4c9b14002bd3c9d3d1a` under its upstream license.
  OpenSSL is provided by Ubuntu's development packages and retains its own
  license. Neither dependency's source is represented as our application code.

The challenge contributors' MIT notice is retained in [LICENSE](LICENSE).
Upstream PR #31's GCP probes and PR #7's official score are their authors'
measurements. They are not measurements of this derivative.
