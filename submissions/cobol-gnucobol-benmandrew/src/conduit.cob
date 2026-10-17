>>SOURCE FORMAT FREE
*> conduit in GnuCOBOL: the 19 endpoints of SPEC.md.
*>
*>   - The parent forks WORKERS processes and one bcrypt process. Each worker has its own SO_REUSEPORT listener,
*>     its own epoll loop and its own PG_CONNS Postgres connections; nothing is shared between workers.
*>   - Every statement is prepared once per connection and returns binary results. A request appends Bind and
*>     Execute for each of its statements. Read-only requests share one Sync and are answered at their last
*>     CommandComplete; a request that writes takes its own Sync and is answered at ReadyForQuery, after the
*>     commit. The writer holds back while PG_MAX_SYNCS Syncs are unanswered, so reads queued meanwhile join one
*>     group.
*>   - Rows are rendered to JSON as they arrive, straight from the Postgres read buffer, and a response goes out
*>     in one writev.
*>   - bcrypt runs in the bcrypt process, four hashes at a time in lockstep, on BCRYPT_THREADS hasher processes.
*>
*> All logic is COBOL. It calls libc for system calls, libcrypto for SHA-256 (JWT and the SCRAM login to
*> Postgres), and the C bcrypt in crypt_blowfish.c.
*>
*> The source is split into copybooks: ws-*.cpy hold data, pd-*.cpy hold paragraphs, one pair per module.
*> GnuCOBOL arithmetic on 64-bit fields, and COMPUTE on any field, goes through decimal routines that cost
*> 50 to 260 ns per operation, so the code on the request path keeps to ADD, SUBTRACT, MOVE between fields of
*> one type, comparisons and subscripts, which compile to plain C.
IDENTIFICATION DIVISION.
PROGRAM-ID. conduit.

ENVIRONMENT DIVISION.
CONFIGURATION SECTION.
SPECIAL-NAMES.
    *> Bytes a JSON string can hold unescaped.
    CLASS JSON-PLAIN IS X"20" THRU X"21" X"23" THRU X"5B" X"5D" THRU X"FF".

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "ws-main.cpy".
COPY "ws-loop.cpy".
COPY "ws-http.cpy".
COPY "ws-jin.cpy".
COPY "ws-jout.cpy".
COPY "ws-jwt.cpy".
COPY "ws-pg.cpy".
COPY "ws-sql.cpy".
COPY "ws-app.cpy".
COPY "ws-bc.cpy".

LINKAGE SECTION.
COPY "ls.cpy".
COPY "ls-jin.cpy".
COPY "ls-jout.cpy".
COPY "ls-jwt.cpy".
COPY "ls-pg.cpy".
COPY "ls-bc.cpy".
COPY "ls-app.cpy".

PROCEDURE DIVISION.
COPY "pd-main.cpy".
COPY "pd-loop.cpy".
COPY "pd-http.cpy".
COPY "pd-app.cpy".
COPY "pd-jin.cpy".
COPY "pd-jout.cpy".
COPY "pd-jwt.cpy".
COPY "pd-pg.cpy".
COPY "pd-pgconn.cpy".
COPY "pd-sql.cpy".
COPY "pd-bc.cpy".
