BCrypt.Net-Next 4.0.3 source from the official BcryptNet/bcrypt.net repository.

Pinned commit: 2dcc0c99874e43fe3b1b98bfc35cfd974d44cf48 (tag 4.0.3).

https://github.com/BcryptNet/bcrypt.net/tree/2dcc0c99874e43fe3b1b98bfc35cfd974d44cf48/src/BCrypt.Net

The seven C# source files retain upstream bcrypt behavior. BCrypt.cs and
HashParser.cs add a #nullable disable directive for the upstream legacy
nullability context. LICENSE.txt and jBCrypt-LICENSE.txt retain the upstream
license notices. No external package or native binary is required to compile
this implementation. The application explicitly selects standard bcrypt cost
10; enhanced pre-hashing is not enabled.

The projects define the upstream `HAS_SPAN` compilation symbol on .NET 10.
This selects its existing span/stackalloc implementation instead of temporary
arrays. The local hot loop also uses scalar left/right words, local state-array
references and the fixed sixteen Blowfish rounds without a round-counter loop.
The cyclic input-byte offset uses increment-and-wrap instead of remainder.
These changes preserve the round operations, state initialization, password
encoding, revisions, salts and work factor. State is still initialized afresh
for every hash. No unsafe access, pooling or password-derived precomputation is
introduced. Correctness checks compare against the unchanged upstream code;
no performance figures are claimed from correctness-only validation.
