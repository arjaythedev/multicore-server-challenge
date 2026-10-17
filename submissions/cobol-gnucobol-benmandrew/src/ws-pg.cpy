*> ---------- pg: the Postgres driver ----------
78 PG-RB-SIZE        VALUE 8388608.
*> the read buffer is compacted before a read that would leave less than this free
78 PG-RB-LOW         VALUE 2097152.
78 PG-WB-SIZE        VALUE 8388608.
78 PG-OUT-SIZE       VALUE 8388608.
78 PG-PB-SIZE        VALUE 4194304.
78 PG-RING           VALUE 16384.

*> the connection of an epoll event (PG-EVENT) and of PG-FLUSH, set by the loop
01 P                 BINARY-LONG.
01 PX                BINARY-LONG.
*> connections currently down
01 PG-DOWN           BINARY-LONG.

*> ---------- building a request (PB-*) and PG-SUBMIT ----------
01 PB-ST             BINARY-LONG.
01 PB-H              BINARY-LONG.
01 PB-INT-V          BINARY-DOUBLE.
01 PB-OFF            BINARY-LONG.
01 PB-LEN            BINARY-LONG.
01 PG-SUBMIT-OK      BINARY-LONG.

*> ---------- what APP-ROW and APP-DONE receive ----------
01 RQ-H              BINARY-LONG.
01 RQ-STMT           BINARY-LONG.
01 RQ-ROW            BINARY-LONG.
01 RQ-ERR            BINARY-LONG.
01 RQ-SQLSTATE       PIC X(5).
01 RQ-NROWS-T.
   05 RQ-NROWS       BINARY-LONG OCCURS 4.
01 RW-NCOL           BINARY-LONG.
01 RW-TABLE.
   05 RW-OFF         BINARY-LONG OCCURS 32.
   05 RW-LEN         BINARY-LONG OCCURS 32.

*> ---------- messages ----------
01 PG-SYNC-MSG       PIC X(5) VALUE X"5300000004".
*> Execute: unnamed portal, no row limit
01 PG-EXEC-MSG       PIC X(10) VALUE X"45000000090000000000".
*> one result format code: binary
01 PG-RESFMT         PIC X(4) VALUE X"00010001".

