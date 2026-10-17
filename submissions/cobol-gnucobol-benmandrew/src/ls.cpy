*> Shared LINKAGE items: storage that lives in malloc'd blocks, addressed with SET ADDRESS OF before use.
*> Module-private LINKAGE items go in ls-<module>.cpy.
01 L-ERRNO           BINARY-LONG.
*> scratch views, for copies; set them immediately before use and never rely on them across a PERFORM
01 L-BUF             PIC X(16777216).
01 L-BUF2            PIC X(16777216).
*> the source of a text copy: CTX-ADD, PB-TEXT, JO-STR
01 L-SRC             PIC X(16777216).
*> the read buffer of the Postgres connection being parsed: the DataRow columns in RW-OFF/RW-LEN point into it
01 L-RB              PIC X(16777216).
*> the render buffer of the request that receives rows; OUT-LEN bytes are used
01 L-OUT             PIC X(16777216).
*> a client's two-step context (layout as CTX-STAGE in ws-loop.cpy): item i is LC-DATA (LC-OFF (i) + 1:LC-LEN (i))
01 L-CTX.
   05 LC-N           BINARY-LONG.
   05 LC-PRES        BINARY-CHAR UNSIGNED OCCURS 8.
   05 LC-OFF         BINARY-LONG OCCURS 8.
   05 LC-LEN         BINARY-LONG OCCURS 8.
   05 LC-DATA        PIC X(1048576).
