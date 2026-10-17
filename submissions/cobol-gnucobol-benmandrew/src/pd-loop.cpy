*> ================= worker =================

WORKER-MAIN.
    CALL "prctl" USING BY VALUE K-PDEATHSIG-D BY VALUE K-SIGTERM-D
    CALL "__errno_location" RETURNING ERRNO-PTR
    SET ADDRESS OF L-ERRNO TO ERRNO-PTR
    CALL "epoll_create1" USING BY VALUE K-0 RETURNING EPFD
    PERFORM HMAC-INIT
    PERFORM PG-INIT-ALL
    PERFORM BC-WORKER-INIT
    PERFORM OPEN-LISTENER
    IF WORKER-INDEX = 0
        MOVE LISTEN-PORT TO NUM-ED
        DISPLAY "conduit (cobol): listening on " FUNCTION TRIM (LISTEN-HOST) ":" FUNCTION TRIM (NUM-ED)
    END-IF
    PERFORM WORKER-LOOP.

*> Each iteration handles the events epoll returns, then gives each Postgres connection one write: the
*> requests queued in this iteration go out together.
WORKER-LOOP.
    PERFORM FOREVER
        MOVE -1 TO EP-TIMEOUT
        IF PG-DOWN > 0
            PERFORM PG-RETRY-TIMEOUT
        END-IF
        CALL "epoll_wait" USING BY VALUE EPFD BY REFERENCE EVENTS BY VALUE K-EV-MAX BY VALUE EP-TIMEOUT
            RETURNING NEV
        *> wall-clock seconds, for token expiry and issue times
        CALL "clock_gettime" USING BY VALUE K-0 BY REFERENCE TS
        MOVE TS-SEC TO NOW-SEC
        PERFORM VARYING EI FROM 1 BY 1 UNTIL EI > NEV
            MOVE EVS-FD (EI) TO SOCK-FD
            MOVE SOCK-FD TO FX
            ADD 1 TO FX
            EVALUATE CN-KIND (FX)
                WHEN 2
                    PERFORM CLIENT-EVENT
                WHEN 3
                    MOVE CN-PG (FX) TO P
                    PERFORM PG-EVENT
                WHEN 1
                    PERFORM ACCEPT-CLIENTS
                WHEN 4
                    PERFORM BC-WORKER-EVENT
            END-EVALUATE
        END-PERFORM
        IF PG-DOWN > 0
            PERFORM PG-RETRY-DUE
        END-IF
        PERFORM VARYING PX FROM 1 BY 1 UNTIL PX > N-PG
            PERFORM PG-FLUSH
        END-PERFORM
    END-PERFORM.

OPEN-LISTENER.
    CALL "socket" USING BY VALUE K-AF-INET BY VALUE K-SOCK-STREAM-NB BY VALUE K-0 RETURNING LISTEN-FD
    CALL "setsockopt" USING BY VALUE LISTEN-FD BY VALUE K-SOL-SOCKET BY VALUE K-SO-REUSEADDR
        BY REFERENCE K-OPT-ON BY VALUE K-OPT-LEN
    CALL "setsockopt" USING BY VALUE LISTEN-FD BY VALUE K-SOL-SOCKET BY VALUE K-SO-REUSEPORT
        BY REFERENCE K-OPT-ON BY VALUE K-OPT-LEN
    MOVE 2 TO SA-FAMILY
    DIVIDE LISTEN-PORT BY 256 GIVING SA-PORT-HI REMAINDER SA-PORT-LO
    CALL "inet_addr" USING BY REFERENCE LISTEN-HOST-Z RETURNING SA-ADDR
    MOVE LOW-VALUES TO SA-ZERO
    CALL "bind" USING BY VALUE LISTEN-FD BY REFERENCE SA BY VALUE K-SA-LEN RETURNING RC
    IF RC NOT = 0
        DISPLAY "bind failed, errno " L-ERRNO UPON SYSERR
        MOVE 1 TO RETURN-CODE
        STOP RUN
    END-IF
    CALL "listen" USING BY VALUE LISTEN-FD BY VALUE K-BACKLOG
    MOVE 1 TO CN-KIND (LISTEN-FD + 1)
    MOVE K-EV-IN TO EV-EVENTS
    MOVE LISTEN-FD TO EV-FD
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE LISTEN-FD BY REFERENCE EV.

