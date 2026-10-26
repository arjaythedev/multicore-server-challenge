# C bcrypt kernel (source only, built on the box)

`crypt-bcrypt.c` is copied without changes from libxcrypt 4.4.36, `lib/crypt-bcrypt.c`:
https://github.com/besser82/libxcrypt/releases/tag/v4.4.36

Source archive `libxcrypt-4.4.36.tar.xz` SHA-256: e5e1f4caee0a01de2aee26e3138807d6d3ca2b8e67287966d1fefd65e1fd8943
(file SHA-256: c6166e3d3d42d23bdc8c151e22e6aa60f33a4b4eeb008de54cf0243881fa1413).

It is Solar Designer's public-domain Openwall bcrypt implementation (crypt_blowfish). Its full license and
attribution are kept at the top of the file, and its runtime self-test is kept.

These files are copied without changes from `submissions/rust-tokio-Scooter1337/native/` in this repository (MIT,
the repository's license):

* `crypt-port.h`, `byteorder.h`: the few types, byte-order helpers and constants that `crypt-bcrypt.c` needs outside
  libxcrypt.
* `bcrypt-batch.c`, `bcrypt-batch-impl.h`: the Openwall rounds with 2, 3 or 4 independent hashes interleaved.

```
b58abb9c42e8a5902aa20bc7cbe516260f54a831d1b43261b5228f8325622d4e  crypt-port.h
cdfa3a3ae45955ad5da880053522b123f2e2d4e2a9dd74adb1f7a206d6ca6dfa  byteorder.h
be69f39655a6e8680d756aeade92d37a060ef08d3e75a875f13c953508c0aff7  bcrypt-batch.c
554687a11fcc46da412c76a40f46a198a1a2462005cc992091eeb2a38ac637c5  bcrypt-batch-impl.h
```

Ours:

| file | what |
|---|---|
| `conduit-bcrypt.h`, `conduit-bcrypt.c`, `conduit-bcrypt-lanes.h` | `conduit_bf_lanes`: 1 to 8 hashes per call (adds the 1-, 6- and 8-lane instances of the same interleave; 5 and 7 run the 6/8-lane kernel). It takes the key and salt words the Kotlin code already computes, so a password with an embedded NUL hashes correctly, which crypt(3)'s C strings can't do. `conduit_bf_self_test`: every lane count against the single-hash Openwall `crypt_bcrypt_rn` (with its own built-in self-test) on known keys. |

Every hash runs all 2^cost rounds with its own key and salt. Nothing is reused between hashes or requests.

Build: the JVM build compiles `conduit-bcrypt.c` with `cc -O3 -fPIC -shared` (gcc from install.sh; the Gradle task
`bcryptLib`, run by build.sh) into `build/jvm/libconduit-bcrypt.so`, which it calls through the FFM API. The
Kotlin/Native build compiles the same file into the binary through cinterop
(`src/nativeInterop/cinterop/bcrypt.def`, Kotlin/Native's clang, `-O3`). No `-m`/`-march` flags, because the box's
CPU is unknown. `-O3` matters: the interleave relies on unrolling, and `-O2` costs ~30% more. At startup the server
runs the C self-test and checks known hashes through the binding. If either fails, or the library is missing, it
logs that once and uses its pure-Kotlin lanes (`conduit.crypto.Bcrypt`), which give the same bytes.

Measured at cost 10 as CPU per hash on the lab's Xeon (thread CPU time, `taskset -c 3`, in process, 3 runs):

| lanes | gcc -O3 (JVM, FFM) | Kotlin/Native cinterop (release) |
|---|---|---|
| 8 | 12.6-12.7 ms | 12.9-13.1 ms |
| 6 | 12.6-12.7 ms | 12.7 ms |
| 4 | 15.2-15.4 ms | 15.9-16.4 ms |
| 1 | 48.3-49.1 ms | 52.4-52.6 ms |

For comparison, the pure-Kotlin 4 lanes take 23.4-23.5 ms (JVM) and 18.6-18.8 ms (Native).
