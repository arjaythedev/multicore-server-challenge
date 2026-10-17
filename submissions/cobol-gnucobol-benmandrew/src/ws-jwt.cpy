*> ---------- jwt: base64url and HS256 tokens ----------
*> JWT-VERIFY: the token IN-BUF (TOK-OFF:TOK-LEN), checked at NOW-SEC; JWT-OK 1/0, and VIEWER-ID when it is 1.
*> JWT-SIGN: JW-SUB, signed at NOW-SEC; the token in JW-TOKEN (1:JW-TOKEN-LEN).
01 JWT-OK            BINARY-LONG.
01 JW-SUB            BINARY-DOUBLE.
01 JW-TOKEN          PIC X(512).
01 JW-TOKEN-LEN      BINARY-LONG.

*> base64url of {"alg":"HS256","typ":"JWT"}
01 JW-HDR            PIC X(36) VALUE "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9".
01 JW-K-DOT          PIC X VALUE ".".
01 JW-K-P1           PIC X(8) VALUE '{"sub":"'.
01 JW-K-P2           PIC X(8) VALUE '","iat":'.
01 JW-K-P3           PIC X(7) VALUE ',"exp":'.
01 JW-K-P4           PIC X VALUE '}'.
01 JW-K-HS256        PIC X(5) VALUE "HS256".
01 JW-K-32-D         BINARY-DOUBLE VALUE 32.
01 JW-K-64-D         BINARY-DOUBLE VALUE 64.
01 JW-K-64           BINARY-LONG VALUE 64.
01 JW-K-FMT-LF       PIC X(4) VALUE Z"%lf".

*> ---------- base64url ----------
01 JW-URL            PIC X(64)
    VALUE "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".
*> Per byte (index byte + 1), the pieces of each output sextet, so encoding is table lookups and additions:
*> sextet 1 = JW-E0 (b0); 2 = JW-E1A (b0) + JW-E1B (b1); 3 = JW-E2A (b1) + JW-E2B (b2); 4 = JW-E3 (b2).
*> JW-E0, JW-E1A, JW-E2A and JW-E3 include the + 1 for the position in JW-URL.
01 JW-ENC-TABLE.
   05 JW-ENC-E OCCURS 256.
      10 JW-E0       BINARY-LONG.
      10 JW-E1A      BINARY-LONG.
      10 JW-E1B      BINARY-LONG.
      10 JW-E2A      BINARY-LONG.
      10 JW-E2B      BINARY-LONG.
      10 JW-E3       BINARY-LONG.
*> Per input character (index byte + 1): its sextet v, -1 if not in the alphabet, and the pieces of the output
*> bytes: byte 1 = v0 * 4 + v1 / 16; byte 2 = (v1 mod 16) * 16 + v2 / 4; byte 3 = (v2 mod 4) * 64 + v3.
01 JW-DEC-TABLE.
   05 JW-DEC-E OCCURS 256.
      10 JW-DV       BINARY-LONG.
      10 JW-D0       BINARY-LONG.
      10 JW-D1H      BINARY-LONG.
      10 JW-D1L      BINARY-LONG.
      10 JW-D2H      BINARY-LONG.
      10 JW-D2L      BINARY-LONG.
