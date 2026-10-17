*> ================= pg: the pipelined Postgres driver =================
*> Every statement is prepared at start-up (pd-pgconn); a request appends a Bind and an Execute per statement. Read-only requests queued on a connection between two writes share
*> one Sync (a group) and are answered at their last CommandComplete; a request that writes takes its own Sync
*> and is answered at its ReadyForQuery, after the commit. An error makes Postgres skip the rest of a group up to
*> its Sync, so the members after the failed one are sent again, each with its own Sync.
*> Everything here runs for every request: binary fields, ADD/SUBTRACT/MOVE and comparisons only.

*> ---------- building a request ----------

PB-BEGIN.
    MOVE 0 TO PB-W PB-NST PB-OVER
    MOVE 1 TO PB-RO.

*> Starts a Bind for statement PB-ST: type, length (filled in by PB-END-STMT), portal, name, format codes, and
*> room for the parameter count.
PB-STMT.
    SET ADDRESS OF L-PB TO PG-PB-PTR
    IF SQ-RO (PB-ST) = 0
        MOVE 0 TO PB-RO
    END-IF
    MOVE PB-W TO PB-END
    ADD 64 TO PB-END
    IF PB-END > PG-PB-SIZE
        MOVE 1 TO PB-OVER
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO PB-W
    MOVE PB-W TO PB-BSTART
    MOVE "B" TO L-PB (PB-W:1)
    ADD 4 TO PB-W
    MOVE SQ-BH-LEN (PB-ST) TO PB-K
    MOVE SQ-BH (PB-ST) (1:PB-K) TO L-PB (PB-W + 1:PB-K)
    ADD PB-K TO PB-W
    MOVE PB-W TO PB-NPPOS
    ADD 1 TO PB-NPPOS
    ADD 2 TO PB-W
    MOVE 0 TO PB-NP.

*> PB-INT-V as decimal text. The digits come from subtracting powers of ten on a BINARY-LONG; a value outside
*> 0 .. 2^31-1 takes the slow path through an edited field.
PB-INT.
    IF PB-OVER = 1
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    MOVE PB-INT-V TO PB-IV
    MOVE 0 TO PB-DL
    IF PB-IV-HI = 0 AND PB-IV-LO >= 0
        MOVE PB-IV-LO TO PB-N
        PERFORM VARYING PB-K FROM 1 BY 1 UNTIL PB-K > 9
            IF PB-N >= PB-POW (PB-K) OR PB-DL > 0
                MOVE 0 TO PB-D
                PERFORM UNTIL PB-N < PB-POW (PB-K)
                    SUBTRACT PB-POW (PB-K) FROM PB-N
                    ADD 1 TO PB-D
                END-PERFORM
                ADD 1 TO PB-DL
                MOVE PB-DIGITS (PB-D + 1:1) TO PB-DIG (PB-DL:1)
            END-IF
        END-PERFORM
        ADD 1 TO PB-DL
        MOVE PB-DIGITS (PB-N + 1:1) TO PB-DIG (PB-DL:1)
    ELSE
        MOVE PB-INT-V TO PB-ED
        PERFORM VARYING PB-K FROM 1 BY 1 UNTIL PB-ED (PB-K:1) NOT = SPACE
            CONTINUE
        END-PERFORM
        PERFORM VARYING PB-K FROM PB-K BY 1 UNTIL PB-K > 20
            ADD 1 TO PB-DL
            MOVE PB-ED (PB-K:1) TO PB-DIG (PB-DL:1)
        END-PERFORM
    END-IF
    MOVE PB-DL TO PB-L
    MOVE X"000000" TO L-PB (PB-W + 1:3)
    MOVE PB-L-X (1:1) TO L-PB (PB-W + 4:1)
    ADD 4 TO PB-W
    MOVE PB-DIG (1:PB-DL) TO L-PB (PB-W + 1:PB-DL)
    ADD PB-DL TO PB-W
    ADD 1 TO PB-NP.

*> L-SRC (PB-OFF:PB-LEN) as a text parameter.
PB-TEXT.
    IF PB-OVER = 1
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    MOVE PB-W TO PB-END
    ADD PB-LEN TO PB-END
    ADD 64 TO PB-END
    IF PB-END > PG-PB-SIZE
        MOVE 1 TO PB-OVER
        EXIT PARAGRAPH
    END-IF
    MOVE PB-LEN TO PB-L
    PERFORM PB-PUT-L
    IF PB-LEN > 0
        MOVE L-SRC (PB-OFF:PB-LEN) TO L-PB (PB-W + 1:PB-LEN)
        ADD PB-LEN TO PB-W
    END-IF
    ADD 1 TO PB-NP.

PB-NULL.
    IF PB-OVER = 1
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    MOVE X"FFFFFFFF" TO L-PB (PB-W + 1:4)
    ADD 4 TO PB-W
    ADD 1 TO PB-NP.

