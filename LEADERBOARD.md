# Leaderboard

Every submission on the same box: **8 dedicated vCPU / 16 GB**, Postgres 18 on the same box, full seed, the load generator on a separate machine. Score = the most users held for a 5-minute run with p95 < 500 ms, p99 < 1 s and < 1% errors ([how it's scored](README.md#scoring)). The video's four examples were re-run on this same box so everything compares like with like.

| # | Users | Submission | PR | Front | req/s | p95 ms | p99 ms | CPU: app / Postgres | Note |
|--:|--:|---|---|---|--:|--:|--:|---|---|
| 1 | **120,000** | [rust-epoll-WorriedArrow](submissions/rust-epoll-WorriedArrow) | [#47](https://github.com/arjaythedev/multicore-server-challenge/pull/47) @WorriedArrow | direct | 30,189 | 433 | 585 | 28% / 60% |  |
| 2 | **110,000** | [zig-fourneau-y2kbugger](submissions/zig-fourneau-y2kbugger) | [#53](https://github.com/arjaythedev/multicore-server-challenge/pull/53) @y2kbugger | direct | 28,535 | 251 | 430 | 20% / 59% |  |
| 3 | **110,000** | [zig-iouring-harshitkhandelwal208](submissions/zig-iouring-harshitkhandelwal208) | [#45](https://github.com/arjaythedev/multicore-server-challenge/pull/45) @harshitkhandelwal208 | direct | 28,835 | 162 | 477 | 22% / 63% |  |
| 4 | **100,000** | [rust-tokio-Scooter1337](submissions/rust-tokio-Scooter1337) | [#7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) @Scooter1337 | direct | 26,279 | 119 | 185 | 20% / 70% |  |
| 5 | **95,000** | [csharp-sockets-jh-d](submissions/csharp-sockets-jh-d) | [#22](https://github.com/arjaythedev/multicore-server-challenge/pull/22) @jh-d | direct | 24,696 | 493 | 737 | 21% / 75% |  |
| 6 | **92,000** | [go-raw-kimmotamio](submissions/go-raw-kimmotamio) | [#37](https://github.com/arjaythedev/multicore-server-challenge/pull/37) @kimmotamio | direct | 23,284 | 452 | 600 | 24% / 70% |  |
| 7 | **90,000** | [rust-epoll-someoneidoknow](submissions/rust-epoll-someoneidoknow) | [#50](https://github.com/arjaythedev/multicore-server-challenge/pull/50) @someoneidoknow | direct | 23,243 | 345 | 421 | 23% / 64% |  |
| 8 | **88,000** | [kotlin-raw-luben93](submissions/kotlin-raw-luben93) | [#48](https://github.com/arjaythedev/multicore-server-challenge/pull/48) @luben93 | direct | 22,456 | 432 | 506 | 20% / 71% |  |
| 9 | **84,000** | [c-iouring-tigokraft](submissions/c-iouring-tigokraft) | [#10](https://github.com/arjaythedev/multicore-server-challenge/pull/10) @tigokraft | direct | 21,262 | 339 | 421 | 18% / 80% |  |
| 10 | **84,000** | [cobol-gnucobol-benmandrew](submissions/cobol-gnucobol-benmandrew) | [#15](https://github.com/arjaythedev/multicore-server-challenge/pull/15) @benmandrew | direct | 21,292 | 361 | 461 | 20% / 75% |  |
| 11 | **84,000** | [kotlin-native-luben93](submissions/kotlin-native-luben93) | [#49](https://github.com/arjaythedev/multicore-server-challenge/pull/49) @luben93 | direct | 21,866 | 293 | 413 | 25% / 68% |  |
| 12 | **84,000** | [rust-tokio-semyonfox](submissions/rust-tokio-semyonfox) | [#59](https://github.com/arjaythedev/multicore-server-challenge/pull/59) @semyonfox | direct | 21,598 | 425 | 511 | 21% / 64% |  |
| 13 | **80,000** | [go-epoll-kaikegm](submissions/go-epoll-kaikegm) | [#57](https://github.com/arjaythedev/multicore-server-challenge/pull/57) @KaikeGM | direct | 20,951 | 201 | 358 | 22% / 71% |  |
| 14 | **80,000** | [julia-raw-wardjm](submissions/julia-raw-wardjm) | [#43](https://github.com/arjaythedev/multicore-server-challenge/pull/43) @wardjm | direct | 20,519 | 339 | 406 | 22% / 68% |  |
| 15 | **80,000** | [rust-mio-foovoo](submissions/rust-mio-foovoo) | [#11](https://github.com/arjaythedev/multicore-server-challenge/pull/11) @FooVoo | direct | 20,710 | 474 | 752 | 18% / 75% |  |
| 16 | **74,000** | [elixir-raw-ZeLarpMaster](submissions/elixir-raw-ZeLarpMaster) | [#56](https://github.com/arjaythedev/multicore-server-challenge/pull/56) @ZeLarpMaster | direct | 18,917 | 405 | 505 | 35% / 57% |  |
| 17 | **72,000** | [csharp-kestrel-xeonfx](submissions/csharp-kestrel-xeonfx) | [#8](https://github.com/arjaythedev/multicore-server-challenge/pull/8) @XeonFX | direct | 18,756 | 405 | 610 | 23% / 74% |  |
| 18 | **72,000** | [goose-native-tbsvttr](submissions/goose-native-tbsvttr) | [#32](https://github.com/arjaythedev/multicore-server-challenge/pull/32) @tbsvttr | direct | 18,985 | 20 | 482 | 15% / 62% |  |
| 19 | **68,000** | [c-epoll-umitaltintas](submissions/c-epoll-umitaltintas) | [#52](https://github.com/arjaythedev/multicore-server-challenge/pull/52) @umitaltintas | direct | 17,695 | 251 | 381 | 24% / 64% |  |
| 20 | **68,000** | [cpp-asio-c-hatton](submissions/cpp-asio-c-hatton) | [#4](https://github.com/arjaythedev/multicore-server-challenge/pull/4) @C-Hatton | direct | 17,887 | 94 | 174 | 27% / 71% |  |
| 21 | **67,000** | [elixir-gentcp-chuukwudi](submissions/elixir-gentcp-chuukwudi) | [#42](https://github.com/arjaythedev/multicore-server-challenge/pull/42) @Chuukwudi | direct | 17,292 | 364 | 506 | 35% / 60% |  |
| 22 | **62,000** | [go-epoll-crazy-vedic](submissions/go-epoll-crazy-vedic) | [#46](https://github.com/arjaythedev/multicore-server-challenge/pull/46) @crazy-vedic | direct | 16,327 | 90 | 165 | 20% / 73% |  |
| 23 | **62,000** | [goose-epoll-xeonfx](submissions/goose-epoll-xeonfx) | [#31](https://github.com/arjaythedev/multicore-server-challenge/pull/31) @XeonFX | direct | 16,311 | 30 | 842 | 17% / 71% |  |
| 24 | **61,000** | [go-epoll-o7livetype](submissions/go-epoll-o7livetype) | [#28](https://github.com/arjaythedev/multicore-server-challenge/pull/28) @o7LiveType | direct | 15,865 | 351 | 484 | 20% / 73% |  |
| 25 | **58,000** | [rust-hyper-cknutson12](submissions/rust-hyper-cknutson12) | [#1](https://github.com/arjaythedev/multicore-server-challenge/pull/1) @cknutson12 | direct | 15,075 | 223 | 367 | 29% / 69% |  |
| 26 | **56,000** | [c-iouring-gilnett](submissions/c-iouring-gilnett) | [#58](https://github.com/arjaythedev/multicore-server-challenge/pull/58) @gilnett | direct | 14,775 | 53 | 155 | 19% / 71% |  |
| 27 | **49,000** | [gleam-raw-kimmotamio](submissions/gleam-raw-kimmotamio) | [#54](https://github.com/arjaythedev/multicore-server-challenge/pull/54) @kimmotamio | direct | 12,935 | 26 | 374 | 28% / 51% |  |
| 28 | **46,000** | [kotlin-vertx-canleon](submissions/kotlin-vertx-canleon) | [#30](https://github.com/arjaythedev/multicore-server-challenge/pull/30) @canleon | direct | 11,923 | 352 | 440 | 37% / 51% |  |
| 29 | **46,000** | [python-uvloop-bensgilbert](https://github.com/arjaythedev/multicore-server-challenge/pull/13) | [#13](https://github.com/arjaythedev/multicore-server-challenge/pull/13) @bensgilbert | direct | 11,572 | 423 | 519 | 38% / 58% | Not merged yet: restarts crashed workers (rule 9). No worker restarted during the run, so the score stands |
| 30 | **44,000** | [go-fasthttp-o7livetype](submissions/go-fasthttp-o7livetype) | [#27](https://github.com/arjaythedev/multicore-server-challenge/pull/27) @o7LiveType | nginx | 11,321 | 496 | 620 | 23% / 53% (+ Nginx 19%) |  |
| 31 | **44,000** | [kotlin-ktor-canleon](submissions/kotlin-ktor-canleon) | [#29](https://github.com/arjaythedev/multicore-server-challenge/pull/29) @canleon | direct | 10,948 | 496 | 664 | 45% / 49% |  |
| 32 | **40,000** | [purebasic-epoll-ALharchi](submissions/purebasic-epoll-ALharchi) | [#41](https://github.com/arjaythedev/multicore-server-challenge/pull/41) @ALharchi | direct | 10,538 | 121 | 356 | 20% / 62% |  |
| 33 | **34,000** | [python-rawsocket-shawal-mbalire](submissions/python-rawsocket-shawal-mbalire) | [#40](https://github.com/arjaythedev/multicore-server-challenge/pull/40) @shawal-mbalire | direct | 8,909 | 218 | 407 | 33% / 50% |  |
| 34 | **33,000** | [lua-openresty-yar0slav](submissions/lua-openresty-yar0slav) | [#19](https://github.com/arjaythedev/multicore-server-challenge/pull/19) @yar0slav | direct | 8,616 | 432 | 783 | 37% / 49% |  |
| 35 | **32,000** | [elixir-raw-foovoo](submissions/elixir-raw-foovoo) | [#12](https://github.com/arjaythedev/multicore-server-challenge/pull/12) @FooVoo | direct | 7,999 | 323 | 382 | 37% / 48% |  |
| 36 | **32,000** | [rust-urus-markk116](submissions/rust-urus-markk116) | [#25](https://github.com/arjaythedev/multicore-server-challenge/pull/25) @Markk116 | direct | 8,313 | 438 | 540 | 27% / 46% |  |
| 37 | **27,000** | [java-jdk-httpserver-bowbahdoe](submissions/java-jdk-httpserver-bowbahdoe) | [#55](https://github.com/arjaythedev/multicore-server-challenge/pull/55) @bowbahdoe | direct | 7,110 | 127 | 283 | 33% / 60% |  |
| 38 | **27,000** | [nim-conduit-NioHast](submissions/nim-conduit-NioHast) | [#38](https://github.com/arjaythedev/multicore-server-challenge/pull/38) @NioHast | direct | 7,081 | 209 | 524 | 33% / 49% |  |
| 39 | **26,000** | [d-vibe-cyrusmsk](submissions/d-vibe-cyrusmsk) | [#17](https://github.com/arjaythedev/multicore-server-challenge/pull/17) @cyrusmsk | direct | 6,854 | 71 | 375 | 31% / 44% |  |
| 40 | **25,000** | [pony-stallion-contact-red](submissions/pony-stallion-contact-red) | [#24](https://github.com/arjaythedev/multicore-server-challenge/pull/24) @redvers | direct | 6,454 | 473 | 733 | 33% / 52% |  |
| 41 | **24,000** | [go example](examples/go) (the video's server) | — | nginx | 6,192 | 483 | 701 | 27% / 47% (+ Nginx 11%) |  |
| 42 | **23,000** | [d-arsd-cyrusmsk](submissions/d-arsd-cyrusmsk) | [#16](https://github.com/arjaythedev/multicore-server-challenge/pull/16) @cyrusmsk | direct | 5,952 | 373 | 577 | 24% / 66% |  |
| 43 | **22,000** | [rust example](examples/rust) (the video's server) | — | nginx | 5,734 | 233 | 334 | 25% / 50% (+ Nginx 11%) |  |
| 44 | **21,000** | [java example](examples/java) (the video's server) | — | nginx | 5,528 | 104 | 182 | 30% / 46% (+ Nginx 11%) |  |
| 45 | **20,000** | [swift-hummingbird-denizakya](submissions/swift-hummingbird-denizakya) | [#9](https://github.com/arjaythedev/multicore-server-challenge/pull/9) @denizak | nginx | 5,077 | 339 | 400 | 48% / 40% (+ Nginx 10%) |  |
| 46 | **20,000** | [v-fasthttp-ulises-jeremias](https://github.com/arjaythedev/multicore-server-challenge/pull/2) | [#2](https://github.com/arjaythedev/multicore-server-challenge/pull/2) @ulises-jeremias | direct | 5,193 | 351 | 563 | 12% / 63% | Not merged yet: install.sh fails on a clean box (V's bootstrap `vc` isn't pinned); scored with vc pinned by hand |
| 47 | **18,000** | [bun-native-PetarGeorgiev-hash](submissions/bun-native-PetarGeorgiev-hash) | [#26](https://github.com/arjaythedev/multicore-server-challenge/pull/26) @PetarGeorgiev-hash | direct | 4,591 | 296 | 736 | 18% / 33% |  |
| 48 | **11,000** | [chicken-spiffy-wardjm](submissions/chicken-spiffy-wardjm) | [#44](https://github.com/arjaythedev/multicore-server-challenge/pull/44) @wardjm | nginx | 2,904 | 75 | 172 | 49% / 32% (+ Nginx 7%) |  |
| 49 | **10,000** | [python example](examples/python) (the video's server) | — | nginx | 2,634 | 82 | 150 | 49% / 25% (+ Nginx 6%) |  |
| 50 | **8,500** | [ruby-rails-Alex-Bradshaw](submissions/ruby-rails-Alex-Bradshaw) | [#51](https://github.com/arjaythedev/multicore-server-challenge/pull/51) @Alex-Bradshaw | nginx | 2,147 | 484 | 553 | 48% / 31% (+ Nginx 5%) |  |
| 51 | **8,300** | [csharp-efcore-xeonfx](submissions/csharp-efcore-xeonfx) | [#20](https://github.com/arjaythedev/multicore-server-challenge/pull/20) @XeonFX | direct | 2,108 | 447 | 720 | 19% / 78% |  |
| 52 | **1,100** | [perl-mojolicious-denizakya](submissions/perl-mojolicious-denizakya) | [#23](https://github.com/arjaythedev/multicore-server-challenge/pull/23) @denizak | nginx | 287 | 197 | 327 | 8% / 3% (+ Nginx 0%) |  |

## Not scored

| Submission | PR | Why |
|---|---|---|
| [c-iouring-27bhd](https://github.com/arjaythedev/multicore-server-challenge/pull/5) | [#5](https://github.com/arjaythedev/multicore-server-challenge/pull/5) @27bhd | No 5-minute hold passed: POST /api/articles takes ~2 s even on an idle box and blocks its worker, so p99 > 1 s from ~100 users (2-minute probes passed at 100) |
| [c-iouring-ssmurfgg04-gif](https://github.com/arjaythedev/multicore-server-challenge/pull/35) | [#35](https://github.com/arjaythedev/multicore-server-challenge/pull/35) @ssmurfgg04-gif | No hold passed at be1897a: errors and 10 s timeouts from the 2,000-user warmup on, then the server stopped answering (health check timed out) and never recovered, failing even at 10 users |
| [cpp-liburing-mattiasca06](https://github.com/arjaythedev/multicore-server-challenge/pull/60) | [#60](https://github.com/arjaythedev/multicore-server-challenge/pull/60) @mattiasca06 | Didn't start at 0593cca: every worker exits with 'io_uring_setup_buf_ring: Invalid argument' on the target (kernel 6.8), so conformance never ran |
| [d-photon-cyrusmsk](https://github.com/arjaythedev/multicore-server-challenge/pull/34) | [#34](https://github.com/arjaythedev/multicore-server-challenge/pull/34) @cyrusmsk | Crashed again at efa6bbd (SIGILL, core dumped) during the search: probes passed up to 32,000 users (8,463 req/s, p95 17 ms), failed at 64,000 ('database pool exhausted' errors, 10 s timeouts, 17% errors), then the server died at the end of that probe; no hold ran |

CPU is the share of the whole box (8 cores) used by your server and by Postgres during the scored 5 minutes. Raw results for every run (each probe and hold, per-endpoint latencies, the box's CPU every second) are kept and can be shared on request.