01 JW-C0             BINARY-CHAR UNSIGNED.
01 JW-C0X REDEFINES JW-C0 PIC X.
01 JW-C1             BINARY-CHAR UNSIGNED.
01 JW-C1X REDEFINES JW-C1 PIC X.
01 JW-C2             BINARY-CHAR UNSIGNED.
01 JW-C2X REDEFINES JW-C2 PIC X.
01 JW-C3             BINARY-CHAR UNSIGNED.
01 JW-C3X REDEFINES JW-C3 PIC X.
*> an output byte is the low byte of JW-W
01 JW-W              BINARY-LONG.
01 JW-W-X REDEFINES JW-W PIC X(4).
01 JW-I              BINARY-LONG.
01 JW-O              BINARY-LONG.
01 JW-REM            BINARY-LONG.
*> JW-ENCODE: JW-ESRC (1:JW-ESRC-LEN) appended to JW-TOKEN
01 JW-ESRC           PIC X(128).
01 JW-ESRC-LEN       BINARY-LONG.
*> JW-DECODE: IN-BUF (JW-B-OFF:JW-B-LEN) into L-JW-DST; JW-B-OK, JW-B-OUT-LEN
01 JW-B-OFF          BINARY-LONG.
01 JW-B-LEN          BINARY-LONG.
01 JW-B-OK           BINARY-LONG.
01 JW-B-OUT-LEN      BINARY-LONG.
*> decoded header, payload and signature (a token is at most IN-BUF's 1 MB)
01 JW-HJ             PIC X(786432).
01 JW-HJ-LEN         BINARY-LONG.
01 JW-PJ             PIC X(786432).
01 JW-PJ-LEN         BINARY-LONG.
01 JW-SG             PIC X(786432).
01 JW-SG-LEN         BINARY-LONG.

*> ---------- HMAC-SHA256 ----------
*> SHA256_CTX states: after the inner pad block, after the outer pad block, and the one being used
01 JW-ICTX           PIC X(112).
01 JW-OCTX           PIC X(112).
01 JW-CTX            PIC X(112).
01 JW-KEY            PIC X(64).
01 JW-PAD            PIC X(64).
01 JW-XOR            PIC X(64).
01 JW-MD             PIC X(32).
01 JW-MAC            PIC X(32).
01 JW-SZ             BINARY-DOUBLE.
01 JW-RC             BINARY-LONG.

*> ---------- verify ----------
01 JW-TE             BINARY-LONG.
01 JW-D1             BINARY-LONG.
01 JW-D2             BINARY-LONG.
01 JW-NDOT           BINARY-LONG.
01 JW-T              BINARY-LONG.
*> own payload: JW-OWN-OK, the sub and exp digits in JW-PJ
01 JW-OWN-OK         BINARY-LONG.
01 JW-SUB-OFF        BINARY-LONG.
01 JW-SUB-LEN        BINARY-LONG.
01 JW-EXP-OFF        BINARY-LONG.
01 JW-EXP-LEN        BINARY-LONG.
01 JW-DS             BINARY-LONG.
01 JW-DL             BINARY-LONG.
*> JW-UINT: JW-DIG (1:JW-DIG-LEN), 1 to 18 digits, to VIEWER-ID; JW-UINT-OK = 0 if not digits or zero
01 JW-DIG            PIC X(18).
01 JW-DIG-LEN        BINARY-LONG.
01 JW-UINT-OK        BINARY-LONG.
01 JW-V              BINARY-LONG.
01 JW-K              BINARY-LONG.
01 JW-BV             BINARY-CHAR UNSIGNED.
01 JW-BX REDEFINES JW-BV PIC X.
*> JW-P10 (k, d + 1) = d * 10 ** (k - 1), for the digit k places from the right
01 JW-P10-TABLE.
   05 JW-P10-ROW OCCURS 9.
      10 JW-P10      BINARY-LONG OCCURS 10.
01 JW-BIG            PIC 9(18).
*> general path: claim JW-NUM-K as a double, compared with NOW-SEC + 1 by bit pattern
01 JW-NUM-K          BINARY-LONG.
01 JW-NUMZ           PIC X(786433).
01 JW-F              COMP-2.
01 JW-F-BITS REDEFINES JW-F BINARY-DOUBLE.
01 JW-N1             COMP-2.
01 JW-N1-BITS REDEFINES JW-N1 BINARY-DOUBLE.
*> JW-GE: 1 if the claim >= NOW-SEC + 1; JW-NAN: 1 if it is NaN
01 JW-GE             BINARY-LONG.
01 JW-NAN            BINARY-LONG.