*> The tags JI-BUF (JT-OFF (i):JT-LEN (i)), i = 1..JT-N, as a binary text[]: ndim 1, has_null 0, element oid 25
*> (text), size JT-N, lower bound 1, then each element's length and bytes.
PB-TAGS.
    IF PB-OVER = 1
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    MOVE PB-W TO PB-END
    ADD 64 TO PB-END
    IF PB-END > PG-PB-SIZE
        MOVE 1 TO PB-OVER
        EXIT PARAGRAPH
    END-IF
    MOVE PB-W TO PB-PSTART
    ADD 4 TO PB-W
    MOVE X"000000010000000000000019" TO L-PB (PB-W + 1:12)
    ADD 12 TO PB-W
    MOVE JT-N TO PB-L
    PERFORM PB-PUT-L
    MOVE X"00000001" TO L-PB (PB-W + 1:4)
    ADD 4 TO PB-W
    PERFORM VARYING PB-I FROM 1 BY 1 UNTIL PB-I > JT-N
        MOVE PB-W TO PB-END
        ADD JT-LEN (PB-I) TO PB-END
        ADD 64 TO PB-END
        IF PB-END > PG-PB-SIZE
            MOVE 1 TO PB-OVER
            EXIT PARAGRAPH
        END-IF
        MOVE JT-LEN (PB-I) TO PB-L
        PERFORM PB-PUT-L
        IF PB-L > 0
            MOVE JI-BUF (JT-OFF (PB-I):PB-L) TO L-PB (PB-W + 1:PB-L)
            ADD PB-L TO PB-W
        END-IF
    END-PERFORM
    *> the parameter's length: the bytes after its length field
    MOVE PB-W TO PB-L
    SUBTRACT PB-PSTART FROM PB-L
    SUBTRACT 4 FROM PB-L
    MOVE PB-L-X (4:1) TO L-PB (PB-PSTART + 1:1)
    MOVE PB-L-X (3:1) TO L-PB (PB-PSTART + 2:1)
    MOVE PB-L-X (2:1) TO L-PB (PB-PSTART + 3:1)
    MOVE PB-L-X (1:1) TO L-PB (PB-PSTART + 4:1)
    ADD 1 TO PB-NP.

*> Appends PB-L as a big-endian int32.
PB-PUT-L.
    MOVE PB-L-X (4:1) TO L-PB (PB-W + 1:1)
    MOVE PB-L-X (3:1) TO L-PB (PB-W + 2:1)
    MOVE PB-L-X (2:1) TO L-PB (PB-W + 3:1)
    MOVE PB-L-X (1:1) TO L-PB (PB-W + 4:1)
    ADD 4 TO PB-W.

*> Ends the Bind (parameter count, one result format: binary, the length) and appends an Execute.
PB-END-STMT.
    IF PB-OVER = 1
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    MOVE PB-NP TO PB-L
    MOVE PB-L-X (2:1) TO L-PB (PB-NPPOS:1)
    MOVE PB-L-X (1:1) TO L-PB (PB-NPPOS + 1:1)
    MOVE PG-RESFMT TO L-PB (PB-W + 1:4)
    ADD 4 TO PB-W
    MOVE PB-W TO PB-L
    SUBTRACT PB-BSTART FROM PB-L
    MOVE PB-L-X (4:1) TO L-PB (PB-BSTART + 1:1)
    MOVE PB-L-X (3:1) TO L-PB (PB-BSTART + 2:1)
    MOVE PB-L-X (2:1) TO L-PB (PB-BSTART + 3:1)
    MOVE PB-L-X (1:1) TO L-PB (PB-BSTART + 4:1)
    MOVE PG-EXEC-MSG TO L-PB (PB-W + 1:10)
    ADD 10 TO PB-W
    ADD 1 TO PB-NST.

