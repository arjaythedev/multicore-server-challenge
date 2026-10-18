*> ================= bcrypt =================
*>
*> A worker sends each hash to the bcrypt process as one frame on its socketpair and gets the answer back on the
*> same socket. The bcrypt process collects frames from every worker into one queue and hands batches of up to
*> four to BC-THREADS hasher processes, which run them in lockstep (_crypt_blowfish_lanes). libcob is not
*> thread-safe, so the hashers are processes rather than threads.

*> ---------- worker side ----------

BC-WORKER-INIT.
    CALL "fcntl" USING BY VALUE BC-FD BY VALUE K-F-SETFL BY VALUE K-O-NONBLOCK
    MOVE 4 TO CN-KIND (BC-FD + 1)
    MOVE 0 TO BC-OLEN BC-OOFF BC-RLEN
    MOVE K-EV-IN TO EV-EVENTS
    MOVE BC-FD TO EV-FD
    MOVE 0 TO EV-PAD
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE BC-FD BY REFERENCE EV.

*> bcrypt reads at most 72 bytes of a password and stops at a NUL, so other passwords are refused.
BC-USABLE.
    MOVE 0 TO BC-USABLE-OK
    IF BC-PW-LEN > 72
        EXIT PARAGRAPH
    END-IF
    MOVE BC-PW-OFF TO BC-N
    ADD BC-PW-LEN TO BC-N
    PERFORM VARYING BC-I FROM BC-PW-OFF BY 1 UNTIL BC-I >= BC-N
        IF L-SRC (BC-I:1) = X"00"
            EXIT PARAGRAPH
        END-IF
    END-PERFORM
    MOVE 1 TO BC-USABLE-OK.

*> One frame for client FX: a new cost-10 salt (mode 1) or the stored hash (mode 2), NUL, the password. A stored
*> hash that cannot be a setting (empty, over 127 bytes, or holding a NUL) is sent as "*0", so the hash fails
*> and the reply says so. The caller has checked the password with BC-USABLE.
BC-SUBMIT.
    MOVE 0 TO BC-SUBMIT-OK
    IF BC-MODE = 1
        CALL "getrandom" USING BY REFERENCE BC-RND BY VALUE K-16-D BY VALUE K-0 RETURNING BC-RC
        IF BC-RC NOT = 16
            EXIT PARAGRAPH
        END-IF
        CALL "_crypt_gensalt_blowfish_rn" USING BY REFERENCE BC-PREFIX BY VALUE K-COST-D
            BY REFERENCE BC-RND BY VALUE BC-K16 BY REFERENCE BC-SALT BY VALUE K-30 RETURNING BC-PTR
        IF BC-PTR = NULL
            EXIT PARAGRAPH
        END-IF
        MOVE 29 TO BC-SET-LEN
        MOVE BC-SALT (1:29) TO BC-F-DATA (1:29)
    ELSE
        MOVE BC-SETTING-LEN TO BC-SET-LEN
        IF BC-SET-LEN < 1 OR BC-SET-LEN > 127
            MOVE 0 TO BC-SET-LEN
        ELSE
            PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > BC-SET-LEN
                IF BC-SETTING (BC-I:1) = X"00"
                    MOVE 0 TO BC-SET-LEN
                    EXIT PERFORM
                END-IF
            END-PERFORM
        END-IF
        IF BC-SET-LEN = 0
            MOVE "*0" TO BC-F-DATA (1:2)
            MOVE 2 TO BC-SET-LEN
        ELSE
            MOVE BC-SETTING (1:BC-SET-LEN) TO BC-F-DATA (1:BC-SET-LEN)
        END-IF
    END-IF
    MOVE X"00" TO BC-F-DATA (BC-SET-LEN + 1:1)
    IF BC-PW-LEN > 0
        MOVE L-SRC (BC-PW-OFF:BC-PW-LEN) TO BC-F-DATA (BC-SET-LEN + 2:BC-PW-LEN)
    END-IF
    MOVE 9 TO BC-F-LEN
    ADD BC-SET-LEN TO BC-F-LEN
    ADD BC-PW-LEN TO BC-F-LEN
    MOVE SOCK-FD TO BC-F-FD
    MOVE CN-GEN (FX) TO BC-F-GEN
    MOVE BC-F-LEN TO BC-FRAME-LEN
    ADD 4 TO BC-FRAME-LEN
    PERFORM BC-SEND
    IF BC-SUBMIT-OK = 1
        MOVE 1 TO CN-BUSY (FX)
    END-IF.

