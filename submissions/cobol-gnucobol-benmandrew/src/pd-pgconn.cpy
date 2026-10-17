*> ================= pg: connecting, start-up and SCRAM =================
*> Start-up code: COMPUTE and STRING are fine here.

*> In each worker before the loop: the buffers, then N-PG connections. A connection that cannot start stops
*> the worker (and so the server).
PG-INIT-ALL.
    MOVE 0 TO PG-DOWN
    MOVE PG-PB-SIZE TO PG-SZ
    CALL "malloc" USING BY VALUE PG-SZ RETURNING PG-PB-PTR
    PERFORM VARYING PG-CI FROM 1 BY 1 UNTIL PG-CI > N-PG
        MOVE PG-RB-SIZE TO PG-SZ
        CALL "malloc" USING BY VALUE PG-SZ RETURNING PG-RB-PTR (PG-CI)
        MOVE PG-WB-SIZE TO PG-SZ
        CALL "malloc" USING BY VALUE PG-SZ RETURNING PG-WB-PTR (PG-CI)
        MOVE PG-OUT-SIZE TO PG-SZ
        CALL "malloc" USING BY VALUE PG-SZ RETURNING PG-OUT-PTR (PG-CI)
        IF PG-PB-PTR = NULL OR PG-RB-PTR (PG-CI) = NULL OR PG-WB-PTR (PG-CI) = NULL
                OR PG-OUT-PTR (PG-CI) = NULL
            DISPLAY "postgres: out of memory" UPON SYSERR
            MOVE 1 TO RETURN-CODE
            STOP RUN
        END-IF
        MOVE 50 TO PG-BACKOFF (PG-CI)
        PERFORM PG-CONNECT
        IF PG-CONN-OK = 0
            DISPLAY "postgres: " PG-WHY (1:PG-WHY-LEN) UPON SYSERR
            MOVE 1 TO RETURN-CODE
            STOP RUN
        END-IF
    END-PERFORM.

*> Before epoll_wait while a connection is down: EP-TIMEOUT is the time until the earliest retry.
PG-RETRY-TIMEOUT.
    PERFORM GET-NOW-MS
    PERFORM VARYING PG-I FROM 1 BY 1 UNTIL PG-I > N-PG
        IF PG-UP (PG-I) = 0
            COMPUTE PG-DT = PG-RETRY-AT (PG-I) - NOW-MS
            IF PG-DT < 0
                MOVE 0 TO PG-DT
            END-IF
            IF EP-TIMEOUT < 0 OR PG-DT < EP-TIMEOUT
                MOVE PG-DT TO EP-TIMEOUT
            END-IF
        END-IF
    END-PERFORM.

*> After the events: reconnect the connections whose retry time has come. Backoff 50 ms doubling to 2 s.
PG-RETRY-DUE.
    PERFORM GET-NOW-MS
    PERFORM VARYING PG-CI FROM 1 BY 1 UNTIL PG-CI > N-PG
        IF PG-UP (PG-CI) = 0 AND PG-RETRY-AT (PG-CI) <= NOW-MS
            PERFORM PG-CONNECT
            IF PG-CONN-OK = 1
                SUBTRACT 1 FROM PG-DOWN
                MOVE 50 TO PG-BACKOFF (PG-CI)
                DISPLAY "postgres: reconnected" UPON SYSERR
            ELSE
                DISPLAY "postgres: reconnect failed: " PG-WHY (1:PG-WHY-LEN) UPON SYSERR
                COMPUTE PG-BACKOFF (PG-CI) = PG-BACKOFF (PG-CI) * 2
                IF PG-BACKOFF (PG-CI) > 2000
                    MOVE 2000 TO PG-BACKOFF (PG-CI)
                END-IF
                PERFORM GET-NOW-MS
                COMPUTE PG-RETRY-AT (PG-CI) = NOW-MS + PG-BACKOFF (PG-CI)
            END-IF
        END-IF
    END-PERFORM.

