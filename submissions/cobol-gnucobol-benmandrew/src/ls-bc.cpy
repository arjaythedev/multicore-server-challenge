*> LINKAGE items private to the bc module: the bcrypt process's job queue and per-worker read buffers (malloc'd
*> in BC-MAIN, so the other processes do not carry them).
01 L-BC-Q.
   05 BC-J OCCURS 65536.
      10 BC-J-W      BINARY-LONG.
      10 BC-J-FD     BINARY-LONG.
      10 BC-J-GEN    BINARY-LONG.
      10 BC-J-AT     BINARY-DOUBLE.
      10 BC-J-SET    PIC X(128).
      10 BC-J-KEY    PIC X(80).
01 L-BC-WB.
   05 BC-WB OCCURS 256.
      10 BC-WB-LEN   BINARY-LONG.
      10 BC-WB-DATA  PIC X(8192).