*> Writes BC-FRAME (1:BC-FRAME-LEN). What the socket does not take goes to BC-OBUF and out on EPOLLOUT; frames
*> stay in order, so while BC-OBUF holds anything a new frame only joins it. BC-SUBMIT-OK = 0 if it is full.
BC-SEND.
    MOVE 0 TO BC-N
    IF BC-OLEN = 0
        MOVE 0 TO BC-SZ
        ADD BC-FRAME-LEN TO BC-SZ
        CALL "write" USING BY VALUE BC-FD BY REFERENCE BC-FRAME BY VALUE BC-SZ RETURNING BC-N
        IF BC-N = BC-FRAME-LEN
            MOVE 1 TO BC-SUBMIT-OK
            EXIT PARAGRAPH
        END-IF
        IF BC-N < 0
            IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
                PERFORM BC-GONE
            END-IF
            MOVE 0 TO BC-N
        END-IF
    END-IF
    MOVE BC-FRAME-LEN TO BC-REST
    SUBTRACT BC-N FROM BC-REST
    MOVE 262144 TO BC-OSPACE
    SUBTRACT BC-OLEN FROM BC-OSPACE
    IF BC-OSPACE < BC-REST AND BC-OOFF > 0
        SUBTRACT BC-OOFF FROM BC-OLEN
        MOVE 0 TO BC-SZ
        ADD BC-OLEN TO BC-SZ
        SET BC-PTR TO ADDRESS OF BC-OBUF
        CALL "memmove" USING BY VALUE BC-PTR BY REFERENCE BC-OBUF (BC-OOFF + 1:1) BY VALUE BC-SZ
        MOVE 0 TO BC-OOFF
        MOVE 262144 TO BC-OSPACE
        SUBTRACT BC-OLEN FROM BC-OSPACE
    END-IF
    IF BC-OSPACE < BC-REST
        *> BC-N is 0 here: the buffer was not empty, so nothing of this frame went out
        EXIT PARAGRAPH
    END-IF
    MOVE BC-FRAME-X (BC-N + 1:BC-REST) TO BC-OBUF (BC-OLEN + 1:BC-REST)
    IF BC-OLEN = 0
        MOVE K-EV-INOUT TO EV-EVENTS
        MOVE BC-FD TO EV-FD
        MOVE 0 TO EV-PAD
        CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE BC-FD BY REFERENCE EV
    END-IF
    ADD BC-REST TO BC-OLEN
    MOVE 1 TO BC-SUBMIT-OK.

BC-DRAIN.
    MOVE 0 TO BC-SZ
    ADD BC-OLEN TO BC-SZ
    SUBTRACT BC-OOFF FROM BC-SZ
    CALL "write" USING BY VALUE BC-FD BY REFERENCE BC-OBUF (BC-OOFF + 1:1) BY VALUE BC-SZ RETURNING BC-N
    IF BC-N < 0
        IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
            PERFORM BC-GONE
        END-IF
        EXIT PARAGRAPH
    END-IF
    ADD BC-N TO BC-OOFF
    IF BC-OOFF = BC-OLEN
        MOVE 0 TO BC-OLEN BC-OOFF
        MOVE K-EV-IN TO EV-EVENTS
        MOVE BC-FD TO EV-FD
        MOVE 0 TO EV-PAD
        CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE BC-FD BY REFERENCE EV
    END-IF.