*> Connects connection PG-CI, blocking: start-up, authentication, the session settings, a Parse of every
*> statement. Then the socket is made non-blocking and registered in epoll. PG-CONN-OK = 1 on success; otherwise
*> 0 with the reason in PG-WHY, and the socket is closed.
PG-CONNECT.
    MOVE 0 TO PG-CONN-OK PG-UP (PG-CI) PG-WANT-OUT (PG-CI) PG-OPEN (PG-CI) PG-ERR (PG-CI)
              PG-RLEN (PG-CI) PG-WLEN (PG-CI) PG-WOFF (PG-CI) PG-WEND (PG-CI) PG-QSYNCS (PG-CI)
              PG-SSYNCS (PG-CI) PG-RN (PG-CI) PG-RT (PG-CI) PG-SEQ-HEAD (PG-CI) PG-SEQ-NEXT (PG-CI)
              PG-NDONE (PG-CI) PG-ROWS (PG-CI) PG-OUTLEN (PG-CI)
              PG-NROWS (PG-CI, 1) PG-NROWS (PG-CI, 2) PG-NROWS (PG-CI, 3) PG-NROWS (PG-CI, 4)
    MOVE 1 TO PG-RPOS (PG-CI) PG-RH (PG-CI)
    MOVE SPACES TO PG-SQLSTATE (PG-CI)
    SET ADDRESS OF L-RB TO PG-RB-PTR (PG-CI)
    SET ADDRESS OF L-PG-WB TO PG-WB-PTR (PG-CI)
    CALL "socket" USING BY VALUE K-AF-INET BY VALUE K-SOCK-STREAM BY VALUE K-0 RETURNING PG-FD (PG-CI)
    IF PG-FD (PG-CI) < 0
        MOVE "cannot create a socket" TO PG-WHY
        MOVE 22 TO PG-WHY-LEN
        EXIT PARAGRAPH
    END-IF
    *> a server that does not answer fails the start-up instead of blocking the worker
    CALL "setsockopt" USING BY VALUE PG-FD (PG-CI) BY VALUE K-SOL-SOCKET BY VALUE PG-K-RCVTIMEO
        BY REFERENCE PG-TV BY VALUE PG-K-TV-LEN
    CALL "setsockopt" USING BY VALUE PG-FD (PG-CI) BY VALUE K-SOL-SOCKET BY VALUE PG-K-SNDTIMEO
        BY REFERENCE PG-TV BY VALUE PG-K-TV-LEN
    MOVE 2 TO SA-FAMILY
    DIVIDE DB-PORT BY 256 GIVING SA-PORT-HI REMAINDER SA-PORT-LO
    CALL "inet_addr" USING BY REFERENCE DB-HOST-Z RETURNING SA-ADDR
    MOVE LOW-VALUES TO SA-ZERO
    CALL "connect" USING BY VALUE PG-FD (PG-CI) BY REFERENCE SA BY VALUE K-SA-LEN RETURNING RC
    IF RC NOT = 0
        MOVE L-ERRNO TO PG-NUM-ED
        MOVE SPACES TO PG-WHY
        MOVE 1 TO PG-WHY-LEN
        STRING "cannot connect to " DB-HOST (1:DB-HOST-LEN) ", errno " FUNCTION TRIM (PG-NUM-ED)
            DELIMITED BY SIZE INTO PG-WHY WITH POINTER PG-WHY-LEN
        SUBTRACT 1 FROM PG-WHY-LEN
        PERFORM PG-CONNECT-FAILED
        EXIT PARAGRAPH
    END-IF
    *> Pipelining sends a new write before the previous one is acknowledged, which Nagle would hold back.
    CALL "setsockopt" USING BY VALUE PG-FD (PG-CI) BY VALUE K-IPPROTO-TCP BY VALUE K-TCP-NODELAY
        BY REFERENCE K-OPT-ON BY VALUE K-OPT-LEN

    *> StartupMessage: length, protocol 3.0, then name/value pairs (empty values left out).
    MOVE 1 TO PG-SP
    STRING X"00000000" X"00030000" DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    IF DB-USER-LEN > 0
        STRING "user" X"00" DB-USER (1:DB-USER-LEN) X"00" DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    END-IF
    IF DB-NAME-LEN > 0
        STRING "database" X"00" DB-NAME (1:DB-NAME-LEN) X"00" DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    END-IF
    STRING "client_encoding" X"00" "UTF8" X"00" "application_name" X"00" "conduit-cobol" X"00" X"00"
        DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    COMPUTE PG-BE4 = PG-SP - 1
    MOVE PG-BE4-X TO L-PG-WB (1:4)
    PERFORM PG-SEND-START
    IF PG-CONN-OK = 2
        PERFORM PG-CONNECT-FAILED
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO PG-READY-WANT
    PERFORM PG-STARTUP-REPLIES
    IF PG-CONN-OK = 2
        PERFORM PG-CONNECT-FAILED
        EXIT PARAGRAPH
    END-IF

    *> Session settings, then every statement prepared once for the life of the connection, then a Sync.
    MOVE 1 TO PG-SP
    MOVE PG-SP TO PG-MSTART
    IF SESSION-SQL-LEN > 0
        STRING "Q" X"00000000" SESSION-SQL (1:SESSION-SQL-LEN) X"00" DELIMITED BY SIZE INTO L-PG-WB
            WITH POINTER PG-SP
    ELSE
        STRING "Q" X"00000000" X"00" DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    END-IF
    PERFORM PG-SET-LEN
    PERFORM VARYING PG-I FROM 1 BY 1 UNTIL PG-I > SQ-COUNT
        MOVE PG-SP TO PG-MSTART
        STRING "P" X"00000000" SQ-NAME (PG-I) (1:SQ-NAME-LEN (PG-I)) X"00"
            SQ-AREA (SQ-OFF (PG-I):SQ-LEN (PG-I)) X"00" X"0000"
            DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
        PERFORM PG-SET-LEN
    END-PERFORM
    STRING PG-SYNC-MSG DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    PERFORM PG-SEND-START
    IF PG-CONN-OK = 2
        PERFORM PG-CONNECT-FAILED
        EXIT PARAGRAPH
    END-IF
    MOVE 2 TO PG-READY-WANT
    PERFORM PG-STARTUP-REPLIES
    IF PG-CONN-OK = 2
        PERFORM PG-CONNECT-FAILED
        EXIT PARAGRAPH
    END-IF

    MOVE 0 TO PG-RLEN (PG-CI)
    MOVE 1 TO PG-RPOS (PG-CI)
    CALL "fcntl" USING BY VALUE PG-FD (PG-CI) BY VALUE K-F-SETFL BY VALUE K-O-NONBLOCK
    MOVE 3 TO CN-KIND (PG-FD (PG-CI) + 1)
    MOVE PG-CI TO CN-PG (PG-FD (PG-CI) + 1)
    MOVE K-EV-IN TO EV-EVENTS
    MOVE PG-FD (PG-CI) TO EV-FD
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE PG-FD (PG-CI) BY REFERENCE EV
    MOVE 1 TO PG-UP (PG-CI)
    MOVE 1 TO PG-CONN-OK.