ACCEPT-CLIENTS.
    PERFORM 64 TIMES
        CALL "accept4" USING BY VALUE LISTEN-FD BY VALUE NULL-PTR BY VALUE NULL-PTR BY VALUE K-SOCK-NONBLOCK
            RETURNING CFD
        IF CFD < 0
            EXIT PERFORM
        END-IF
        IF CFD >= MAX-FD
            CALL "close" USING BY VALUE CFD
        ELSE
            *> A response larger than one segment would otherwise wait for the client's delayed ACK (40 ms).
            CALL "setsockopt" USING BY VALUE CFD BY VALUE K-IPPROTO-TCP BY VALUE K-TCP-NODELAY
                BY REFERENCE K-OPT-ON BY VALUE K-OPT-LEN
            MOVE CFD TO CX
            ADD 1 TO CX
            MOVE 2 TO CN-KIND (CX)
            MOVE 0 TO CN-BUSY (CX) CN-CLOSE (CX) CN-STEP (CX) CN-IN-LEN (CX) CN-OUT-LEN (CX) CN-OUT-OFF (CX)
            SET CN-CTX-PTR (CX) TO NULL
            ADD 1 TO CN-GEN (CX)
            MOVE K-EV-IN TO EV-EVENTS
            MOVE CFD TO EV-FD
            CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-ADD BY VALUE CFD BY REFERENCE EV
        END-IF
    END-PERFORM.

*> ---------- clients ----------

*> A client is registered for EPOLLIN, or for EPOLLOUT alone while a response is partly written.
CLIENT-EVENT.
    MOVE 0 TO CLOSED
    IF CN-OUT-LEN (FX) > 0
        PERFORM CLIENT-DRAIN
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO IN-LEN
    IF CN-IN-LEN (FX) > 0
        PERFORM TAKE-STASH
    END-IF
    IF IN-LEN >= IN-SIZE
        *> a request larger than the buffer
        IF CN-BUSY (FX) = 1
            PERFORM CLOSE-CLIENT
        ELSE
            MOVE 1 TO CN-CLOSE (FX)
            MOVE 400 TO ERR-STATUS
            MOVE "bad request" TO ERR-MSG
            PERFORM RESPOND-ERROR
        END-IF
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO SIZE-T
    ADD IN-SIZE TO SIZE-T
    SUBTRACT IN-LEN FROM SIZE-T
    CALL "read" USING BY VALUE SOCK-FD BY REFERENCE IN-BUF (IN-LEN + 1:1) BY VALUE SIZE-T RETURNING IN-N
    IF IN-N = 0
        PERFORM CLOSE-CLIENT
        EXIT PARAGRAPH
    END-IF
    IF IN-N < 0
        IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
            PERFORM CLOSE-CLIENT
            EXIT PARAGRAPH
        END-IF
        MOVE 0 TO IN-N
    END-IF
    ADD IN-N TO IN-LEN
    MOVE 1 TO IN-POS
    PERFORM PROCESS-INPUT.

TAKE-STASH.
    SET ADDRESS OF L-BUF TO CN-IN-PTR (FX)
    MOVE CN-IN-LEN (FX) TO IN-LEN
    MOVE L-BUF (1:IN-LEN) TO IN-BUF (1:IN-LEN)
    CALL "free" USING BY VALUE CN-IN-PTR (FX)
    SET CN-IN-PTR (FX) TO NULL
    MOVE 0 TO CN-IN-LEN (FX).

*> Handles the requests in IN-BUF from IN-POS to IN-LEN, until the client is busy.
PROCESS-INPUT.
    PERFORM UNTIL IN-POS > IN-LEN OR CLOSED = 1
        IF CN-BUSY (FX) = 1
            PERFORM STASH-INPUT
            EXIT PERFORM
        END-IF
        PERFORM PARSE-REQUEST
        EVALUATE REQ-STATE
            WHEN 0
                PERFORM STASH-INPUT
                EXIT PERFORM
            WHEN 2
                *> nothing after a malformed request is read
                MOVE 1 TO CN-CLOSE (FX)
                MOVE IN-LEN TO IN-POS
                ADD 1 TO IN-POS
                MOVE 400 TO ERR-STATUS
                MOVE "bad request" TO ERR-MSG
                PERFORM RESPOND-ERROR
                EXIT PERFORM
            WHEN OTHER
                MOVE REQ-NEXT TO IN-POS
                IF REQ-CLOSE = 1
                    MOVE 1 TO CN-CLOSE (FX)
                END-IF
                PERFORM DISPATCH
        END-EVALUATE
    END-PERFORM.

