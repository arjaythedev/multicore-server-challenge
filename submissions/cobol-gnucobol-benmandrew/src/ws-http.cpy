*> ---------- request parsing ----------
*> REQ-STATE: 0 incomplete, 1 a whole request, 2 malformed. Offsets are positions in IN-BUF.
01 REQ-STATE         BINARY-LONG.
01 REQ-START         BINARY-LONG.
01 REQ-NEXT          BINARY-LONG.
01 REQ-CLOSE         BINARY-LONG.
01 REQ-REM           BINARY-LONG.
01 HDR-CNT           BINARY-LONG.
01 HDR-END           BINARY-LONG.
01 LN-START          BINARY-LONG.
01 LN-END            BINARY-LONG.
01 HI                BINARY-LONG.
01 HJ                BINARY-LONG.
01 HCOLON            BINARY-LONG.
01 HNAME-LEN         BINARY-LONG.
01 HNAME             PIC X(16).
01 HVAL-OFF          BINARY-LONG.
01 HVAL-END          BINARY-LONG.
01 HVAL-LEN          BINARY-LONG.
01 HVAL-LC           PIC X(16).
01 METH-OFF          BINARY-LONG.
01 METH-LEN          BINARY-LONG.
01 METH-CODE         BINARY-LONG.
01 TGT-OFF           BINARY-LONG.
01 TGT-LEN           BINARY-LONG.
01 PATH-LEN          BINARY-LONG.
01 QRY-OFF           BINARY-LONG.
01 QRY-LEN           BINARY-LONG.
01 AUTH-SET          BINARY-LONG.
01 AUTH-OFF          BINARY-LONG.
01 AUTH-LEN          BINARY-LONG.
01 CLEN              BINARY-LONG.
01 BODY-OFF          BINARY-LONG.
01 BODY-LEN          BINARY-LONG.
01 UPPER-AZ          PIC X(26) VALUE "ABCDEFGHIJKLMNOPQRSTUVWXYZ".
01 LOWER-AZ          PIC X(26) VALUE "abcdefghijklmnopqrstuvwxyz".

*> hex digit values (-1 for any other byte), and the same times 16; index byte + 1
01 HEX-TABLES.
   05 HEX-VAL        BINARY-LONG OCCURS 256.
   05 HEX-HI         BINARY-LONG OCCURS 256.
01 HEX-DIGITS        PIC X(22) VALUE "0123456789abcdefABCDEF".

*> ---------- path segments after /api, percent-decoded ----------
01 SEG-OK            BINARY-LONG.
01 NSEG              BINARY-LONG.
01 SEG-TABLE.
   05 SEG-OFF        BINARY-LONG OCCURS 5.
   05 SEG-LEN        BINARY-LONG OCCURS 5.
01 SEGBUF            PIC X(65536).
01 PATH-END          BINARY-LONG.
01 ROUTE             BINARY-LONG.
*> authentication: 0 no header, 1 invalid, 2 a valid token (VIEWER-ID, the token at TOK-OFF in IN-BUF)
01 AUTH-RESULT       BINARY-LONG.
01 TOK-OFF           BINARY-LONG.
01 TOK-LEN           BINARY-LONG.
01 VIEWER-ID         BINARY-DOUBLE.

*> ---------- query parameters, decoded like Go's url.ParseQuery ----------
01 QP-I              BINARY-LONG.
01 QP-END            BINARY-LONG.
01 QP-PS             BINARY-LONG.
01 QP-PE             BINARY-LONG.
01 QP-EQ             BINARY-LONG.
01 QP-SEMI           BINARY-LONG.
01 QP-WHICH          BINARY-LONG.
*> unescape: UE-OFF/UE-LEN in IN-BUF into SEGBUF or QBUF at UE-OUT; UE-OK = 0 on a malformed escape
01 UE-OFF            BINARY-LONG.
01 UE-LEN            BINARY-LONG.
01 UE-END            BINARY-LONG.
01 UE-OK             BINARY-LONG.
01 UE-OUT            BINARY-LONG.
01 UE-I              BINARY-LONG.
01 QKEY              PIC X(16).
01 QKEY-LEN          BINARY-LONG.
01 QBUF              PIC X(65536).
01 QB-LEN            BINARY-LONG.
*> per key (1 limit, 2 offset, 3 tag, 4 author, 5 favorited): seen, and the value in QBUF
01 QV-TABLE.
   05 QV-SET         BINARY-LONG OCCURS 5.
   05 QV-OFF         BINARY-LONG OCCURS 5.
   05 QV-LEN         BINARY-LONG OCCURS 5.
01 LIMIT-TXT         PIC X(20).
01 LIMIT-LEN         BINARY-LONG.
01 OFFSET-TXT        PIC X(20).
01 OFFSET-LEN        BINARY-LONG.
01 LO-OK             BINARY-LONG.
*> an unsigned integer in QBUF (UI-OFF:UI-LEN): UI-OK, and the digits without leading zeros at UI-SKIP
01 UI-OFF            BINARY-LONG.
01 UI-LEN            BINARY-LONG.
01 UI-OK             BINARY-LONG.
01 UI-SKIP           BINARY-LONG.
01 UI-I              BINARY-LONG.