PG-CONNECT-FAILED.
    CALL "close" USING BY VALUE PG-FD (PG-CI)
    MOVE 0 TO PG-CONN-OK.

*> Fills in the length of the message that starts at PG-MSTART and ends before PG-SP.
PG-SET-LEN.
    COMPUTE PG-BE4 = PG-SP - PG-MSTART - 1
    MOVE PG-BE4-X TO L-PG-WB (PG-MSTART + 1:4).

*> Writes L-PG-WB (1:PG-SP - 1), blocking. PG-CONN-OK = 2 on failure.
PG-SEND-START.
    MOVE 0 TO PG-K
    COMPUTE PG-REST = PG-SP - 1
    PERFORM UNTIL PG-K >= PG-REST
        COMPUTE PG-SZ = PG-REST - PG-K
        CALL "write" USING BY VALUE PG-FD (PG-CI) BY REFERENCE L-PG-WB (PG-K + 1:1) BY VALUE PG-SZ
            RETURNING PG-N
        IF PG-N <= 0
            IF PG-N < 0 AND L-ERRNO = EINTR
                MOVE 0 TO PG-N
            ELSE
                MOVE "write failed at start-up" TO PG-WHY
                MOVE 24 TO PG-WHY-LEN
                MOVE 2 TO PG-CONN-OK
                EXIT PERFORM
            END-IF
        END-IF
        ADD PG-N TO PG-K
    END-PERFORM.