BC-GONE.
    DISPLAY "bcrypt process gone; stopping worker" UPON SYSERR
    MOVE 1 TO RETURN-CODE
    STOP RUN.

*> Writes what is queued, then reads replies. Each whole reply frame for a client that is still the same
*> connection goes to APP-BC-DONE; a partial frame waits in BC-RBUF.
BC-WORKER-EVENT.
    IF BC-OLEN > 0
        PERFORM BC-DRAIN
    END-IF
    MOVE 0 TO BC-SZ
    ADD 65536 TO BC-SZ
    SUBTRACT BC-RLEN FROM BC-SZ
    CALL "read" USING BY VALUE BC-FD BY REFERENCE BC-RBUF (BC-RLEN + 1:1) BY VALUE BC-SZ RETURNING BC-N
    IF BC-N = 0
        PERFORM BC-GONE
    END-IF
    IF BC-N < 0
        IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
            PERFORM BC-GONE
        END-IF
        EXIT PARAGRAPH
    END-IF
    ADD BC-N TO BC-RLEN
    MOVE 1 TO BC-RPOS
    PERFORM FOREVER
        MOVE BC-RLEN TO BC-AVAIL
        SUBTRACT BC-RPOS FROM BC-AVAIL
        ADD 1 TO BC-AVAIL
        IF BC-AVAIL < 12
            EXIT PERFORM
        END-IF
        MOVE BC-RBUF (BC-RPOS:12) TO BC-HDR
        IF BC-H-LEN < 8 OR BC-H-LEN > 72
            PERFORM BC-GONE
        END-IF
        MOVE BC-H-LEN TO BC-TOTAL
        ADD 4 TO BC-TOTAL
        IF BC-AVAIL < BC-TOTAL
            EXIT PERFORM
        END-IF
        MOVE BC-H-LEN TO BC-RESULT-LEN
        SUBTRACT 8 FROM BC-RESULT-LEN
        IF BC-RESULT-LEN > 0
            MOVE BC-RBUF (BC-RPOS + 12:BC-RESULT-LEN) TO BC-RESULT (1:BC-RESULT-LEN)
        END-IF
        ADD BC-TOTAL TO BC-RPOS
        IF BC-H-FD >= 0 AND BC-H-FD < MAX-FD
            MOVE BC-H-FD TO BC-FX
            ADD 1 TO BC-FX
            IF CN-KIND (BC-FX) = 2 AND CN-GEN (BC-FX) = BC-H-GEN
                MOVE BC-FX TO FX
                MOVE BC-H-FD TO SOCK-FD
                MOVE 0 TO CLOSED
                PERFORM APP-BC-DONE
            END-IF
        END-IF
    END-PERFORM
    IF BC-RPOS > BC-RLEN
        MOVE 0 TO BC-RLEN
    ELSE
        MOVE BC-RLEN TO BC-AVAIL
        SUBTRACT BC-RPOS FROM BC-AVAIL
        ADD 1 TO BC-AVAIL
        MOVE 0 TO BC-SZ
        ADD BC-AVAIL TO BC-SZ
        SET BC-PTR TO ADDRESS OF BC-RBUF
        CALL "memmove" USING BY VALUE BC-PTR BY REFERENCE BC-RBUF (BC-RPOS:1) BY VALUE BC-SZ
        MOVE BC-AVAIL TO BC-RLEN
    END-IF.

*> ---------- the bcrypt process ----------