STASH-INPUT.
    MOVE IN-LEN TO STASH-LEN
    SUBTRACT IN-POS FROM STASH-LEN
    ADD 1 TO STASH-LEN
    IF STASH-LEN > 0
        MOVE 0 TO SIZE-T
        ADD STASH-LEN TO SIZE-T
        CALL "malloc" USING BY VALUE SIZE-T RETURNING PTR
        SET CN-IN-PTR (FX) TO PTR
        SET ADDRESS OF L-BUF TO PTR
        MOVE IN-BUF (IN-POS:STASH-LEN) TO L-BUF (1:STASH-LEN)
        MOVE STASH-LEN TO CN-IN-LEN (FX)
    END-IF
    MOVE IN-LEN TO IN-POS
    ADD 1 TO IN-POS.

*> Called when a client becomes idle with stashed input.
CLIENT-RESUME.
    PERFORM TAKE-STASH
    MOVE 1 TO IN-POS
    PERFORM PROCESS-INPUT.

*> After an answer that came from Postgres or bcrypt: carry on with the client's pipelined requests.
AFTER-RESPONSE.
    IF CLOSED = 0 AND CN-KIND (FX) = 2 AND CN-BUSY (FX) = 0 AND CN-IN-LEN (FX) > 0
        PERFORM CLIENT-RESUME
    END-IF.

CLIENT-DRAIN.
    SET ADDRESS OF L-BUF TO CN-OUT-PTR (FX)
    MOVE 0 TO SIZE-T
    ADD CN-OUT-LEN (FX) TO SIZE-T
    SUBTRACT CN-OUT-OFF (FX) FROM SIZE-T
    CALL "write" USING BY VALUE SOCK-FD BY REFERENCE L-BUF (CN-OUT-OFF (FX) + 1:1) BY VALUE SIZE-T
        RETURNING RESP-N
    IF RESP-N < 0
        IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
            PERFORM CLOSE-CLIENT
        END-IF
        EXIT PARAGRAPH
    END-IF
    ADD RESP-N TO CN-OUT-OFF (FX)
    IF CN-OUT-OFF (FX) = CN-OUT-LEN (FX)
        CALL "free" USING BY VALUE CN-OUT-PTR (FX)
        SET CN-OUT-PTR (FX) TO NULL
        MOVE 0 TO CN-OUT-LEN (FX) CN-OUT-OFF (FX) CN-BUSY (FX)
        IF CN-CLOSE (FX) = 1
            PERFORM CLOSE-CLIENT
            EXIT PARAGRAPH
        END-IF
        MOVE K-EV-IN TO EV-EVENTS
        MOVE SOCK-FD TO EV-FD
        CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE SOCK-FD BY REFERENCE EV
        IF CN-IN-LEN (FX) > 0
            PERFORM CLIENT-RESUME
        END-IF
    END-IF.

CLOSE-CLIENT.
    CALL "close" USING BY VALUE SOCK-FD
    MOVE 0 TO CN-KIND (FX) CN-BUSY (FX) CN-CLOSE (FX) CN-STEP (FX)
    ADD 1 TO CN-GEN (FX)
    IF CN-IN-LEN (FX) > 0
        CALL "free" USING BY VALUE CN-IN-PTR (FX)
        SET CN-IN-PTR (FX) TO NULL
        MOVE 0 TO CN-IN-LEN (FX)
    END-IF
    IF CN-OUT-LEN (FX) > 0
        CALL "free" USING BY VALUE CN-OUT-PTR (FX)
        SET CN-OUT-PTR (FX) TO NULL
        MOVE 0 TO CN-OUT-LEN (FX) CN-OUT-OFF (FX)
    END-IF
    PERFORM CTX-FREE
    MOVE 1 TO CLOSED.