*> Reads (blocking) until PG-READY-WANT ReadyForQuery messages have arrived, answering authentication requests.
PG-STARTUP-REPLIES.
    MOVE 0 TO PG-READY-N
    PERFORM UNTIL PG-READY-N >= PG-READY-WANT OR PG-CONN-OK = 2
        PERFORM PG-NEXT-MSG
        IF PG-CONN-OK NOT = 2
            EVALUATE PG-MT
                WHEN "R"
                    PERFORM PG-AUTH
                WHEN "E"
                    COMPUTE PG-EB = PG-MPOS
                    COMPUTE PG-EE = PG-MPOS + PG-ML - 5
                    PERFORM PG-PARSE-ERR
                    MOVE 2 TO PG-CONN-OK
                WHEN "Z"
                    ADD 1 TO PG-READY-N
            END-EVALUATE
        END-IF
    END-PERFORM.

*> Blocking: the next whole message of connection PG-CI. Sets PG-MT, PG-ML (its length, without the type byte)
*> and PG-MPOS (where its payload starts in L-RB).
PG-NEXT-MSG.
    PERFORM FOREVER
        COMPUTE PG-AV = PG-RLEN (PG-CI) - PG-RPOS (PG-CI) + 1
        IF PG-AV >= 5
            MOVE L-RB (PG-RPOS (PG-CI) + 1:4) TO PG-BE4-X
            MOVE PG-BE4 TO PG-ML
            IF PG-AV >= PG-ML + 1
                EXIT PERFORM
            END-IF
        END-IF
        IF PG-RPOS (PG-CI) > 1
            COMPUTE PG-REST = PG-RLEN (PG-CI) - PG-RPOS (PG-CI) + 1
            IF PG-REST > 0
                MOVE PG-REST TO PG-SZ
                CALL "memmove" USING BY REFERENCE L-RB BY REFERENCE L-RB (PG-RPOS (PG-CI):1) BY VALUE PG-SZ
            END-IF
            MOVE PG-REST TO PG-RLEN (PG-CI)
            MOVE 1 TO PG-RPOS (PG-CI)
        END-IF
        COMPUTE PG-SZ = PG-RB-SIZE - PG-RLEN (PG-CI)
        CALL "read" USING BY VALUE PG-FD (PG-CI) BY REFERENCE L-RB (PG-RLEN (PG-CI) + 1:1) BY VALUE PG-SZ
            RETURNING PG-N
        IF PG-N <= 0
            IF PG-N < 0 AND L-ERRNO = EINTR
                MOVE 0 TO PG-N
            ELSE
                MOVE "connection closed during start-up" TO PG-WHY
                MOVE 33 TO PG-WHY-LEN
                MOVE 2 TO PG-CONN-OK
                EXIT PARAGRAPH
            END-IF
        END-IF
        ADD PG-N TO PG-RLEN (PG-CI)
    END-PERFORM
    MOVE L-RB (PG-RPOS (PG-CI):1) TO PG-MT
    COMPUTE PG-MPOS = PG-RPOS (PG-CI) + 5
    COMPUTE PG-RPOS (PG-CI) = PG-RPOS (PG-CI) + PG-ML + 1.

PG-AUTH.
    MOVE L-RB (PG-MPOS:4) TO PG-BE4-X
    MOVE PG-BE4 TO PG-AUTH-CODE
    EVALUATE PG-AUTH-CODE
        WHEN 0
            CONTINUE
        WHEN 3
            MOVE 1 TO PG-SP
            MOVE PG-SP TO PG-MSTART
            IF DB-PASS-LEN > 0
                STRING "p" X"00000000" DB-PASS (1:DB-PASS-LEN) X"00" DELIMITED BY SIZE INTO L-PG-WB
                    WITH POINTER PG-SP
            ELSE
                STRING "p" X"00000000" X"00" DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
            END-IF
            PERFORM PG-SET-LEN
            PERFORM PG-SEND-START
        WHEN 10
            PERFORM PG-SCRAM-FIRST
        WHEN 11
            PERFORM PG-SCRAM-FINAL
        WHEN 12
            CONTINUE
        WHEN OTHER
            MOVE PG-AUTH-CODE TO PG-NUM-ED
            MOVE SPACES TO PG-WHY
            MOVE 1 TO PG-WHY-LEN
            STRING "unsupported auth method " FUNCTION TRIM (PG-NUM-ED) DELIMITED BY SIZE INTO PG-WHY
                WITH POINTER PG-WHY-LEN
            SUBTRACT 1 FROM PG-WHY-LEN
            MOVE 2 TO PG-CONN-OK
    END-EVALUATE.