*> Queues the request built by PB-* for client FX on the live connection with the fewest requests in flight.
*> A read-only request joins that connection's open group (and keeps a copy of its bytes, for a resend); a
*> request that writes seals the open group and takes its own Sync. The write buffer always keeps 5 bytes free
*> for the Sync that seals an open group.
PG-SUBMIT.
    MOVE 0 TO PG-SUBMIT-OK
    IF PB-OVER = 1 OR PB-NST = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO PB-PK
    PERFORM VARYING PB-I FROM 1 BY 1 UNTIL PB-I > N-PG
        IF PG-UP (PB-I) = 1
            IF PB-PK = 0 OR PG-RN (PB-I) < PB-BEST
                MOVE PB-I TO PB-PK
                MOVE PG-RN (PB-I) TO PB-BEST
            END-IF
        END-IF
    END-PERFORM
    IF PB-PK = 0
        EXIT PARAGRAPH
    END-IF
    IF PG-RN (PB-PK) >= PG-RING
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PG-WB TO PG-WB-PTR (PB-PK)
    MOVE PB-W TO PB-NEED
    ADD 10 TO PB-NEED
    MOVE PG-WB-SIZE TO PB-FREE
    SUBTRACT PG-WLEN (PB-PK) FROM PB-FREE
    IF PB-FREE < PB-NEED AND PG-WOFF (PB-PK) > 0
        *> drop the bytes already written
        MOVE PG-WLEN (PB-PK) TO PB-REST
        SUBTRACT PG-WOFF (PB-PK) FROM PB-REST
        IF PB-REST > 0
            MOVE 0 TO PB-SZ
            ADD PB-REST TO PB-SZ
            CALL "memmove" USING BY REFERENCE L-PG-WB BY REFERENCE L-PG-WB (PG-WOFF (PB-PK) + 1:1)
                BY VALUE PB-SZ
        END-IF
        SUBTRACT PG-WOFF (PB-PK) FROM PG-WEND (PB-PK)
        MOVE PB-REST TO PG-WLEN (PB-PK)
        MOVE 0 TO PG-WOFF (PB-PK)
        MOVE PG-WB-SIZE TO PB-FREE
        SUBTRACT PG-WLEN (PB-PK) FROM PB-FREE
    END-IF
    IF PB-FREE < PB-NEED
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-PB TO PG-PB-PTR
    IF PB-RO = 1
        MOVE 0 TO PB-SZ
        ADD PB-W TO PB-SZ
        CALL "malloc" USING BY VALUE PB-SZ RETURNING PB-PTR
        IF PB-PTR = NULL
            EXIT PARAGRAPH
        END-IF
        SET ADDRESS OF L-PG-RS TO PB-PTR
        MOVE L-PB (1:PB-W) TO L-PG-RS (1:PB-W)
    END-IF
    MOVE PG-RT (PB-PK) TO PB-T
    ADD 1 TO PB-T
    IF PB-T > PG-RING
        MOVE 1 TO PB-T
    END-IF
    MOVE PB-T TO PG-RT (PB-PK)
    ADD 1 TO PG-RN (PB-PK)
    MOVE FX TO PG-Q-FX (PB-PK, PB-T)
    MOVE CN-GEN (FX) TO PG-Q-GEN (PB-PK, PB-T)
    MOVE PB-H TO PG-Q-H (PB-PK, PB-T)
    MOVE PB-NST TO PG-Q-NST (PB-PK, PB-T)
    IF PB-RO = 1
        MOVE L-PB (1:PB-W) TO L-PG-WB (PG-WLEN (PB-PK) + 1:PB-W)
        ADD PB-W TO PG-WLEN (PB-PK)
        MOVE 1 TO PG-OPEN (PB-PK)
        MOVE 0 TO PG-Q-SINGLE (PB-PK, PB-T)
        SET PG-Q-RS-PTR (PB-PK, PB-T) TO PB-PTR
        MOVE PB-W TO PG-Q-RS-LEN (PB-PK, PB-T)
        MOVE PG-SEQ-NEXT (PB-PK) TO PG-Q-SEQ (PB-PK, PB-T)
    ELSE
        MOVE PB-PK TO PG-SX
        IF PG-OPEN (PB-PK) = 1
            *> the Sync that ends the open group
            PERFORM PG-SEAL
        END-IF
        MOVE 1 TO PG-Q-SINGLE (PB-PK, PB-T)
        SET PG-Q-RS-PTR (PB-PK, PB-T) TO NULL
        MOVE 0 TO PG-Q-RS-LEN (PB-PK, PB-T)
        MOVE PG-SEQ-NEXT (PB-PK) TO PG-Q-SEQ (PB-PK, PB-T)
        MOVE L-PB (1:PB-W) TO L-PG-WB (PG-WLEN (PB-PK) + 1:PB-W)
        ADD PB-W TO PG-WLEN (PB-PK)
        *> and its own Sync
        PERFORM PG-SEAL
    END-IF
    MOVE 1 TO CN-BUSY (FX)
    MOVE 1 TO PG-SUBMIT-OK.

*> ---------- writing ----------

*> End of a loop iteration, connection PX: unless MAX-SYNCS Syncs are unanswered, seal the open group and write
*> everything queued.
PG-FLUSH.
    IF PG-UP (PX) = 0
        EXIT PARAGRAPH
    END-IF
    IF MAX-SYNCS > 0 AND PG-SSYNCS (PX) >= MAX-SYNCS
        EXIT PARAGRAPH
    END-IF
    IF PG-OPEN (PX) = 1
        MOVE PX TO PG-SX
        PERFORM PG-SEAL
    END-IF
    IF PG-QSYNCS (PX) > 0
        ADD PG-QSYNCS (PX) TO PG-SSYNCS (PX)
        MOVE 0 TO PG-QSYNCS (PX)
        MOVE PG-WLEN (PX) TO PG-WEND (PX)
        MOVE PX TO PG-WX
        PERFORM PG-WRITE
    END-IF.

