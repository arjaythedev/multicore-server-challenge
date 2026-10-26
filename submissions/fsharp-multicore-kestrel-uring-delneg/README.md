# F# multicore: own io_uring loops + own Postgres client (delneg)

Front: direct

Work in progress. F# on .NET 11 RC 3, Kestrel host with an io_uring transport of our own, ported ideas from
csharp-sockets-jh-d (#22), rust-tokio-Scooter1337 (#7) and c-iouring-tigokraft (#10).