PG-SCRAM-FIRST.
    CALL "RAND_bytes" USING BY REFERENCE PG-SC-NONCE-RAW BY VALUE K-18 RETURNING PG-SC-RC
    CALL "EVP_EncodeBlock" USING BY REFERENCE PG-SC-NONCE-B64 BY REFERENCE PG-SC-NONCE-RAW BY VALUE K-18
        RETURNING PG-SC-RC
    MOVE SPACES TO PG-SC-CFB
    MOVE 1 TO PG-SC-CFB-LEN
    STRING "n=,r=" PG-SC-NONCE-B64 (1:PG-SC-RC) DELIMITED BY SIZE INTO PG-SC-CFB WITH POINTER PG-SC-CFB-LEN
    SUBTRACT 1 FROM PG-SC-CFB-LEN
    *> SASLInitialResponse: the mechanism, then the client-first message with its length.
    MOVE 1 TO PG-SP
    MOVE PG-SP TO PG-MSTART
    COMPUTE PG-BE4 = PG-SC-CFB-LEN + 3
    STRING "p" X"00000000" "SCRAM-SHA-256" X"00" PG-BE4-X "n,," PG-SC-CFB (1:PG-SC-CFB-LEN)
        DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    PERFORM PG-SET-LEN
    PERFORM PG-SEND-START.