*> Appends a Sync to connection PG-SX's write buffer, which ends its open group or a write request's own.
PG-SEAL.
    SET ADDRESS OF L-PG-WB TO PG-WB-PTR (PG-SX)
    MOVE PG-SYNC-MSG TO L-PG-WB (PG-WLEN (PG-SX) + 1:5)
    ADD 5 TO PG-WLEN (PG-SX)
    ADD 1 TO PG-QSYNCS (PG-SX)
    ADD 1 TO PG-SEQ-NEXT (PG-SX)
    MOVE 0 TO PG-OPEN (PG-SX).

*> Writes connection PG-WX's buffer up to PG-WEND; what the socket does not take waits for EPOLLOUT.
PG-WRITE.
    SET ADDRESS OF L-PG-WB TO PG-WB-PTR (PG-WX)
    MOVE PG-WEND (PG-WX) TO PG-REST
    SUBTRACT PG-WOFF (PG-WX) FROM PG-REST
    IF PG-REST > 0
        MOVE 0 TO PG-SZ
        ADD PG-REST TO PG-SZ
        CALL "write" USING BY VALUE PG-FD (PG-WX) BY REFERENCE L-PG-WB (PG-WOFF (PG-WX) + 1:1) BY VALUE PG-SZ
            RETURNING PG-N
        IF PG-N < 0
            IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
                MOVE L-ERRNO TO PG-NUM-ED
                MOVE SPACES TO PG-WHY
                MOVE 1 TO PG-WHY-LEN
                STRING "write failed, errno " FUNCTION TRIM (PG-NUM-ED) DELIMITED BY SIZE INTO PG-WHY
                    WITH POINTER PG-WHY-LEN
                SUBTRACT 1 FROM PG-WHY-LEN
                MOVE PG-WX TO PG-LX
                PERFORM PG-LOST
                EXIT PARAGRAPH
            END-IF
            MOVE 0 TO PG-N
        END-IF
        ADD PG-N TO PG-WOFF (PG-WX)
    END-IF
    IF PG-WOFF (PG-WX) = PG-WEND (PG-WX)
        *> keep only what is not yet due: the open group's Binds, or Syncs queued while MAX-SYNCS held back
        MOVE PG-WLEN (PG-WX) TO PG-REST
        SUBTRACT PG-WEND (PG-WX) FROM PG-REST
        IF PG-REST > 0 AND PG-WEND (PG-WX) > 0
            MOVE 0 TO PG-SZ
            ADD PG-REST TO PG-SZ
            CALL "memmove" USING BY REFERENCE L-PG-WB BY REFERENCE L-PG-WB (PG-WEND (PG-WX) + 1:1)
                BY VALUE PG-SZ
        END-IF
        MOVE PG-REST TO PG-WLEN (PG-WX)
        MOVE 0 TO PG-WOFF (PG-WX) PG-WEND (PG-WX)
        IF PG-WANT-OUT (PG-WX) = 1
            MOVE 0 TO PG-WANT-OUT (PG-WX)
            MOVE K-EV-IN TO EV-EVENTS
            MOVE PG-FD (PG-WX) TO EV-FD
            CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE PG-FD (PG-WX) BY REFERENCE EV
        END-IF
    ELSE
        IF PG-WANT-OUT (PG-WX) = 0
            MOVE 1 TO PG-WANT-OUT (PG-WX)
            MOVE K-EV-INOUT TO EV-EVENTS
            MOVE PG-FD (PG-WX) TO EV-FD
            CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE PG-FD (PG-WX) BY REFERENCE EV
        END-IF
    END-IF.

*> ---------- reading ----------

