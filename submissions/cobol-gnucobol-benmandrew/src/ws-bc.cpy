*> ---------- bcrypt: interface ----------
*> The worker's end of its socketpair to the bcrypt process.
01 BC-FD             BINARY-LONG.
*> BC-SUBMIT sends the password L-SRC (BC-PW-OFF:BC-PW-LEN) for client FX: BC-MODE 1 hashes it with a new salt,
*> 2 verifies it against the stored hash BC-SETTING (1:BC-SETTING-LEN); BC-SUBMIT-OK 1/0. BC-USABLE checks the
*> password first: BC-USABLE-OK 1/0. The reply comes back through BC-WORKER-EVENT to APP-BC-DONE, with the hash
*> in BC-RESULT (1:BC-RESULT-LEN), or BC-RESULT-LEN 0 when hashing failed.
01 BC-MODE           BINARY-LONG.
01 BC-SETTING        PIC X(128).
01 BC-SETTING-LEN    BINARY-LONG.
01 BC-PW-OFF         BINARY-LONG.
01 BC-PW-LEN         BINARY-LONG.
01 BC-SUBMIT-OK      BINARY-LONG.
01 BC-USABLE-OK      BINARY-LONG.
01 BC-RESULT         PIC X(64).
01 BC-RESULT-LEN     BINARY-LONG.

*> ---------- bcrypt: worker side ----------
*> Frames, both ways, in native byte order: int32 length of the rest, int32 client fd, int32 client generation,
*> payload. A request's payload is the setting, NUL, the password; a reply's is the hash, or nothing on failure.
01 BC-FRAME.
   05 BC-F-LEN       BINARY-LONG.
   05 BC-F-FD        BINARY-LONG.
   05 BC-F-GEN       BINARY-LONG.
   05 BC-F-DATA      PIC X(256).
01 BC-FRAME-X REDEFINES BC-FRAME PIC X(268).
01 BC-FRAME-LEN      BINARY-LONG.
01 BC-HDR.
   05 BC-H-LEN       BINARY-LONG.
   05 BC-H-FD        BINARY-LONG.
   05 BC-H-GEN       BINARY-LONG.
01 BC-RND            PIC X(16).
01 BC-SALT           PIC X(32).
01 BC-PREFIX         PIC X(5) VALUE "$2b$" & X"00".
01 BC-K16            BINARY-LONG VALUE 16.
01 BC-K64            BINARY-LONG VALUE 64.
01 BC-SET-LEN        BINARY-LONG.
01 BC-KEY-LEN        BINARY-LONG.
01 BC-I              BINARY-LONG.
01 BC-N              BINARY-LONG.
01 BC-RC             BINARY-LONG.
01 BC-SZ             BINARY-DOUBLE.
01 BC-PTR            USAGE POINTER.
01 BC-FX             BINARY-LONG.
*> requests the socket did not take, written on EPOLLOUT
01 BC-OBUF           PIC X(262144).
01 BC-OLEN           BINARY-LONG.
01 BC-OOFF           BINARY-LONG.
01 BC-OSPACE         BINARY-LONG.
01 BC-REST           BINARY-LONG.
*> replies read, up to the last whole frame
01 BC-RBUF           PIC X(65536).
01 BC-RLEN           BINARY-LONG.
01 BC-RPOS           BINARY-LONG.
01 BC-AVAIL          BINARY-LONG.
01 BC-TOTAL          BINARY-LONG.

*> ---------- bcrypt: the bcrypt process ----------
78 BC-QCAP           VALUE 65536.
78 BC-WBCAP          VALUE 8192.
*> jobs queued: BC-NJ of them from BC-QH; the next goes at BC-QT (ring of BC-QCAP in L-BC-Q)
01 BC-NJ             BINARY-LONG.
01 BC-QH             BINARY-LONG.
01 BC-QT             BINARY-LONG.
01 BC-W              BINARY-LONG.
01 BC-W-OPEN-T.
   05 BC-W-OPEN      BINARY-CHAR UNSIGNED OCCURS 256.
01 BC-TAG            BINARY-LONG.
01 BC-HX             BINARY-LONG.
01 BC-HI             BINARY-LONG.
01 BC-HASHERS.
   05 BC-HS OCCURS 64.
      10 BC-HS-FD    BINARY-LONG.
      10 BC-HS-BUSY  BINARY-LONG.
      10 BC-HS-N     BINARY-LONG.
      10 BC-HS-JW    BINARY-LONG OCCURS 4.
      10 BC-HS-JFD   BINARY-LONG OCCURS 4.
      10 BC-HS-JGEN  BINARY-LONG OCCURS 4.
01 BC-DEADLINE-SET   BINARY-LONG.
01 BC-DEADLINE       BINARY-DOUBLE.
01 BC-NUL-AT         BINARY-LONG.
01 BC-PL             BINARY-LONG.
01 BC-OFF            BINARY-LONG.
*> a batch for a hasher, and its answer; strings are NUL-terminated
01 BC-BATCH.
   05 BC-B-N         BINARY-LONG.
   05 BC-B-SET       PIC X(128) OCCURS 4.
   05 BC-B-KEY       PIC X(80) OCCURS 4.
01 BC-BREPLY.
   05 BC-B-OUT       PIC X(64) OCCURS 4.
01 BC-KPTRS.
   05 BC-KP          USAGE POINTER OCCURS 4.
01 BC-SPTRS.
   05 BC-SP          USAGE POINTER OCCURS 4.
01 BC-OPTRS.
   05 BC-OP          USAGE POINTER OCCURS 4.
01 BC-LANES-OK       BINARY-LONG.
01 BC-HFD            BINARY-LONG.
*> BC-READ-FULL / BC-WRITE-FULL: BC-IO-LEN bytes at BC-IO-PTR on BC-IO-FD (blocking); BC-IO-OK 1/0
01 BC-IO-FD          BINARY-LONG.
01 BC-IO-PTR         USAGE POINTER.
01 BC-IO-LEN         BINARY-LONG.
01 BC-IO-GOT         BINARY-LONG.
01 BC-IO-OK          BINARY-LONG.