*> ---------- responses ----------

*> Writes the head and the RESP-LEN bytes at RESP-PTR in one writev. Whatever the socket does not take is
*> copied to a buffer and written on EPOLLOUT; the client stays busy until then. A client marked to close is
*> closed once its response is written.
RESPOND.
    IF RESP-STATUS = 204
        MOVE HEAD-204 TO HEAD-BUF (1:27)
        MOVE 27 TO HEAD-LEN
    ELSE
        EVALUATE RESP-STATUS
            WHEN 200
                MOVE ST-200 TO HEAD-BUF (1:15)
                MOVE 16 TO HP
            WHEN 201
                MOVE ST-201 TO HEAD-BUF (1:20)
                MOVE 21 TO HP
            WHEN 400
                MOVE ST-400 TO HEAD-BUF (1:24)
                MOVE 25 TO HP
            WHEN 401
                MOVE ST-401 TO HEAD-BUF (1:25)
                MOVE 26 TO HP
            WHEN 403
                MOVE ST-403 TO HEAD-BUF (1:22)
                MOVE 23 TO HP
            WHEN 404
                MOVE ST-404 TO HEAD-BUF (1:22)
                MOVE 23 TO HP
            WHEN 422
                MOVE ST-422 TO HEAD-BUF (1:33)
                MOVE 34 TO HP
            WHEN OTHER
                MOVE ST-500 TO HEAD-BUF (1:34)
                MOVE 35 TO HP
        END-EVALUATE
        MOVE HDR-COMMON TO HEAD-BUF (HP:50)
        ADD 50 TO HP
        MOVE 0 TO NUM-IN
        ADD RESP-LEN TO NUM-IN
        PERFORM NUM-FMT
        MOVE NUM-TXT (1:NUM-TXT-LEN) TO HEAD-BUF (HP:NUM-TXT-LEN)
        ADD NUM-TXT-LEN TO HP
        MOVE CRLF2 TO HEAD-BUF (HP:4)
        MOVE HP TO HEAD-LEN
        ADD 3 TO HEAD-LEN
    END-IF
    SET IOV-HEAD TO ADDRESS OF HEAD-BUF
    MOVE 0 TO IOV-HEAD-LEN IOV-BODY-LEN
    ADD HEAD-LEN TO IOV-HEAD-LEN
    SET IOV-BODY TO RESP-PTR
    ADD RESP-LEN TO IOV-BODY-LEN
    MOVE HEAD-LEN TO RESP-TOTAL
    ADD RESP-LEN TO RESP-TOTAL
    CALL "writev" USING BY VALUE SOCK-FD BY REFERENCE IOV BY VALUE K-IOV-2 RETURNING RESP-N
    IF RESP-N = RESP-TOTAL
        MOVE 0 TO CN-BUSY (FX)
        IF CN-CLOSE (FX) = 1
            PERFORM CLOSE-CLIENT
        END-IF
        EXIT PARAGRAPH
    END-IF
    IF RESP-N < 0
        IF L-ERRNO NOT = EAGAIN AND L-ERRNO NOT = EINTR
            PERFORM CLOSE-CLIENT
            EXIT PARAGRAPH
        END-IF
        MOVE 0 TO RESP-N
    END-IF
    MOVE RESP-TOTAL TO RESP-REST
    SUBTRACT RESP-N FROM RESP-REST
    MOVE 0 TO SIZE-T
    ADD RESP-REST TO SIZE-T
    CALL "malloc" USING BY VALUE SIZE-T RETURNING PTR
    SET CN-OUT-PTR (FX) TO PTR
    SET ADDRESS OF L-BUF2 TO PTR
    SET ADDRESS OF L-BUF TO RESP-PTR
    IF RESP-N < HEAD-LEN
        MOVE HEAD-LEN TO HP
        SUBTRACT RESP-N FROM HP
        MOVE HEAD-BUF (RESP-N + 1:HP) TO L-BUF2 (1:HP)
        IF RESP-LEN > 0
            MOVE L-BUF (1:RESP-LEN) TO L-BUF2 (HP + 1:RESP-LEN)
        END-IF
    ELSE
        MOVE RESP-N TO HP
        SUBTRACT HEAD-LEN FROM HP
        MOVE L-BUF (HP + 1:RESP-REST) TO L-BUF2 (1:RESP-REST)
    END-IF
    MOVE RESP-REST TO CN-OUT-LEN (FX)
    MOVE 0 TO CN-OUT-OFF (FX)
    MOVE 1 TO CN-BUSY (FX)
    MOVE K-EV-OUT TO EV-EVENTS
    MOVE SOCK-FD TO EV-FD
    CALL "epoll_ctl" USING BY VALUE EPFD BY VALUE K-CTL-MOD BY VALUE SOCK-FD BY REFERENCE EV.