*> An epoll event on connection P.
PG-EVENT.
    IF PG-UP (P) = 0
        EXIT PARAGRAPH
    END-IF
    IF PG-WANT-OUT (P) = 1
        MOVE P TO PG-WX
        PERFORM PG-WRITE
        IF PG-UP (P) = 0
            EXIT PARAGRAPH
        END-IF
    END-IF
    SET ADDRESS OF L-RB TO PG-RB-PTR (P)
    PERFORM FOREVER
        IF PG-RPOS (P) > PG-RLEN (P)
            MOVE 0 TO PG-RLEN (P)
            MOVE 1 TO PG-RPOS (P)
        ELSE
            MOVE PG-RB-SIZE TO PG-FREE
            SUBTRACT PG-RLEN (P) FROM PG-FREE
            IF PG-FREE < PG-RB-LOW AND PG-RPOS (P) > 1
                *> keep the partial message at the end
                MOVE PG-RLEN (P) TO PG-REST
                SUBTRACT PG-RPOS (P) FROM PG-REST
                ADD 1 TO PG-REST
                MOVE 0 TO PG-SZ
                ADD PG-REST TO PG-SZ
                CALL "memmove" USING BY REFERENCE L-RB BY REFERENCE L-RB (PG-RPOS (P):1) BY VALUE PG-SZ
                MOVE PG-REST TO PG-RLEN (P)
                MOVE 1 TO PG-RPOS (P)
            END-IF
        END-IF
        MOVE PG-RB-SIZE TO PG-FREE
        SUBTRACT PG-RLEN (P) FROM PG-FREE
        IF PG-FREE = 0
            MOVE "message too large" TO PG-WHY
            MOVE 17 TO PG-WHY-LEN
            MOVE P TO PG-LX
            PERFORM PG-LOST
            EXIT PERFORM
        END-IF
        MOVE 0 TO PG-SZ
        ADD PG-FREE TO PG-SZ
        CALL "read" USING BY VALUE PG-FD (P) BY REFERENCE L-RB (PG-RLEN (P) + 1:1) BY VALUE PG-SZ
            RETURNING PG-N
        IF PG-N = 0
            MOVE "connection closed" TO PG-WHY
            MOVE 17 TO PG-WHY-LEN
            MOVE P TO PG-LX
            PERFORM PG-LOST
            EXIT PERFORM
        END-IF
        IF PG-N < 0
            IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
                MOVE L-ERRNO TO PG-NUM-ED
                MOVE SPACES TO PG-WHY
                MOVE 1 TO PG-WHY-LEN
                STRING "read failed, errno " FUNCTION TRIM (PG-NUM-ED) DELIMITED BY SIZE INTO PG-WHY
                    WITH POINTER PG-WHY-LEN
                SUBTRACT 1 FROM PG-WHY-LEN
                MOVE P TO PG-LX
                PERFORM PG-LOST
            END-IF
            EXIT PERFORM
        END-IF
        ADD PG-N TO PG-RLEN (P)
        *> PG-PARSE can change PG-FREE (PG-RESEND uses it), so keep this read's room in PG-RFREE
        MOVE PG-FREE TO PG-RFREE
        PERFORM PG-PARSE
        IF PG-UP (P) = 0 OR PG-N < PG-RFREE
            EXIT PERFORM
        END-IF
    END-PERFORM.

*> Handles the whole messages in connection P's read buffer.
PG-PARSE.
    PERFORM FOREVER
        MOVE PG-RLEN (P) TO PG-AV
        SUBTRACT PG-RPOS (P) FROM PG-AV
        IF PG-AV < 4
            EXIT PERFORM
        END-IF
        MOVE PG-RPOS (P) TO PG-QP
        MOVE L-RB (PG-QP + 1:1) TO PG-L-X (4:1)
        MOVE L-RB (PG-QP + 2:1) TO PG-L-X (3:1)
        MOVE L-RB (PG-QP + 3:1) TO PG-L-X (2:1)
        MOVE L-RB (PG-QP + 4:1) TO PG-L-X (1:1)
        MOVE PG-L TO PG-ML
        IF PG-ML < 4
            MOVE "bad message length" TO PG-WHY
            MOVE 18 TO PG-WHY-LEN
            MOVE P TO PG-LX
            PERFORM PG-LOST
            EXIT PERFORM
        END-IF
        *> PG-MEND: the message's last byte
        MOVE PG-QP TO PG-MEND
        ADD PG-ML TO PG-MEND
        IF PG-MEND > PG-RLEN (P)
            EXIT PERFORM
        END-IF
        MOVE L-RB (PG-QP:1) TO PG-MT
        EVALUATE PG-MT
            WHEN "D"
                PERFORM PG-ON-ROW
            WHEN "C"
                PERFORM PG-ON-COMPLETE
            WHEN "Z"
                PERFORM PG-ON-READY
            WHEN "E"
                PERFORM PG-ON-ERROR
            WHEN OTHER
                *> BindComplete, NoData, ParameterStatus, NoticeResponse, ...
                CONTINUE
        END-EVALUATE
        IF PG-UP (P) = 0
            EXIT PERFORM
        END-IF
        MOVE PG-MEND TO PG-RPOS (P)
        ADD 1 TO PG-RPOS (P)
    END-PERFORM.

*> PG-OK = 1 when connection P's head request (PG-HX) is the one the next result belongs to.
PG-CUR-CHECK.
    MOVE 0 TO PG-OK
    IF PG-RN (P) > 0
        MOVE PG-RH (P) TO PG-HX
        IF PG-Q-SEQ (P, PG-HX) = PG-SEQ-HEAD (P)
            MOVE 1 TO PG-OK
        END-IF
    END-IF.

PG-UNEXPECTED.
    MOVE SPACES TO PG-WHY
    MOVE 1 TO PG-WHY-LEN
    STRING "unexpected message '" PG-MT "' with no request waiting" DELIMITED BY SIZE INTO PG-WHY
        WITH POINTER PG-WHY-LEN
    SUBTRACT 1 FROM PG-WHY-LEN
    MOVE P TO PG-LX
    PERFORM PG-LOST.