PG-SCRAM-FINAL.
    COMPUTE PG-SC-SF-LEN = PG-ML - 8
    MOVE SPACES TO PG-SC-SF
    MOVE L-RB (PG-MPOS + 4:PG-SC-SF-LEN) TO PG-SC-SF
    MOVE SPACES TO PG-SC-ATTR (1) PG-SC-ATTR (2) PG-SC-ATTR (3)
    MOVE 0 TO PG-SC-ATTR-LEN (1) PG-SC-ATTR-LEN (2) PG-SC-ATTR-LEN (3) PG-SC-NONCE-LEN PG-SC-SALT-B64-LEN
              PG-SC-ITERS
    UNSTRING PG-SC-SF (1:PG-SC-SF-LEN) DELIMITED BY ","
        INTO PG-SC-ATTR (1) COUNT IN PG-SC-ATTR-LEN (1)
             PG-SC-ATTR (2) COUNT IN PG-SC-ATTR-LEN (2)
             PG-SC-ATTR (3) COUNT IN PG-SC-ATTR-LEN (3)
    PERFORM VARYING PG-I FROM 1 BY 1 UNTIL PG-I > 3
        IF PG-SC-ATTR-LEN (PG-I) > 2
            EVALUATE PG-SC-ATTR (PG-I) (1:2)
                WHEN "r="
                    COMPUTE PG-SC-NONCE-LEN = PG-SC-ATTR-LEN (PG-I) - 2
                    MOVE PG-SC-ATTR (PG-I) (3:PG-SC-NONCE-LEN) TO PG-SC-NONCE
                WHEN "s="
                    COMPUTE PG-SC-SALT-B64-LEN = PG-SC-ATTR-LEN (PG-I) - 2
                    MOVE PG-SC-ATTR (PG-I) (3:PG-SC-SALT-B64-LEN) TO PG-SC-SALT-B64
                WHEN "i="
                    COMPUTE PG-SC-ITERS = FUNCTION NUMVAL (PG-SC-ATTR (PG-I) (3:PG-SC-ATTR-LEN (PG-I) - 2))
            END-EVALUATE
        END-IF
    END-PERFORM
    IF PG-SC-NONCE-LEN < PG-SC-CFB-LEN - 5 OR PG-SC-SALT-B64-LEN = 0 OR PG-SC-ITERS < 1
            OR PG-SC-NONCE (1:PG-SC-CFB-LEN - 5) NOT = PG-SC-CFB (6:PG-SC-CFB-LEN - 5)
        MOVE "SCRAM: bad server-first message" TO PG-WHY
        MOVE 31 TO PG-WHY-LEN
        MOVE 2 TO PG-CONN-OK
        EXIT PARAGRAPH
    END-IF
    CALL "EVP_DecodeBlock" USING BY REFERENCE PG-SC-SALT BY REFERENCE PG-SC-SALT-B64 BY VALUE PG-SC-SALT-B64-LEN
        RETURNING PG-SC-SALT-LEN
    MOVE 0 TO PG-SC-PAD
    INSPECT PG-SC-SALT-B64 (1:PG-SC-SALT-B64-LEN) TALLYING PG-SC-PAD FOR ALL "="
    SUBTRACT PG-SC-PAD FROM PG-SC-SALT-LEN
    CALL "EVP_sha256" RETURNING PG-SC-MD
    *> SaltedPassword = Hi(password, salt, i), ClientKey = HMAC(SaltedPassword, "Client Key")
    CALL "PKCS5_PBKDF2_HMAC" USING BY REFERENCE DB-PASS BY VALUE DB-PASS-LEN BY REFERENCE PG-SC-SALT
        BY VALUE PG-SC-SALT-LEN BY VALUE PG-SC-ITERS BY VALUE PG-SC-MD BY VALUE K-32 BY REFERENCE PG-SC-SALTED
        RETURNING PG-SC-RC
    CALL "HMAC" USING BY VALUE PG-SC-MD BY REFERENCE PG-SC-SALTED BY VALUE K-32 BY REFERENCE PG-SC-CK-LABEL
        BY VALUE K-10-D BY REFERENCE PG-SC-CKEY BY VALUE NULL-PTR RETURNING PTR
    CALL "SHA256" USING BY REFERENCE PG-SC-CKEY BY VALUE K-32-D BY REFERENCE PG-SC-SKEY RETURNING PTR
    MOVE SPACES TO PG-SC-WP PG-SC-AM
    MOVE 1 TO PG-SC-WP-LEN
    STRING "c=biws,r=" PG-SC-NONCE (1:PG-SC-NONCE-LEN) DELIMITED BY SIZE INTO PG-SC-WP WITH POINTER PG-SC-WP-LEN
    SUBTRACT 1 FROM PG-SC-WP-LEN
    MOVE 1 TO PG-SC-AM-LEN
    STRING PG-SC-CFB (1:PG-SC-CFB-LEN) "," PG-SC-SF (1:PG-SC-SF-LEN) "," PG-SC-WP (1:PG-SC-WP-LEN)
        DELIMITED BY SIZE INTO PG-SC-AM WITH POINTER PG-SC-AM-LEN
    SUBTRACT 1 FROM PG-SC-AM-LEN
    MOVE PG-SC-AM-LEN TO PG-SC-AM-LEN-D
    *> ClientProof = ClientKey XOR HMAC(StoredKey, AuthMessage)
    CALL "HMAC" USING BY VALUE PG-SC-MD BY REFERENCE PG-SC-SKEY BY VALUE K-32 BY REFERENCE PG-SC-AM
        BY VALUE PG-SC-AM-LEN-D BY REFERENCE PG-SC-SIG BY VALUE NULL-PTR RETURNING PTR
    MOVE PG-SC-CKEY TO PG-SC-PROOF
    CALL "CBL_XOR" USING PG-SC-SIG PG-SC-PROOF BY VALUE K-32
    CALL "EVP_EncodeBlock" USING BY REFERENCE PG-SC-PROOF-B64 BY REFERENCE PG-SC-PROOF BY VALUE K-32
        RETURNING PG-SC-RC
    MOVE 1 TO PG-SP
    MOVE PG-SP TO PG-MSTART
    STRING "p" X"00000000" PG-SC-WP (1:PG-SC-WP-LEN) ",p=" PG-SC-PROOF-B64 (1:PG-SC-RC)
        DELIMITED BY SIZE INTO L-PG-WB WITH POINTER PG-SP
    PERFORM PG-SET-LEN
    PERFORM PG-SEND-START.
