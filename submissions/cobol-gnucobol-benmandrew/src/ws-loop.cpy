*> ---------- sockets ----------
01 SA.
   05 SA-FAMILY      BINARY-SHORT UNSIGNED.
   05 SA-PORT-HI     BINARY-CHAR UNSIGNED.
   05 SA-PORT-LO     BINARY-CHAR UNSIGNED.
   05 SA-ADDR        BINARY-LONG.
   05 SA-ZERO        PIC X(8).
01 EPFD              BINARY-LONG.
01 LISTEN-FD         BINARY-LONG.
01 RC                BINARY-LONG.
01 PTR               USAGE POINTER.
01 ERRNO-PTR         USAGE POINTER.
01 SIZE-T            BINARY-DOUBLE.

*> epoll_event is packed on x86-64: u32 events, u64 data. The data holds the fd in its low half.
01 EV.
   05 EV-EVENTS      BINARY-LONG UNSIGNED.
   05 EV-FD          BINARY-LONG.
   05 EV-PAD         BINARY-LONG.
01 EVENTS.
   05 EVS OCCURS 512.
      10 EVS-EVENTS  BINARY-LONG UNSIGNED.
      10 EVS-FD      BINARY-LONG.
      10 EVS-PAD     BINARY-LONG.
01 NEV               BINARY-LONG.
01 EI                BINARY-LONG.
01 EP-TIMEOUT        BINARY-LONG.

*> One record per fd (index fd + 1). Kind: 0 free, 1 listener, 2 client, 3 Postgres, 4 bcrypt process.
*> A client is busy from a request's dispatch until its response is written; input that arrives meanwhile,
*> and any partial request, waits in a malloc'd stash. A request that takes two steps (a Postgres lookup,
*> then a write or a bcrypt hash) keeps what the second step needs in a malloc'd context.
01 CONNS.
   05 CN OCCURS 65536.
      10 CN-KIND     BINARY-CHAR UNSIGNED.
      10 CN-PG       BINARY-CHAR UNSIGNED.
      10 CN-BUSY     BINARY-CHAR UNSIGNED.
      *> close the connection once this response is written
      10 CN-CLOSE    BINARY-CHAR UNSIGNED.
      *> a bcrypt hash outstanding: 1 register, 2 login, 3 update user
      10 CN-STEP     BINARY-CHAR UNSIGNED.
      *> the count statement for an empty list page
      10 CN-COUNT-ST BINARY-CHAR UNSIGNED.
      10 CN-GEN      BINARY-LONG.
      10 CN-VIEWER   BINARY-DOUBLE.
      *> values a handler keeps from a row until its request completes (a list's total, an owner's id)
      10 CN-AUX      BINARY-DOUBLE.
      10 CN-AUX2     BINARY-DOUBLE.
      10 CN-IN-PTR   USAGE POINTER.
      10 CN-IN-LEN   BINARY-LONG.
      10 CN-OUT-PTR  USAGE POINTER.
      10 CN-OUT-LEN  BINARY-LONG.
      10 CN-OUT-OFF  BINARY-LONG.
      10 CN-CTX-PTR  USAGE POINTER.

*> ---------- client input ----------
78 IN-SIZE           VALUE 1048576.
01 SOCK-FD           BINARY-LONG.
01 FX                BINARY-LONG.
01 CFD               BINARY-LONG.
01 CX                BINARY-LONG.
01 CLOSED            BINARY-CHAR UNSIGNED.
01 IN-BUF            PIC X(1048576).
01 IN-LEN            BINARY-LONG.
01 IN-POS            BINARY-LONG.
01 IN-N              BINARY-LONG.
01 STASH-LEN         BINARY-LONG.

*> ---------- responses ----------
01 RESP-STATUS       BINARY-LONG.
01 RESP-PTR          USAGE POINTER.
01 RESP-LEN          BINARY-LONG.
01 RESP-N            BINARY-LONG.
01 RESP-TOTAL        BINARY-LONG.
01 RESP-REST         BINARY-LONG.
01 HEAD-BUF          PIC X(256).
01 HEAD-LEN          BINARY-LONG.
01 HP                BINARY-LONG.
01 IOV.
   05 IOV-HEAD       USAGE POINTER.
   05 IOV-HEAD-LEN   BINARY-DOUBLE.
   05 IOV-BODY       USAGE POINTER.
   05 IOV-BODY-LEN   BINARY-DOUBLE.
01 ST-200            PIC X(15) VALUE "HTTP/1.1 200 OK".
01 ST-201            PIC X(20) VALUE "HTTP/1.1 201 Created".
01 ST-400            PIC X(24) VALUE "HTTP/1.1 400 Bad Request".
01 ST-401            PIC X(25) VALUE "HTTP/1.1 401 Unauthorized".
01 ST-403            PIC X(22) VALUE "HTTP/1.1 403 Forbidden".
01 ST-404            PIC X(22) VALUE "HTTP/1.1 404 Not Found".
01 ST-422            PIC X(33) VALUE "HTTP/1.1 422 Unprocessable Entity".
01 ST-500            PIC X(34) VALUE "HTTP/1.1 500 Internal Server Error".
01 HEAD-204          PIC X(27) VALUE "HTTP/1.1 204 No Content" & X"0D0A0D0A".
01 HDR-COMMON.
   05 FILLER         PIC X(2)  VALUE X"0D0A".
   05 FILLER         PIC X(30) VALUE "Content-Type: application/json".
   05 FILLER         PIC X(2)  VALUE X"0D0A".
   05 FILLER         PIC X(16) VALUE "Content-Length: ".
01 CRLF2             PIC X(4) VALUE X"0D0A0D0A".
*> {"errors":{"body":["<message>"]}}
01 ERR-MSG           PIC X(64).
01 ERR-MSG-LEN       BINARY-LONG.
01 ERR-STATUS        BINARY-LONG.
01 ERR-BUF           PIC X(128).
01 ERR-LEN           BINARY-LONG.
01 EMPTY-BODY        PIC X VALUE SPACE.

*> ---------- two-step contexts ----------
*> Built here, then copied to a malloc'd block of the same layout (L-CTX): item i is the bytes at offset
*> CX-OFF (i) of the data, CX-LEN (i) long; CX-PRES (i) = 0 for an absent value (a SQL NULL).
78 CX-HDR-LEN        VALUE 76.
01 CTX-STAGE.
   05 CX-N           BINARY-LONG.
   05 CX-PRES        BINARY-CHAR UNSIGNED OCCURS 8.
   05 CX-OFF         BINARY-LONG OCCURS 8.
   05 CX-LEN         BINARY-LONG OCCURS 8.
   05 CX-DATA        PIC X(1048576).
01 CX-USED           BINARY-LONG.
01 CX-SIZE           BINARY-LONG.
01 CA-PTR            USAGE POINTER.
01 CA-OFF            BINARY-LONG.
01 CA-LEN            BINARY-LONG.
01 CA-PRES           BINARY-CHAR UNSIGNED.
01 CTX-OLD           USAGE POINTER.