*> DataRow: the columns into RW-*, then APP-ROW.
PG-ON-ROW.
    PERFORM PG-CUR-CHECK
    IF PG-OK = 0
        PERFORM PG-UNEXPECTED
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO PG-ROWS (P)
    MOVE 0 TO PG-L
    MOVE L-RB (PG-QP + 5:1) TO PG-L-X (2:1)
    MOVE L-RB (PG-QP + 6:1) TO PG-L-X (1:1)
    MOVE PG-L TO RW-NCOL
    IF RW-NCOL > 32
        MOVE 32 TO RW-NCOL
    END-IF
    ADD 7 TO PG-QP
    PERFORM VARYING PG-COL FROM 1 BY 1 UNTIL PG-COL > RW-NCOL
        MOVE L-RB (PG-QP:1) TO PG-L-X (4:1)
        MOVE L-RB (PG-QP + 1:1) TO PG-L-X (3:1)
        MOVE L-RB (PG-QP + 2:1) TO PG-L-X (2:1)
        MOVE L-RB (PG-QP + 3:1) TO PG-L-X (1:1)
        ADD 4 TO PG-QP
        MOVE PG-QP TO RW-OFF (PG-COL)
        MOVE PG-L TO RW-LEN (PG-COL)
        IF PG-L > 0
            ADD PG-L TO PG-QP
        END-IF
    END-PERFORM
    MOVE PG-Q-FX (P, PG-HX) TO FX
    IF CN-KIND (FX) = 2 AND CN-GEN (FX) = PG-Q-GEN (P, PG-HX)
        MOVE PG-Q-H (P, PG-HX) TO RQ-H
        MOVE PG-NDONE (P) TO RQ-STMT
        ADD 1 TO RQ-STMT
        MOVE PG-ROWS (P) TO RQ-ROW
        MOVE FX TO SOCK-FD
        SUBTRACT 1 FROM SOCK-FD
        SET ADDRESS OF L-OUT TO PG-OUT-PTR (P)
        MOVE PG-OUTLEN (P) TO OUT-LEN
        PERFORM APP-ROW
        MOVE OUT-LEN TO PG-OUTLEN (P)
        SET ADDRESS OF L-RB TO PG-RB-PTR (P)
    END-IF.

*> CommandComplete: one statement of the head request done; a group member is answered at its last.
PG-ON-COMPLETE.
    PERFORM PG-CUR-CHECK
    IF PG-OK = 0
        PERFORM PG-UNEXPECTED
        EXIT PARAGRAPH
    END-IF
    IF PG-NDONE (P) < 4
        MOVE PG-NDONE (P) TO PG-K
        ADD 1 TO PG-K
        MOVE PG-ROWS (P) TO PG-NROWS (P, PG-K)
    END-IF
    ADD 1 TO PG-NDONE (P)
    MOVE 0 TO PG-ROWS (P)
    IF PG-Q-SINGLE (P, PG-HX) = 0 AND PG-NDONE (P) >= PG-Q-NST (P, PG-HX)
        MOVE P TO PG-AX
        PERFORM PG-ANSWER
    END-IF.

*> ErrorResponse: a group member fails at once; a Single fails at its ReadyForQuery. With no request waiting it
*> is the server ending the connection (a FATAL error, e.g. on administrator command).
PG-ON-ERROR.
    MOVE PG-QP TO PG-EB
    ADD 5 TO PG-EB
    MOVE PG-MEND TO PG-EE
    PERFORM PG-PARSE-ERR
    PERFORM PG-CUR-CHECK
    IF PG-OK = 0
        MOVE P TO PG-LX
        PERFORM PG-LOST
        EXIT PARAGRAPH
    END-IF
    IF PG-Q-SINGLE (P, PG-HX) = 0
        MOVE 1 TO PG-ERR (P)
        MOVE PG-EC TO PG-SQLSTATE (P)
        MOVE P TO PG-AX
        PERFORM PG-ANSWER
    ELSE
        IF PG-ERR (P) = 0
            MOVE 1 TO PG-ERR (P)
            MOVE PG-EC TO PG-SQLSTATE (P)
        END-IF
    END-IF.

*> ReadyForQuery: a Single is answered; the members of a group still waiting were skipped after an error, and
*> are sent again on their own.
PG-ON-READY.
    IF PG-SSYNCS (P) = 0
        PERFORM PG-UNEXPECTED
        EXIT PARAGRAPH
    END-IF
    SUBTRACT 1 FROM PG-SSYNCS (P)
    PERFORM PG-CUR-CHECK
    MOVE PG-SEQ-HEAD (P) TO PG-SEQ-T
    ADD 1 TO PG-SEQ-HEAD (P)
    IF PG-OK = 1
        IF PG-Q-SINGLE (P, PG-HX) = 1
            MOVE P TO PG-AX
            PERFORM PG-ANSWER
        ELSE
            PERFORM PG-RESEND
        END-IF
    END-IF.