*> ERR-STATUS with the body {"errors":{"body":["<ERR-MSG>"]}}.
RESPOND-ERROR.
    MOVE 64 TO ERR-MSG-LEN
    PERFORM UNTIL ERR-MSG (ERR-MSG-LEN:1) NOT = SPACE
        SUBTRACT 1 FROM ERR-MSG-LEN
    END-PERFORM
    MOVE '{"errors":{"body":["' TO ERR-BUF (1:20)
    MOVE ERR-MSG (1:ERR-MSG-LEN) TO ERR-BUF (21:ERR-MSG-LEN)
    MOVE 21 TO ERR-LEN
    ADD ERR-MSG-LEN TO ERR-LEN
    MOVE '"]}}' TO ERR-BUF (ERR-LEN:4)
    ADD 3 TO ERR-LEN
    MOVE ERR-STATUS TO RESP-STATUS
    SET RESP-PTR TO ADDRESS OF ERR-BUF
    MOVE ERR-LEN TO RESP-LEN
    PERFORM RESPOND.

RESPOND-500.
    MOVE 500 TO ERR-STATUS
    MOVE "internal error" TO ERR-MSG
    PERFORM RESPOND-ERROR.

RESPOND-204.
    MOVE 204 TO RESP-STATUS
    SET RESP-PTR TO ADDRESS OF EMPTY-BODY
    MOVE 0 TO RESP-LEN
    PERFORM RESPOND.

*> ---------- two-step contexts ----------

CTX-CLEAR.
    MOVE 0 TO CX-N CX-USED.

*> Appends an item: CA-LEN bytes at offset CA-OFF (1-based) from CA-PTR, or an absent value if CA-PRES = 0.
CTX-ADD.
    ADD 1 TO CX-N
    MOVE CA-PRES TO CX-PRES (CX-N)
    MOVE CX-USED TO CX-OFF (CX-N)
    IF CA-PRES = 0
        MOVE 0 TO CX-LEN (CX-N)
    ELSE
        MOVE CA-LEN TO CX-LEN (CX-N)
        IF CA-LEN > 0
            SET ADDRESS OF L-SRC TO CA-PTR
            MOVE L-SRC (CA-OFF:CA-LEN) TO CX-DATA (CX-USED + 1:CA-LEN)
            ADD CA-LEN TO CX-USED
        END-IF
    END-IF.

*> Copies the staged items to a new block for client FX, replacing (and freeing) any context it had.
CTX-SAVE.
    MOVE CX-HDR-LEN TO CX-SIZE
    ADD CX-USED TO CX-SIZE
    MOVE 0 TO SIZE-T
    ADD CX-SIZE TO SIZE-T
    CALL "malloc" USING BY VALUE SIZE-T RETURNING PTR
    SET ADDRESS OF L-BUF2 TO PTR
    MOVE CTX-STAGE (1:CX-SIZE) TO L-BUF2 (1:CX-SIZE)
    SET CTX-OLD TO CN-CTX-PTR (FX)
    SET CN-CTX-PTR (FX) TO PTR
    IF CTX-OLD NOT = NULL
        CALL "free" USING BY VALUE CTX-OLD
    END-IF.

CTX-LOAD.
    SET ADDRESS OF L-CTX TO CN-CTX-PTR (FX).

CTX-FREE.
    IF CN-CTX-PTR (FX) NOT = NULL
        CALL "free" USING BY VALUE CN-CTX-PTR (FX)
        SET CN-CTX-PTR (FX) TO NULL
    END-IF.