*> The collector: an epoll loop over the worker sockets (tag w in the event's high word) and the hasher sockets
*> (tag 1000 + h). One batch is collected at a time: once a hasher is idle, it sends at once if four jobs are
*> queued, and otherwise waits until BC-WAIT-MS after the oldest job arrived. Never returns.
BC-MAIN.
    CALL "prctl" USING BY VALUE K-PDEATHSIG-D BY VALUE K-SIGTERM-D
    CALL "__errno_location" RETURNING ERRNO-PTR
    SET ADDRESS OF L-ERRNO TO ERRNO-PTR
    MOVE LENGTH OF L-BC-Q TO BC-SZ
    CALL "malloc" USING BY VALUE BC-SZ RETURNING BC-PTR
    SET ADDRESS OF L-BC-Q TO BC-PTR
    MOVE LENGTH OF L-BC-WB TO BC-SZ
    CALL "malloc" USING BY VALUE BC-SZ RETURNING BC-PTR
    SET ADDRESS OF L-BC-WB TO BC-PTR
    MOVE 0 TO BC-NJ BC-DEADLINE-SET
    MOVE 1 TO BC-QH BC-QT
    CALL "epoll_create1" USING BY VALUE K-0 RETURNING EPFD
    PERFORM VARYING BC-W FROM 1 BY 1 UNTIL BC-W > N-WORKERS
        MOVE 0 TO BC-WB-LEN (BC-W)
        MOVE 1 TO BC-W-OPEN (BC-W)
        MOVE K-EV-IN TO EV-EVENTS
        MOVE BC-PAIR-FD (BC-W, 2) TO EV-FD
        MOVE BC-W TO EV-PAD
        CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE BC-PAIR-FD (BC-W, 2) BY REFERENCE EV
    END-PERFORM
    PERFORM VARYING BC-HX FROM 1 BY 1 UNTIL BC-HX > BC-THREADS
        CALL "socketpair" USING BY VALUE K-AF-UNIX BY VALUE K-SOCK-STREAM BY VALUE K-0
            BY REFERENCE PAIR-FDS RETURNING BC-RC
        IF BC-RC NOT = 0
            DISPLAY "bcrypt: socketpair failed" UPON SYSERR
            MOVE 1 TO RETURN-CODE
            STOP RUN
        END-IF
        CALL "fork" RETURNING PID
        IF PID = 0
            PERFORM VARYING BC-W FROM 1 BY 1 UNTIL BC-W > N-WORKERS
                CALL "close" USING BY VALUE BC-PAIR-FD (BC-W, 2)
            END-PERFORM
            PERFORM VARYING BC-HI FROM 1 BY 1 UNTIL BC-HI >= BC-HX
                CALL "close" USING BY VALUE BC-HS-FD (BC-HI)
            END-PERFORM
            CALL "close" USING BY VALUE PAIR-FD (1)
            CALL "close" USING BY VALUE EPFD
            MOVE PAIR-FD (2) TO BC-HFD
            PERFORM BC-HASHER
        END-IF
        IF PID < 0
            DISPLAY "bcrypt: fork failed" UPON SYSERR
            MOVE 1 TO RETURN-CODE
            STOP RUN
        END-IF
        CALL "close" USING BY VALUE PAIR-FD (2)
        MOVE PAIR-FD (1) TO BC-HS-FD (BC-HX)
        MOVE 0 TO BC-HS-BUSY (BC-HX)
        MOVE K-EV-IN TO EV-EVENTS
        MOVE PAIR-FD (1) TO EV-FD
        COMPUTE EV-PAD = 1000 + BC-HX
        CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE PAIR-FD (1) BY REFERENCE EV
    END-PERFORM
    PERFORM FOREVER
        MOVE -1 TO EP-TIMEOUT
        IF BC-DEADLINE-SET = 1
            PERFORM GET-NOW-MS
            IF NOW-MS >= BC-DEADLINE
                MOVE 0 TO EP-TIMEOUT
            ELSE
                COMPUTE EP-TIMEOUT = BC-DEADLINE - NOW-MS
            END-IF
        END-IF
        CALL "epoll_wait" USING BY VALUE EPFD BY REFERENCE EVENTS BY VALUE K-EV-MAX BY VALUE EP-TIMEOUT
            RETURNING NEV
        PERFORM VARYING EI FROM 1 BY 1 UNTIL EI > NEV
            MOVE EVS-PAD (EI) TO BC-TAG
            IF BC-TAG > 1000
                COMPUTE BC-HX = BC-TAG - 1000
                PERFORM BC-HASHER-DONE
            ELSE
                MOVE BC-TAG TO BC-W
                PERFORM BC-COLLECT-INPUT
            END-IF
        END-PERFORM
        PERFORM BC-DISPATCH
    END-PERFORM.

*> Reads from worker BC-W and queues each whole frame. A worker that has gone is forgotten.
BC-COLLECT-INPUT.
    MOVE BC-WBCAP TO BC-N
    SUBTRACT BC-WB-LEN (BC-W) FROM BC-N
    MOVE BC-N TO BC-SZ
    CALL "read" USING BY VALUE BC-PAIR-FD (BC-W, 2) BY REFERENCE BC-WB-DATA (BC-W) (BC-WB-LEN (BC-W) + 1:1)
        BY VALUE BC-SZ RETURNING BC-N
    IF BC-N <= 0
        IF BC-N = 0 OR (L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR)
            PERFORM BC-DROP-WORKER
        END-IF
        EXIT PARAGRAPH
    END-IF
    ADD BC-N TO BC-WB-LEN (BC-W)
    MOVE 1 TO BC-RPOS
    PERFORM FOREVER
        COMPUTE BC-AVAIL = BC-WB-LEN (BC-W) - BC-RPOS + 1
        IF BC-AVAIL < 12
            EXIT PERFORM
        END-IF
        MOVE BC-WB-DATA (BC-W) (BC-RPOS:12) TO BC-HDR
        IF BC-H-LEN < 8 OR BC-H-LEN > 4000
            DISPLAY "bcrypt: bad frame from a worker" UPON SYSERR
            PERFORM BC-DROP-WORKER
            EXIT PARAGRAPH
        END-IF
        COMPUTE BC-TOTAL = BC-H-LEN + 4
        IF BC-AVAIL < BC-TOTAL
            EXIT PERFORM
        END-IF
        COMPUTE BC-PL = BC-H-LEN - 8
        COMPUTE BC-OFF = BC-RPOS + 12
        MOVE 0 TO BC-NUL-AT
        PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > BC-PL
            IF BC-WB-DATA (BC-W) (BC-OFF + BC-I - 1:1) = X"00"
                MOVE BC-I TO BC-NUL-AT
                EXIT PERFORM
            END-IF
        END-PERFORM
        PERFORM BC-ENQUEUE
        ADD BC-TOTAL TO BC-RPOS
    END-PERFORM
    IF BC-RPOS > BC-WB-LEN (BC-W)
        MOVE 0 TO BC-WB-LEN (BC-W)
    ELSE
        COMPUTE BC-AVAIL = BC-WB-LEN (BC-W) - BC-RPOS + 1
        MOVE BC-AVAIL TO BC-SZ
        SET BC-PTR TO ADDRESS OF BC-WB-DATA (BC-W)
        CALL "memmove" USING BY VALUE BC-PTR BY REFERENCE BC-WB-DATA (BC-W) (BC-RPOS:1)
            BY VALUE BC-SZ
        MOVE BC-AVAIL TO BC-WB-LEN (BC-W)
    END-IF.

BC-DROP-WORKER.
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-DEL BY VALUE BC-PAIR-FD (BC-W, 2) BY REFERENCE EV
    CALL "close" USING BY VALUE BC-PAIR-FD (BC-W, 2)
    MOVE 0 TO BC-W-OPEN (BC-W) BC-WB-LEN (BC-W).

*> Queues the frame in BC-HDR whose payload (BC-PL bytes) is at BC-WB-DATA (BC-W) (BC-OFF:), with its first NUL at
*> payload position BC-NUL-AT (0: none). Setting and key are stored NUL-terminated; a bad setting becomes "*0".
BC-ENQUEUE.
    IF BC-NJ >= BC-QCAP
        *> no room: fail it at once
        MOVE 8 TO BC-F-LEN
        MOVE BC-H-FD TO BC-F-FD
        MOVE BC-H-GEN TO BC-F-GEN
        MOVE BC-PAIR-FD (BC-W, 2) TO BC-IO-FD
        SET BC-IO-PTR TO ADDRESS OF BC-FRAME
        MOVE 12 TO BC-IO-LEN
        PERFORM BC-WRITE-FULL
        EXIT PARAGRAPH
    END-IF
    MOVE BC-W TO BC-J-W (BC-QT)
    MOVE BC-H-FD TO BC-J-FD (BC-QT)
    MOVE BC-H-GEN TO BC-J-GEN (BC-QT)
    PERFORM GET-NOW-MS
    MOVE NOW-MS TO BC-J-AT (BC-QT)
    IF BC-NUL-AT = 0
        MOVE 0 TO BC-SET-LEN BC-KEY-LEN
    ELSE
        COMPUTE BC-SET-LEN = BC-NUL-AT - 1
        COMPUTE BC-KEY-LEN = BC-PL - BC-NUL-AT
    END-IF
    IF BC-SET-LEN < 1 OR BC-SET-LEN > 127
        MOVE "*0" & X"00" TO BC-J-SET (BC-QT) (1:3)
    ELSE
        MOVE BC-WB-DATA (BC-W) (BC-OFF:BC-SET-LEN) TO BC-J-SET (BC-QT) (1:BC-SET-LEN)
        MOVE X"00" TO BC-J-SET (BC-QT) (BC-SET-LEN + 1:1)
    END-IF
    IF BC-KEY-LEN > 72
        MOVE 72 TO BC-KEY-LEN
    END-IF
    IF BC-KEY-LEN > 0
        MOVE BC-WB-DATA (BC-W) (BC-OFF + BC-NUL-AT:BC-KEY-LEN) TO BC-J-KEY (BC-QT) (1:BC-KEY-LEN)
    END-IF
    MOVE X"00" TO BC-J-KEY (BC-QT) (BC-KEY-LEN + 1:1)
    ADD 1 TO BC-NJ
    ADD 1 TO BC-QT
    IF BC-QT > BC-QCAP
        MOVE 1 TO BC-QT
    END-IF.

*> Hands batches to idle hashers while the batching rule allows.
BC-DISPATCH.
    PERFORM FOREVER
        IF BC-NJ = 0
            MOVE 0 TO BC-DEADLINE-SET
            EXIT PERFORM
        END-IF
        MOVE 0 TO BC-HI
        PERFORM VARYING BC-HX FROM 1 BY 1 UNTIL BC-HX > BC-THREADS OR BC-HI > 0
            IF BC-HS-BUSY (BC-HX) = 0
                MOVE BC-HX TO BC-HI
            END-IF
        END-PERFORM
        IF BC-HI = 0
            *> a hasher finishing wakes the loop, so no timer is needed
            MOVE 0 TO BC-DEADLINE-SET
            EXIT PERFORM
        END-IF
        IF BC-NJ < 4 AND BC-WAIT-MS > 0
            *> the head job is the oldest, so time from its arrival: a job that queued behind busy hashers has
            *> already waited and goes as soon as a hasher is idle
            COMPUTE BC-DEADLINE = BC-J-AT (BC-QH) + BC-WAIT-MS
            MOVE 1 TO BC-DEADLINE-SET
            PERFORM GET-NOW-MS
            IF NOW-MS < BC-DEADLINE
                EXIT PERFORM
            END-IF
        END-IF
        PERFORM BC-SEND-BATCH
        MOVE 0 TO BC-DEADLINE-SET
    END-PERFORM.

*> Up to four jobs from the head of the queue to hasher BC-HI.
BC-SEND-BATCH.
    MOVE BC-NJ TO BC-N
    IF BC-N > 4
        MOVE 4 TO BC-N
    END-IF
    MOVE BC-N TO BC-B-N BC-HS-N (BC-HI)
    PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > BC-N
        MOVE BC-J-SET (BC-QH) TO BC-B-SET (BC-I)
        MOVE BC-J-KEY (BC-QH) TO BC-B-KEY (BC-I)
        MOVE BC-J-W (BC-QH) TO BC-HS-JW (BC-HI, BC-I)
        MOVE BC-J-FD (BC-QH) TO BC-HS-JFD (BC-HI, BC-I)
        MOVE BC-J-GEN (BC-QH) TO BC-HS-JGEN (BC-HI, BC-I)
        SUBTRACT 1 FROM BC-NJ
        ADD 1 TO BC-QH
        IF BC-QH > BC-QCAP
            MOVE 1 TO BC-QH
        END-IF
    END-PERFORM
    MOVE BC-HS-FD (BC-HI) TO BC-IO-FD
    SET BC-IO-PTR TO ADDRESS OF BC-BATCH
    MOVE LENGTH OF BC-BATCH TO BC-IO-LEN
    PERFORM BC-WRITE-FULL
    IF BC-IO-OK = 0
        PERFORM BC-HASHER-GONE
    END-IF
    MOVE 1 TO BC-HS-BUSY (BC-HI).

*> Hasher BC-HX has answered: send each hash to its worker. A result starting with '*' is a failure (empty
*> payload).
BC-HASHER-DONE.
    MOVE BC-HS-FD (BC-HX) TO BC-IO-FD
    SET BC-IO-PTR TO ADDRESS OF BC-BREPLY
    MOVE LENGTH OF BC-BREPLY TO BC-IO-LEN
    PERFORM BC-READ-FULL
    IF BC-IO-OK = 0
        PERFORM BC-HASHER-GONE
    END-IF
    PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > BC-HS-N (BC-HX)
        MOVE BC-HS-JW (BC-HX, BC-I) TO BC-W
        IF BC-W-OPEN (BC-W) = 1
            MOVE 0 TO BC-N
            IF BC-B-OUT (BC-I) (1:1) NOT = "*"
                PERFORM UNTIL BC-N >= 64 OR BC-B-OUT (BC-I) (BC-N + 1:1) = X"00"
                    ADD 1 TO BC-N
                END-PERFORM
            END-IF
            MOVE 8 TO BC-F-LEN
            ADD BC-N TO BC-F-LEN
            MOVE BC-HS-JFD (BC-HX, BC-I) TO BC-F-FD
            MOVE BC-HS-JGEN (BC-HX, BC-I) TO BC-F-GEN
            IF BC-N > 0
                MOVE BC-B-OUT (BC-I) (1:BC-N) TO BC-F-DATA (1:BC-N)
            END-IF
            MOVE BC-F-LEN TO BC-IO-LEN
            ADD 4 TO BC-IO-LEN
            MOVE BC-PAIR-FD (BC-W, 2) TO BC-IO-FD
            SET BC-IO-PTR TO ADDRESS OF BC-FRAME
            PERFORM BC-WRITE-FULL
        END-IF
    END-PERFORM
    MOVE 0 TO BC-HS-BUSY (BC-HX).

BC-HASHER-GONE.
    DISPLAY "bcrypt: a hasher process is gone" UPON SYSERR
    MOVE 1 TO RETURN-CODE
    STOP RUN.

*> A hasher process: reads a batch, hashes it, writes the hashes, until the collector goes away. Runs at nice
*> BC-NICE, so at saturation hashes wait for a core rather than take one from Postgres or a worker.
BC-HASHER.
    CALL "prctl" USING BY VALUE K-PDEATHSIG-D BY VALUE K-SIGTERM-D
    IF BC-NICE > 0
        CALL "setpriority" USING BY VALUE K-0 BY VALUE K-0 BY VALUE BC-NICE
    END-IF
    CALL "_crypt_blowfish_lanes_selftest" RETURNING BC-RC
    IF BC-RC = 0
        MOVE 1 TO BC-LANES-OK
    ELSE
        MOVE 0 TO BC-LANES-OK
        DISPLAY "bcrypt: lanes self-test failed; hashing one at a time" UPON SYSERR
    END-IF
    PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > 4
        SET BC-KP (BC-I) TO ADDRESS OF BC-B-KEY (BC-I)
        SET BC-SP (BC-I) TO ADDRESS OF BC-B-SET (BC-I)
        SET BC-OP (BC-I) TO ADDRESS OF BC-B-OUT (BC-I)
    END-PERFORM
    PERFORM FOREVER
        MOVE BC-HFD TO BC-IO-FD
        SET BC-IO-PTR TO ADDRESS OF BC-BATCH
        MOVE LENGTH OF BC-BATCH TO BC-IO-LEN
        PERFORM BC-READ-FULL
        IF BC-IO-OK = 0
            STOP RUN
        END-IF
        PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > 4
            MOVE "*" TO BC-B-OUT (BC-I) (1:1)
        END-PERFORM
        IF BC-LANES-OK = 1
            CALL "_crypt_blowfish_lanes" USING BY VALUE BC-B-N BY REFERENCE BC-KPTRS BY REFERENCE BC-SPTRS
                BY REFERENCE BC-OPTRS RETURNING BC-RC
        ELSE
            PERFORM VARYING BC-I FROM 1 BY 1 UNTIL BC-I > BC-B-N
                CALL "_crypt_blowfish_rn" USING BY REFERENCE BC-B-KEY (BC-I) BY REFERENCE BC-B-SET (BC-I)
                    BY REFERENCE BC-B-OUT (BC-I) BY VALUE BC-K64 RETURNING BC-PTR
                IF BC-PTR = NULL
                    MOVE "*" TO BC-B-OUT (BC-I) (1:1)
                END-IF
            END-PERFORM
        END-IF
        MOVE BC-HFD TO BC-IO-FD
        SET BC-IO-PTR TO ADDRESS OF BC-BREPLY
        MOVE LENGTH OF BC-BREPLY TO BC-IO-LEN
        PERFORM BC-WRITE-FULL
        IF BC-IO-OK = 0
            STOP RUN
        END-IF
    END-PERFORM.

*> Blocking reads and writes of BC-IO-LEN bytes at BC-IO-PTR on BC-IO-FD, for the bcrypt process.
BC-READ-FULL.
    MOVE 0 TO BC-IO-GOT
    MOVE 1 TO BC-IO-OK
    SET ADDRESS OF L-BUF TO BC-IO-PTR
    PERFORM UNTIL BC-IO-GOT >= BC-IO-LEN
        COMPUTE BC-SZ = BC-IO-LEN - BC-IO-GOT
        CALL "read" USING BY VALUE BC-IO-FD BY REFERENCE L-BUF (BC-IO-GOT + 1:1) BY VALUE BC-SZ
            RETURNING BC-RC
        IF BC-RC = 0
            MOVE 0 TO BC-IO-OK
            EXIT PARAGRAPH
        END-IF
        IF BC-RC < 0
            IF L-ERRNO NOT = EINTR
                MOVE 0 TO BC-IO-OK
                EXIT PARAGRAPH
            END-IF
        ELSE
            ADD BC-RC TO BC-IO-GOT
        END-IF
    END-PERFORM.

BC-WRITE-FULL.
    MOVE 0 TO BC-IO-GOT
    MOVE 1 TO BC-IO-OK
    SET ADDRESS OF L-BUF TO BC-IO-PTR
    PERFORM UNTIL BC-IO-GOT >= BC-IO-LEN
        COMPUTE BC-SZ = BC-IO-LEN - BC-IO-GOT
        CALL "write" USING BY VALUE BC-IO-FD BY REFERENCE L-BUF (BC-IO-GOT + 1:1) BY VALUE BC-SZ
            RETURNING BC-RC
        IF BC-RC < 0
            IF L-ERRNO NOT = EINTR
                MOVE 0 TO BC-IO-OK
                EXIT PARAGRAPH
            END-IF
        ELSE
            ADD BC-RC TO BC-IO-GOT
        END-IF
    END-PERFORM.