*> Connection P's head requests with Sync PG-SEQ-T go to the end of the queue, each with its own Sync.
PG-RESEND.
    IF PG-OPEN (P) = 1
        MOVE P TO PG-SX
        PERFORM PG-SEAL
    END-IF
    SET ADDRESS OF L-PG-WB TO PG-WB-PTR (P)
    MOVE 0 TO PG-NDONE (P) PG-ROWS (P) PG-ERR (P) PG-OUTLEN (P)
              PG-NROWS (P, 1) PG-NROWS (P, 2) PG-NROWS (P, 3) PG-NROWS (P, 4)
    PERFORM UNTIL PG-RN (P) = 0
        MOVE PG-RH (P) TO PG-HX
        IF PG-Q-SEQ (P, PG-HX) NOT = PG-SEQ-T
            EXIT PERFORM
        END-IF
        MOVE PG-Q-RS-LEN (P, PG-HX) TO PG-K
        MOVE PG-WB-SIZE TO PG-FREE
        SUBTRACT PG-WLEN (P) FROM PG-FREE
        SUBTRACT 10 FROM PG-FREE
        IF PG-FREE < PG-K AND PG-WOFF (P) > 0
            MOVE PG-WLEN (P) TO PG-REST
            SUBTRACT PG-WOFF (P) FROM PG-REST
            IF PG-REST > 0
                MOVE 0 TO PG-SZ
                ADD PG-REST TO PG-SZ
                CALL "memmove" USING BY REFERENCE L-PG-WB BY REFERENCE L-PG-WB (PG-WOFF (P) + 1:1)
                    BY VALUE PG-SZ
            END-IF
            SUBTRACT PG-WOFF (P) FROM PG-WEND (P)
            MOVE PG-REST TO PG-WLEN (P)
            MOVE 0 TO PG-WOFF (P)
            MOVE PG-WB-SIZE TO PG-FREE
            SUBTRACT PG-WLEN (P) FROM PG-FREE
            SUBTRACT 10 FROM PG-FREE
        END-IF
        IF PG-FREE < PG-K
            *> no room to send it again (not expected: it was in this buffer once)
            MOVE 1 TO PG-ERR (P)
            MOVE "08006" TO PG-SQLSTATE (P)
            MOVE P TO PG-AX
            PERFORM PG-ANSWER
            SET ADDRESS OF L-PG-WB TO PG-WB-PTR (P)
        ELSE
            MOVE PG-RT (P) TO PG-TAIL
            ADD 1 TO PG-TAIL
            IF PG-TAIL > PG-RING
                MOVE 1 TO PG-TAIL
            END-IF
            MOVE PG-Q-FX (P, PG-HX) TO PG-Q-FX (P, PG-TAIL)
            MOVE PG-Q-GEN (P, PG-HX) TO PG-Q-GEN (P, PG-TAIL)
            MOVE PG-Q-H (P, PG-HX) TO PG-Q-H (P, PG-TAIL)
            MOVE PG-Q-NST (P, PG-HX) TO PG-Q-NST (P, PG-TAIL)
            MOVE 1 TO PG-Q-SINGLE (P, PG-TAIL)
            MOVE PG-SEQ-NEXT (P) TO PG-Q-SEQ (P, PG-TAIL)
            SET PG-Q-RS-PTR (P, PG-TAIL) TO NULL
            MOVE 0 TO PG-Q-RS-LEN (P, PG-TAIL)
            SET ADDRESS OF L-PG-RS TO PG-Q-RS-PTR (P, PG-HX)
            MOVE L-PG-RS (1:PG-K) TO L-PG-WB (PG-WLEN (P) + 1:PG-K)
            ADD PG-K TO PG-WLEN (P)
            MOVE PG-SYNC-MSG TO L-PG-WB (PG-WLEN (P) + 1:5)
            ADD 5 TO PG-WLEN (P)
            ADD 1 TO PG-QSYNCS (P)
            ADD 1 TO PG-SEQ-NEXT (P)
            CALL "free" USING BY VALUE PG-Q-RS-PTR (P, PG-HX)
            SET PG-Q-RS-PTR (P, PG-HX) TO NULL
            MOVE PG-TAIL TO PG-RT (P)
            ADD 1 TO PG-RH (P)
            IF PG-RH (P) > PG-RING
                MOVE 1 TO PG-RH (P)
            END-IF
        END-IF
    END-PERFORM.