*> ---------- connections ----------
*> Requests are answered in the order they were queued, so each connection keeps them in a ring (head PG-RH,
*> PG-RN entries, last PG-RT). Every Sync has a sequence number: PG-SEQ-NEXT is the one the next Sync appended to
*> the write buffer will carry (so the open group's), PG-SEQ-HEAD the one the next ReadyForQuery answers. A request
*> records the Sync it belongs to in PG-Q-SEQ, so the head request is the one being answered when its PG-Q-SEQ is
*> PG-SEQ-HEAD. Only the head request receives rows, so its progress (PG-NDONE, PG-ROWS, PG-NROWS, PG-ERR) and its
*> render output (PG-OUTLEN bytes of PG-OUT-PTR) are kept once per connection.
*> The write buffer holds PG-WLEN bytes: PG-WOFF are written, up to PG-WEND may be written (the Syncs counted in
*> PG-SSYNCS), and the rest waits for the next PG-FLUSH (the open group's Binds, and PG-QSYNCS Syncs).
01 PG-CONNS.
   05 PG-C OCCURS 8.
      10 PG-FD       BINARY-LONG.
      10 PG-UP       BINARY-CHAR UNSIGNED.
      10 PG-WANT-OUT BINARY-CHAR UNSIGNED.
      10 PG-OPEN     BINARY-CHAR UNSIGNED.
      10 PG-ERR      BINARY-CHAR UNSIGNED.
      10 PG-SQLSTATE PIC X(5).
      10 PG-RB-PTR   USAGE POINTER.
      10 PG-WB-PTR   USAGE POINTER.
      10 PG-OUT-PTR  USAGE POINTER.
      10 PG-RLEN     BINARY-LONG.
      10 PG-RPOS     BINARY-LONG.
      10 PG-WLEN     BINARY-LONG.
      10 PG-WOFF     BINARY-LONG.
      10 PG-WEND     BINARY-LONG.
      10 PG-QSYNCS   BINARY-LONG.
      10 PG-SSYNCS   BINARY-LONG.
      10 PG-RH       BINARY-LONG.
      10 PG-RT       BINARY-LONG.
      10 PG-RN       BINARY-LONG.
      10 PG-SEQ-HEAD BINARY-DOUBLE.
      10 PG-SEQ-NEXT BINARY-DOUBLE.
      10 PG-NDONE    BINARY-LONG.
      10 PG-ROWS     BINARY-LONG.
      10 PG-NROWS    BINARY-LONG OCCURS 4.
      10 PG-OUTLEN   BINARY-LONG.
      10 PG-RETRY-AT BINARY-DOUBLE.
      10 PG-BACKOFF  BINARY-LONG.
      10 PG-Q OCCURS 16384.
         15 PG-Q-FX     BINARY-LONG.
         15 PG-Q-GEN    BINARY-LONG.
         15 PG-Q-H      BINARY-LONG.
         15 PG-Q-NST    BINARY-LONG.
         15 PG-Q-SINGLE BINARY-CHAR UNSIGNED.
         15 PG-Q-SEQ    BINARY-DOUBLE.
         15 PG-Q-RS-PTR USAGE POINTER.
         15 PG-Q-RS-LEN BINARY-LONG.

*> ---------- PB-* and PG-SUBMIT scratch (never used by the parser: they run inside its callbacks) ----------
01 PG-PB-PTR         USAGE POINTER.
01 PB-W              BINARY-LONG.
01 PB-NST            BINARY-LONG.
01 PB-RO             BINARY-LONG.
01 PB-OVER           BINARY-LONG.
01 PB-BSTART         BINARY-LONG.
01 PB-NPPOS          BINARY-LONG.
01 PB-NP             BINARY-LONG.
01 PB-PSTART         BINARY-LONG.
01 PB-END            BINARY-LONG.
01 PB-I              BINARY-LONG.
01 PB-K              BINARY-LONG.
01 PB-D              BINARY-LONG.
01 PB-N              BINARY-LONG.
01 PB-L              BINARY-LONG.
01 PB-L-X REDEFINES PB-L PIC X(4).
01 PB-IV             BINARY-DOUBLE.
01 PB-IV-PARTS REDEFINES PB-IV.
   05 PB-IV-LO       BINARY-LONG.
   05 PB-IV-HI       BINARY-LONG.
01 PB-DIG            PIC X(24).
01 PB-DL             BINARY-LONG.
01 PB-ED             PIC -(19)9.
01 PB-DIGITS         PIC X(10) VALUE "0123456789".
01 PB-POW-VALUES.
   05 FILLER         BINARY-LONG VALUE 1000000000.
   05 FILLER         BINARY-LONG VALUE 100000000.
   05 FILLER         BINARY-LONG VALUE 10000000.
   05 FILLER         BINARY-LONG VALUE 1000000.
   05 FILLER         BINARY-LONG VALUE 100000.
   05 FILLER         BINARY-LONG VALUE 10000.
   05 FILLER         BINARY-LONG VALUE 1000.
   05 FILLER         BINARY-LONG VALUE 100.
   05 FILLER         BINARY-LONG VALUE 10.
01 PB-POW-T REDEFINES PB-POW-VALUES.
   05 PB-POW         BINARY-LONG OCCURS 9.
01 PB-PK             BINARY-LONG.
01 PB-BEST           BINARY-LONG.
01 PB-FREE           BINARY-LONG.
01 PB-NEED           BINARY-LONG.
01 PB-REST           BINARY-LONG.
01 PB-T              BINARY-LONG.
01 PB-SZ             BINARY-DOUBLE.
01 PB-PTR            USAGE POINTER.

*> ---------- parser and writer scratch ----------
01 PG-AV             BINARY-LONG.
01 PG-ML             BINARY-LONG.
01 PG-MEND           BINARY-LONG.
01 PG-MT             PIC X.
01 PG-QP             BINARY-LONG.
01 PG-CI             BINARY-LONG.
01 PG-COL            BINARY-LONG.
01 PG-L              BINARY-LONG.
01 PG-L-X REDEFINES PG-L PIC X(4).
01 PG-HX             BINARY-LONG.
01 PG-OK             BINARY-LONG.
01 PG-FX             BINARY-LONG.
01 PG-GEN            BINARY-LONG.
01 PG-SEQ-T          BINARY-DOUBLE.
01 PG-AX             BINARY-LONG.
01 PG-LX             BINARY-LONG.
01 PG-WX             BINARY-LONG.
01 PG-SX             BINARY-LONG.
01 PG-K              BINARY-LONG.
01 PG-N              BINARY-LONG.
01 PG-FREE           BINARY-LONG.
01 PG-RFREE          BINARY-LONG.
01 PG-REST           BINARY-LONG.
01 PG-TAIL           BINARY-LONG.
01 PG-SZ             BINARY-DOUBLE.
01 PG-DT             BINARY-DOUBLE.
*> ErrorResponse fields: PG-EB..PG-EE in L-RB; out PG-EC (SQLSTATE) and PG-WHY (message)
01 PG-EB             BINARY-LONG.
01 PG-EE             BINARY-LONG.
01 PG-EV             BINARY-LONG.
01 PG-EVE            BINARY-LONG.
01 PG-EVL            BINARY-LONG.
01 PG-EF             PIC X.
01 PG-EC             PIC X(5).
*> why a connection was lost or could not start
01 PG-WHY            PIC X(256).
01 PG-WHY-LEN        BINARY-LONG.
01 PG-NUM-ED         PIC -(9)9.

*> ---------- connecting (pd-pgconn) ----------
01 PG-CONN-OK        BINARY-LONG.
01 PG-SP             BINARY-LONG.
01 PG-MSTART         BINARY-LONG.
01 PG-MPOS           BINARY-LONG.
01 PG-AUTH-CODE      BINARY-LONG.
01 PG-READY-N        BINARY-LONG.
01 PG-READY-WANT     BINARY-LONG.
01 PG-BE4            PIC S9(9) COMP.
01 PG-BE4-X REDEFINES PG-BE4 PIC X(4).
01 PG-I              BINARY-LONG.
*> struct timeval for SO_RCVTIMEO / SO_SNDTIMEO while starting up
01 PG-TV.
   05 PG-TV-SEC      BINARY-DOUBLE VALUE 5.
   05 PG-TV-USEC     BINARY-DOUBLE VALUE 0.
01 PG-K-TV-LEN       BINARY-LONG VALUE 16.
01 PG-K-RCVTIMEO     BINARY-LONG VALUE 20.
01 PG-K-SNDTIMEO     BINARY-LONG VALUE 21.
*> SCRAM-SHA-256 (RFC 5802 / 7677), as Postgres uses it: the username is sent empty.
01 PG-SC-MD          USAGE POINTER.
01 PG-SC-NONCE-RAW   PIC X(18).
01 PG-SC-NONCE-B64   PIC X(32).
01 PG-SC-CFB         PIC X(64).
01 PG-SC-CFB-LEN     BINARY-LONG.
01 PG-SC-SF          PIC X(512).
01 PG-SC-SF-LEN      BINARY-LONG.
01 PG-SC-ATTR        PIC X(512) OCCURS 3.
01 PG-SC-ATTR-LEN    BINARY-LONG OCCURS 3.
01 PG-SC-NONCE       PIC X(256).
01 PG-SC-NONCE-LEN   BINARY-LONG.
01 PG-SC-SALT-B64    PIC X(256).
01 PG-SC-SALT-B64-LEN BINARY-LONG.
01 PG-SC-SALT        PIC X(256).
01 PG-SC-SALT-LEN    BINARY-LONG.
01 PG-SC-PAD         BINARY-LONG.
01 PG-SC-ITERS       BINARY-LONG.
01 PG-SC-SALTED      PIC X(32).
01 PG-SC-CKEY        PIC X(32).
01 PG-SC-SKEY        PIC X(32).
01 PG-SC-SIG         PIC X(32).
01 PG-SC-PROOF       PIC X(32).
01 PG-SC-PROOF-B64   PIC X(64).
01 PG-SC-CK-LABEL    PIC X(10) VALUE "Client Key".
01 PG-SC-WP          PIC X(512).
01 PG-SC-WP-LEN      BINARY-LONG.
01 PG-SC-AM          PIC X(2048).
01 PG-SC-AM-LEN      BINARY-LONG.
01 PG-SC-AM-LEN-D    BINARY-DOUBLE.
01 PG-SC-RC          BINARY-LONG.