*> Answers connection PG-AX's head request with PG-ERR / PG-SQLSTATE / PG-NROWS: takes it off the queue, resets
*> the head state and the render output, and calls APP-DONE if its client is still the same connection.
PG-ANSWER.
    MOVE PG-RH (PG-AX) TO PG-HX
    MOVE PG-Q-FX (PG-AX, PG-HX) TO PG-FX
    MOVE PG-Q-GEN (PG-AX, PG-HX) TO PG-GEN
    MOVE PG-Q-H (PG-AX, PG-HX) TO RQ-H
    MOVE PG-ERR (PG-AX) TO RQ-ERR
    MOVE PG-SQLSTATE (PG-AX) TO RQ-SQLSTATE
    MOVE PG-NROWS (PG-AX, 1) TO RQ-NROWS (1)
    MOVE PG-NROWS (PG-AX, 2) TO RQ-NROWS (2)
    MOVE PG-NROWS (PG-AX, 3) TO RQ-NROWS (3)
    MOVE PG-NROWS (PG-AX, 4) TO RQ-NROWS (4)
    MOVE PG-OUTLEN (PG-AX) TO OUT-LEN
    IF PG-Q-RS-PTR (PG-AX, PG-HX) NOT = NULL
        CALL "free" USING BY VALUE PG-Q-RS-PTR (PG-AX, PG-HX)
        SET PG-Q-RS-PTR (PG-AX, PG-HX) TO NULL
    END-IF
    ADD 1 TO PG-RH (PG-AX)
    IF PG-RH (PG-AX) > PG-RING
        MOVE 1 TO PG-RH (PG-AX)
    END-IF
    SUBTRACT 1 FROM PG-RN (PG-AX)
    MOVE 0 TO PG-NDONE (PG-AX) PG-ROWS (PG-AX) PG-ERR (PG-AX) PG-OUTLEN (PG-AX)
              PG-NROWS (PG-AX, 1) PG-NROWS (PG-AX, 2) PG-NROWS (PG-AX, 3) PG-NROWS (PG-AX, 4)
    MOVE SPACES TO PG-SQLSTATE (PG-AX)
    MOVE PG-FX TO FX
    IF CN-KIND (FX) = 2 AND CN-GEN (FX) = PG-GEN
        MOVE FX TO SOCK-FD
        SUBTRACT 1 FROM SOCK-FD
        SET ADDRESS OF L-RB TO PG-RB-PTR (PG-AX)
        SET ADDRESS OF L-OUT TO PG-OUT-PTR (PG-AX)
        PERFORM APP-DONE
        SET ADDRESS OF L-RB TO PG-RB-PTR (PG-AX)
    END-IF.

*> The fields of the ErrorResponse at L-RB (PG-EB) to (PG-EE): PG-EC the SQLSTATE, PG-WHY the message.
PG-PARSE-ERR.
    MOVE "XX000" TO PG-EC
    MOVE "error" TO PG-WHY
    MOVE 5 TO PG-WHY-LEN
    PERFORM UNTIL PG-EB > PG-EE
        MOVE L-RB (PG-EB:1) TO PG-EF
        IF PG-EF = X"00"
            EXIT PERFORM
        END-IF
        ADD 1 TO PG-EB
        MOVE PG-EB TO PG-EV
        MOVE PG-EB TO PG-EVE
        PERFORM UNTIL PG-EVE > PG-EE
            IF L-RB (PG-EVE:1) = X"00"
                EXIT PERFORM
            END-IF
            ADD 1 TO PG-EVE
        END-PERFORM
        MOVE PG-EVE TO PG-EVL
        SUBTRACT PG-EV FROM PG-EVL
        IF PG-EF = "C" AND PG-EVL >= 5
            MOVE L-RB (PG-EV:5) TO PG-EC
        END-IF
        IF PG-EF = "M" AND PG-EVL > 0
            IF PG-EVL > 200
                MOVE 200 TO PG-EVL
            END-IF
            MOVE L-RB (PG-EV:PG-EVL) TO PG-WHY
            MOVE PG-EVL TO PG-WHY-LEN
        END-IF
        MOVE PG-EVE TO PG-EB
        ADD 1 TO PG-EB
    END-PERFORM.

*> Connection PG-LX is lost (PG-WHY says why): close it, fail every request it holds with 08006, and retry
*> in 50 ms.
PG-LOST.
    DISPLAY "postgres: " PG-WHY (1:PG-WHY-LEN) "; reconnecting" UPON SYSERR
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-DEL BY VALUE PG-FD (PG-LX) BY REFERENCE EV
    CALL "close" USING BY VALUE PG-FD (PG-LX)
    MOVE 0 TO CN-KIND (PG-FD (PG-LX) + 1)
    MOVE 0 TO PG-UP (PG-LX)
    ADD 1 TO PG-DOWN
    MOVE 0 TO PG-WLEN (PG-LX) PG-WOFF (PG-LX) PG-WEND (PG-LX) PG-QSYNCS (PG-LX) PG-SSYNCS (PG-LX)
              PG-OPEN (PG-LX) PG-WANT-OUT (PG-LX) PG-RLEN (PG-LX)
    MOVE 1 TO PG-RPOS (PG-LX)
    MOVE 50 TO PG-BACKOFF (PG-LX)
    PERFORM GET-NOW-MS
    COMPUTE PG-RETRY-AT (PG-LX) = NOW-MS + 50
    MOVE PG-LX TO PG-AX
    PERFORM UNTIL PG-RN (PG-AX) = 0
        MOVE 1 TO PG-ERR (PG-AX)
        MOVE "08006" TO PG-SQLSTATE (PG-AX)
        PERFORM PG-ANSWER
    END-PERFORM
    MOVE 0 TO PG-SEQ-HEAD (PG-AX) PG-SEQ-NEXT (PG-AX) PG-RT (PG-AX)
    MOVE 1 TO PG-RH (PG-AX).
