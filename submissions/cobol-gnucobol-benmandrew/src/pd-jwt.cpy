*> ================= jwt: base64url and HS256 tokens =================
*> Tokens are accepted by the rules of golang-jwt/v5 with HS256 as the only method and exp required. A token with
*> this server's header and payload is read by hand; any other goes through JI-PARSE. Signing and the fast path
*> are native apart from the libcrypto calls.

*> Start-up: base64url tables and digit place values.
INIT-JWT-TABLES.
    PERFORM VARYING JW-K FROM 0 BY 1 UNTIL JW-K > 255
        COMPUTE JW-E0 (JW-K + 1) = JW-K / 4 + 1
        COMPUTE JW-E1A (JW-K + 1) = FUNCTION MOD (JW-K, 4) * 16 + 1
        COMPUTE JW-E1B (JW-K + 1) = JW-K / 16
        COMPUTE JW-E2A (JW-K + 1) = FUNCTION MOD (JW-K, 16) * 4 + 1
        COMPUTE JW-E2B (JW-K + 1) = JW-K / 64
        COMPUTE JW-E3 (JW-K + 1) = FUNCTION MOD (JW-K, 64) + 1
        MOVE -1 TO JW-DV (JW-K + 1)
        MOVE 0 TO JW-D0 (JW-K + 1) JW-D1H (JW-K + 1) JW-D1L (JW-K + 1) JW-D2H (JW-K + 1) JW-D2L (JW-K + 1)
    END-PERFORM
    PERFORM VARYING JW-K FROM 0 BY 1 UNTIL JW-K > 63
        MOVE JW-URL (JW-K + 1:1) TO JW-BX
        COMPUTE JW-I = JW-BV + 1
        MOVE JW-K TO JW-DV (JW-I)
        COMPUTE JW-D0 (JW-I) = JW-K * 4
        COMPUTE JW-D1H (JW-I) = JW-K / 16
        COMPUTE JW-D1L (JW-I) = FUNCTION MOD (JW-K, 16) * 16
        COMPUTE JW-D2H (JW-I) = JW-K / 4
        COMPUTE JW-D2L (JW-I) = FUNCTION MOD (JW-K, 4) * 64
    END-PERFORM
    PERFORM VARYING JW-K FROM 1 BY 1 UNTIL JW-K > 9
        PERFORM VARYING JW-I FROM 1 BY 1 UNTIL JW-I > 10
            COMPUTE JW-P10 (JW-K, JW-I) = (JW-I - 1) * 10 ** (JW-K - 1)
        END-PERFORM
    END-PERFORM.

*> In each worker: the SHA-256 states after the key's inner and outer pad blocks.
HMAC-INIT.
    MOVE LOW-VALUES TO JW-KEY
    IF JWT-SECRET-LEN > 64
        MOVE 0 TO JW-SZ
        ADD JWT-SECRET-LEN TO JW-SZ
        CALL "SHA256" USING BY REFERENCE JWT-SECRET BY VALUE JW-SZ BY REFERENCE JW-KEY
    ELSE
        IF JWT-SECRET-LEN > 0
            MOVE JWT-SECRET (1:JWT-SECRET-LEN) TO JW-KEY (1:JWT-SECRET-LEN)
        END-IF
    END-IF
    MOVE JW-KEY TO JW-PAD
    MOVE ALL X"36" TO JW-XOR
    CALL "CBL_XOR" USING JW-XOR JW-PAD BY VALUE JW-K-64
    CALL "SHA256_Init" USING BY REFERENCE JW-ICTX
    CALL "SHA256_Update" USING BY REFERENCE JW-ICTX BY REFERENCE JW-PAD BY VALUE JW-K-64-D
    MOVE JW-KEY TO JW-PAD
    MOVE ALL X"5C" TO JW-XOR
    CALL "CBL_XOR" USING JW-XOR JW-PAD BY VALUE JW-K-64
    CALL "SHA256_Init" USING BY REFERENCE JW-OCTX
    CALL "SHA256_Update" USING BY REFERENCE JW-OCTX BY REFERENCE JW-PAD BY VALUE JW-K-64-D.

*> The caller has copied JW-ICTX to JW-CTX and fed it the message: JW-MAC = the HMAC.
JW-HMAC-FINISH.
    CALL "SHA256_Final" USING BY REFERENCE JW-MD BY REFERENCE JW-CTX
    MOVE JW-OCTX TO JW-CTX
    CALL "SHA256_Update" USING BY REFERENCE JW-CTX BY REFERENCE JW-MD BY VALUE JW-K-32-D
    CALL "SHA256_Final" USING BY REFERENCE JW-MAC BY REFERENCE JW-CTX.

*> ---------- sign ----------

*> {"sub":"<JW-SUB>","iat":<now>,"exp":<now + 30 days>} under this server's header.
JWT-SIGN.
    MOVE JW-HDR TO JW-TOKEN (1:36)
    MOVE JW-K-DOT TO JW-TOKEN (37:1)
    MOVE 37 TO JW-TOKEN-LEN
    MOVE JW-K-P1 TO JW-ESRC (1:8)
    MOVE 8 TO JW-ESRC-LEN
    MOVE JW-SUB TO JO-D
    PERFORM JO-FMT-D
    PERFORM JW-ADD-NUM
    MOVE JW-K-P2 TO JW-ESRC (JW-ESRC-LEN + 1:8)
    ADD 8 TO JW-ESRC-LEN
    MOVE NOW-SEC TO JO-D
    PERFORM JO-FMT-D
    PERFORM JW-ADD-NUM
    MOVE JW-K-P3 TO JW-ESRC (JW-ESRC-LEN + 1:7)
    ADD 7 TO JW-ESRC-LEN
    MOVE NOW-SEC TO JO-D
    ADD 2592000 TO JO-D
    PERFORM JO-FMT-D
    PERFORM JW-ADD-NUM
    MOVE JW-K-P4 TO JW-ESRC (JW-ESRC-LEN + 1:1)
    ADD 1 TO JW-ESRC-LEN
    PERFORM JW-ENCODE
    MOVE JW-ICTX TO JW-CTX
    MOVE 0 TO JW-SZ
    ADD JW-TOKEN-LEN TO JW-SZ
    CALL "SHA256_Update" USING BY REFERENCE JW-CTX BY REFERENCE JW-TOKEN BY VALUE JW-SZ
    PERFORM JW-HMAC-FINISH
    MOVE JW-K-DOT TO JW-TOKEN (JW-TOKEN-LEN + 1:1)
    ADD 1 TO JW-TOKEN-LEN
    MOVE JW-MAC TO JW-ESRC (1:32)
    MOVE 32 TO JW-ESRC-LEN
    PERFORM JW-ENCODE.

JW-ADD-NUM.
    MOVE JO-NUM (JO-NUM-OFF:JO-NUM-LEN) TO JW-ESRC (JW-ESRC-LEN + 1:JO-NUM-LEN)
    ADD JO-NUM-LEN TO JW-ESRC-LEN.

*> base64url without padding of JW-ESRC (1:JW-ESRC-LEN), appended to JW-TOKEN.
JW-ENCODE.
    MOVE 1 TO JW-I
    MOVE JW-ESRC-LEN TO JW-REM
    PERFORM UNTIL JW-REM < 3
        MOVE JW-ESRC (JW-I:1) TO JW-C0X
        MOVE JW-ESRC (JW-I + 1:1) TO JW-C1X
        MOVE JW-ESRC (JW-I + 2:1) TO JW-C2X
        MOVE JW-E0 (JW-C0 + 1) TO JW-W
        MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 1:1)
        MOVE JW-E1A (JW-C0 + 1) TO JW-W
        ADD JW-E1B (JW-C1 + 1) TO JW-W
        MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 2:1)
        MOVE JW-E2A (JW-C1 + 1) TO JW-W
        ADD JW-E2B (JW-C2 + 1) TO JW-W
        MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 3:1)
        MOVE JW-E3 (JW-C2 + 1) TO JW-W
        MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 4:1)
        ADD 4 TO JW-TOKEN-LEN
        ADD 3 TO JW-I
        SUBTRACT 3 FROM JW-REM
    END-PERFORM
    EVALUATE JW-REM
        WHEN 1
            MOVE JW-ESRC (JW-I:1) TO JW-C0X
            MOVE JW-E0 (JW-C0 + 1) TO JW-W
            MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 1:1)
            MOVE JW-E1A (JW-C0 + 1) TO JW-W
            MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 2:1)
            ADD 2 TO JW-TOKEN-LEN
        WHEN 2
            MOVE JW-ESRC (JW-I:1) TO JW-C0X
            MOVE JW-ESRC (JW-I + 1:1) TO JW-C1X
            MOVE JW-E0 (JW-C0 + 1) TO JW-W
            MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 1:1)
            MOVE JW-E1A (JW-C0 + 1) TO JW-W
            ADD JW-E1B (JW-C1 + 1) TO JW-W
            MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 2:1)
            MOVE JW-E2A (JW-C1 + 1) TO JW-W
            MOVE JW-URL (JW-W:1) TO JW-TOKEN (JW-TOKEN-LEN + 3:1)
            ADD 3 TO JW-TOKEN-LEN
    END-EVALUATE.

*> ---------- verify ----------

*> IN-BUF (TOK-OFF:TOK-LEN): JWT-OK, and VIEWER-ID when it is 1.
JWT-VERIFY.
    MOVE 0 TO JWT-OK
    MOVE TOK-OFF TO JW-TE
    ADD TOK-LEN TO JW-TE
    IF TOK-LEN >= 37
        IF IN-BUF (TOK-OFF:36) = JW-HDR AND IN-BUF (TOK-OFF + 36:1) = JW-K-DOT
            PERFORM JW-FAST
            EXIT PARAGRAPH
        END-IF
    END-IF
    PERFORM JW-GENERAL.

*> This server's header (so alg is HS256). The payload and signature must decode; a payload in the format
*> JWT-SIGN writes is read here, any other takes the general path.
JW-FAST.
    MOVE TOK-OFF TO JW-D1
    ADD 36 TO JW-D1
    MOVE JW-D1 TO JW-D2
    ADD 1 TO JW-D2
    PERFORM UNTIL JW-D2 >= JW-TE
        IF IN-BUF (JW-D2:1) = JW-K-DOT
            EXIT PERFORM
        END-IF
        ADD 1 TO JW-D2
    END-PERFORM
    IF JW-D2 >= JW-TE
        EXIT PARAGRAPH
    END-IF
    PERFORM JW-DECODE-PS
    IF JW-B-OK = 0
        EXIT PARAGRAPH
    END-IF
    PERFORM JW-OWN
    IF JW-OWN-OK = 0
        PERFORM JW-GENERAL
        EXIT PARAGRAPH
    END-IF
    PERFORM JW-MAC-CHECK
    IF JW-RC NOT = 0
        EXIT PARAGRAPH
    END-IF
    *> now < exp, compared as digit strings (exp has no leading zero)
    MOVE NOW-SEC TO JO-D
    PERFORM JO-FMT-D
    IF JO-NUM-LEN > JW-EXP-LEN
        EXIT PARAGRAPH
    END-IF
    IF JO-NUM-LEN = JW-EXP-LEN
        *> byte by byte (a compare of variable-length fields is a libcob call): expired when equal or when
        *> now's first differing digit is the greater
        MOVE JW-EXP-OFF TO JW-I
        PERFORM VARYING JW-K FROM JO-NUM-OFF BY 1 UNTIL JW-K > 20
            IF JO-NUM (JW-K:1) NOT = JW-PJ (JW-I:1)
                EXIT PERFORM
            END-IF
            ADD 1 TO JW-I
        END-PERFORM
        IF JW-K > 20
            EXIT PARAGRAPH
        END-IF
        IF JO-NUM (JW-K:1) > JW-PJ (JW-I:1)
            EXIT PARAGRAPH
        END-IF
    END-IF
    MOVE JW-PJ (JW-SUB-OFF:JW-SUB-LEN) TO JW-DIG (1:JW-SUB-LEN)
    MOVE JW-SUB-LEN TO JW-DIG-LEN
    PERFORM JW-UINT
    MOVE JW-UINT-OK TO JWT-OK.

*> JW-PJ is exactly {"sub":"<digits>","iat":<digits>,"exp":<digits>}, each 1 to 15 digits not starting with 0:
*> JW-OWN-OK, JW-SUB-OFF/LEN, JW-EXP-OFF/LEN.
JW-OWN.
    MOVE 0 TO JW-OWN-OK
    IF JW-PJ-LEN < 8
        EXIT PARAGRAPH
    END-IF
    IF JW-PJ (1:8) NOT = JW-K-P1
        EXIT PARAGRAPH
    END-IF
    MOVE 9 TO JW-DS
    PERFORM JW-DIGITS
    IF JW-DL = 0
        EXIT PARAGRAPH
    END-IF
    MOVE JW-DS TO JW-SUB-OFF
    MOVE JW-DL TO JW-SUB-LEN
    MOVE JW-I TO JW-T
    ADD 7 TO JW-T
    IF JW-T > JW-PJ-LEN
        EXIT PARAGRAPH
    END-IF
    IF JW-PJ (JW-I:8) NOT = JW-K-P2
        EXIT PARAGRAPH
    END-IF
    MOVE JW-I TO JW-DS
    ADD 8 TO JW-DS
    PERFORM JW-DIGITS
    IF JW-DL = 0
        EXIT PARAGRAPH
    END-IF
    MOVE JW-I TO JW-T
    ADD 6 TO JW-T
    IF JW-T > JW-PJ-LEN
        EXIT PARAGRAPH
    END-IF
    IF JW-PJ (JW-I:7) NOT = JW-K-P3
        EXIT PARAGRAPH
    END-IF
    MOVE JW-I TO JW-DS
    ADD 7 TO JW-DS
    PERFORM JW-DIGITS
    IF JW-DL = 0
        EXIT PARAGRAPH
    END-IF
    MOVE JW-DS TO JW-EXP-OFF
    MOVE JW-DL TO JW-EXP-LEN
    IF JW-I NOT = JW-PJ-LEN
        EXIT PARAGRAPH
    END-IF
    IF JW-PJ (JW-I:1) NOT = JW-K-P4
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO JW-OWN-OK.

*> The digits at JW-PJ (JW-DS): JW-I one past them, JW-DL their count, or 0 if none, more than 15 or a leading 0.
JW-DIGITS.
    MOVE JW-DS TO JW-I
    PERFORM UNTIL JW-I > JW-PJ-LEN
        IF JW-PJ (JW-I:1) < "0" OR JW-PJ (JW-I:1) > "9"
            EXIT PERFORM
        END-IF
        ADD 1 TO JW-I
    END-PERFORM
    MOVE JW-I TO JW-DL
    SUBTRACT JW-DS FROM JW-DL
    IF JW-DL > 15
        MOVE 0 TO JW-DL
    END-IF
    IF JW-DL > 0
        IF JW-PJ (JW-DS:1) = "0"
            MOVE 0 TO JW-DL
        END-IF
    END-IF.

*> JW-DIG (1:JW-DIG-LEN) is 1 to 18 ASCII digits with a value above 0, which goes to VIEWER-ID.
*> Up to 9 significant digits are summed from place values; more take decimal arithmetic.
JW-UINT.
    MOVE 0 TO JW-UINT-OK
    IF JW-DIG-LEN < 1 OR JW-DIG-LEN > 18
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING JW-I FROM 1 BY 1 UNTIL JW-I > JW-DIG-LEN
        IF JW-DIG (JW-I:1) < "0" OR JW-DIG (JW-I:1) > "9"
            EXIT PARAGRAPH
        END-IF
    END-PERFORM
    MOVE 1 TO JW-DS
    PERFORM UNTIL JW-DS > JW-DIG-LEN
        IF JW-DIG (JW-DS:1) NOT = "0"
            EXIT PERFORM
        END-IF
        ADD 1 TO JW-DS
    END-PERFORM
    IF JW-DS > JW-DIG-LEN
        EXIT PARAGRAPH
    END-IF
    MOVE JW-DIG-LEN TO JW-DL
    SUBTRACT JW-DS FROM JW-DL
    ADD 1 TO JW-DL
    IF JW-DL <= 9
        MOVE 0 TO JW-V
        MOVE JW-DL TO JW-K
        PERFORM VARYING JW-I FROM JW-DS BY 1 UNTIL JW-I > JW-DIG-LEN
            MOVE JW-DIG (JW-I:1) TO JW-BX
            MOVE 0 TO JW-T
            ADD JW-BV TO JW-T
            SUBTRACT 47 FROM JW-T
            ADD JW-P10 (JW-K, JW-T) TO JW-V
            SUBTRACT 1 FROM JW-K
        END-PERFORM
        MOVE 0 TO VIEWER-ID
        ADD JW-V TO VIEWER-ID
    ELSE
        MOVE 0 TO JW-BIG
        PERFORM VARYING JW-I FROM JW-DS BY 1 UNTIL JW-I > JW-DIG-LEN
            MOVE JW-DIG (JW-I:1) TO JW-BX
            COMPUTE JW-BIG = JW-BIG * 10 + JW-BV - 48
        END-PERFORM
        MOVE JW-BIG TO VIEWER-ID
    END-IF
    MOVE 1 TO JW-UINT-OK.

*> JW-MAC = HMAC of the header and payload, IN-BUF from TOK-OFF up to the second dot at JW-D2; JW-RC = 0 if it
*> equals the decoded signature JW-SG, in constant time.
JW-MAC-CHECK.
    MOVE JW-ICTX TO JW-CTX
    MOVE 0 TO JW-SZ
    ADD JW-D2 TO JW-SZ
    SUBTRACT TOK-OFF FROM JW-SZ
    CALL "SHA256_Update" USING BY REFERENCE JW-CTX BY REFERENCE IN-BUF (TOK-OFF:1) BY VALUE JW-SZ
    PERFORM JW-HMAC-FINISH
    MOVE 1 TO JW-RC
    IF JW-SG-LEN = 32
        CALL "CRYPTO_memcmp" USING BY REFERENCE JW-MAC BY REFERENCE JW-SG BY VALUE JW-K-32-D RETURNING JW-RC
    END-IF.

*> The payload, between the dots at JW-D1 and JW-D2, into JW-PJ, and the signature, from JW-D2 to the token's end
*> at JW-TE, into JW-SG: JW-B-OK, JW-PJ-LEN, JW-SG-LEN.
JW-DECODE-PS.
    SET ADDRESS OF L-JW-DST TO ADDRESS OF JW-PJ
    MOVE JW-D1 TO JW-B-OFF
    ADD 1 TO JW-B-OFF
    MOVE JW-D2 TO JW-B-LEN
    SUBTRACT JW-B-OFF FROM JW-B-LEN
    PERFORM JW-DECODE
    IF JW-B-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE JW-B-OUT-LEN TO JW-PJ-LEN
    SET ADDRESS OF L-JW-DST TO ADDRESS OF JW-SG
    MOVE JW-D2 TO JW-B-OFF
    ADD 1 TO JW-B-OFF
    MOVE JW-TE TO JW-B-LEN
    SUBTRACT JW-B-OFF FROM JW-B-LEN
    PERFORM JW-DECODE
    MOVE JW-B-OUT-LEN TO JW-SG-LEN.

*> base64url of IN-BUF (JW-B-OFF:JW-B-LEN) into L-JW-DST: no padding, no other characters, a length of 4n + 1
*> rejected, unused trailing bits ignored (as Go's non-strict decoder). JW-B-OK, JW-B-OUT-LEN.
JW-DECODE.
    MOVE 0 TO JW-B-OK JW-O
    MOVE JW-B-OFF TO JW-I
    MOVE JW-B-LEN TO JW-REM
    PERFORM UNTIL JW-REM < 4
        MOVE IN-BUF (JW-I:1) TO JW-C0X
        MOVE IN-BUF (JW-I + 1:1) TO JW-C1X
        MOVE IN-BUF (JW-I + 2:1) TO JW-C2X
        MOVE IN-BUF (JW-I + 3:1) TO JW-C3X
        IF JW-DV (JW-C0 + 1) < 0 OR JW-DV (JW-C1 + 1) < 0 OR JW-DV (JW-C2 + 1) < 0 OR JW-DV (JW-C3 + 1) < 0
            EXIT PARAGRAPH
        END-IF
        MOVE JW-D0 (JW-C0 + 1) TO JW-W
        ADD JW-D1H (JW-C1 + 1) TO JW-W
        MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 1:1)
        MOVE JW-D1L (JW-C1 + 1) TO JW-W
        ADD JW-D2H (JW-C2 + 1) TO JW-W
        MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 2:1)
        MOVE JW-D2L (JW-C2 + 1) TO JW-W
        ADD JW-DV (JW-C3 + 1) TO JW-W
        MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 3:1)
        ADD 3 TO JW-O
        ADD 4 TO JW-I
        SUBTRACT 4 FROM JW-REM
    END-PERFORM
    EVALUATE JW-REM
        WHEN 1
            EXIT PARAGRAPH
        WHEN 2
            MOVE IN-BUF (JW-I:1) TO JW-C0X
            MOVE IN-BUF (JW-I + 1:1) TO JW-C1X
            IF JW-DV (JW-C0 + 1) < 0 OR JW-DV (JW-C1 + 1) < 0
                EXIT PARAGRAPH
            END-IF
            MOVE JW-D0 (JW-C0 + 1) TO JW-W
            ADD JW-D1H (JW-C1 + 1) TO JW-W
            MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 1:1)
            ADD 1 TO JW-O
        WHEN 3
            MOVE IN-BUF (JW-I:1) TO JW-C0X
            MOVE IN-BUF (JW-I + 1:1) TO JW-C1X
            MOVE IN-BUF (JW-I + 2:1) TO JW-C2X
            IF JW-DV (JW-C0 + 1) < 0 OR JW-DV (JW-C1 + 1) < 0 OR JW-DV (JW-C2 + 1) < 0
                EXIT PARAGRAPH
            END-IF
            MOVE JW-D0 (JW-C0 + 1) TO JW-W
            ADD JW-D1H (JW-C1 + 1) TO JW-W
            MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 1:1)
            MOVE JW-D1L (JW-C1 + 1) TO JW-W
            ADD JW-D2H (JW-C2 + 1) TO JW-W
            MOVE JW-W-X (1:1) TO L-JW-DST (JW-O + 2:1)
            ADD 2 TO JW-O
    END-EVALUATE
    MOVE JW-O TO JW-B-OUT-LEN
    MOVE 1 TO JW-B-OK.

*> Any other token: exactly three parts, each valid base64url; header alg "HS256"; the MAC; claims an object
*> with exp a number and now < trunc (exp), nbf absent, null or a number with now >= trunc (nbf), iat absent,
*> null or a number, and sub a string of 1 to 18 digits above 0.
JW-GENERAL.
    MOVE 0 TO JW-NDOT
    PERFORM VARYING JW-I FROM TOK-OFF BY 1 UNTIL JW-I >= JW-TE
        IF IN-BUF (JW-I:1) = JW-K-DOT
            ADD 1 TO JW-NDOT
            EVALUATE JW-NDOT
                WHEN 1
                    MOVE JW-I TO JW-D1
                WHEN 2
                    MOVE JW-I TO JW-D2
                WHEN OTHER
                    EXIT PARAGRAPH
            END-EVALUATE
        END-IF
    END-PERFORM
    IF JW-NDOT NOT = 2
        EXIT PARAGRAPH
    END-IF
    SET ADDRESS OF L-JW-DST TO ADDRESS OF JW-HJ
    MOVE TOK-OFF TO JW-B-OFF
    MOVE JW-D1 TO JW-B-LEN
    SUBTRACT TOK-OFF FROM JW-B-LEN
    PERFORM JW-DECODE
    IF JW-B-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE JW-B-OUT-LEN TO JW-HJ-LEN
    PERFORM JW-DECODE-PS
    IF JW-B-OK = 0
        EXIT PARAGRAPH
    END-IF
    *> header
    SET ADDRESS OF L-JSRC TO ADDRESS OF JW-HJ
    MOVE 2 TO JI-MODE
    MOVE 1 TO JI-SRC-OFF
    MOVE JW-HJ-LEN TO JI-SRC-LEN
    PERFORM JI-PARSE
    IF JI-OK = 0 OR JI-TOP-OBJ = 0 OR JF-T (10) NOT = 2 OR JF-LEN (10) NOT = 5
        EXIT PARAGRAPH
    END-IF
    IF JI-BUF (JF-OFF (10):5) NOT = JW-K-HS256
        EXIT PARAGRAPH
    END-IF
    PERFORM JW-MAC-CHECK
    IF JW-RC NOT = 0
        EXIT PARAGRAPH
    END-IF
    *> claims
    SET ADDRESS OF L-JSRC TO ADDRESS OF JW-PJ
    MOVE 3 TO JI-MODE
    MOVE 1 TO JI-SRC-OFF
    MOVE JW-PJ-LEN TO JI-SRC-LEN
    PERFORM JI-PARSE
    IF JI-OK = 0 OR JI-TOP-OBJ = 0
        EXIT PARAGRAPH
    END-IF
    IF JF-T (11) NOT = 5
        EXIT PARAGRAPH
    END-IF
    MOVE 11 TO JW-NUM-K
    PERFORM JW-NUM-CMP
    IF JW-NAN = 1 OR JW-GE = 0
        EXIT PARAGRAPH
    END-IF
    EVALUATE JF-T (12)
        WHEN 0
        WHEN 1
            CONTINUE
        WHEN 5
            MOVE 12 TO JW-NUM-K
            PERFORM JW-NUM-CMP
            IF JW-NAN = 1 OR JW-GE = 1
                EXIT PARAGRAPH
            END-IF
        WHEN OTHER
            EXIT PARAGRAPH
    END-EVALUATE
    IF JF-T (13) NOT = 0 AND JF-T (13) NOT = 1 AND JF-T (13) NOT = 5
        EXIT PARAGRAPH
    END-IF
    IF JF-T (14) NOT = 2 OR JF-LEN (14) < 1 OR JF-LEN (14) > 18
        EXIT PARAGRAPH
    END-IF
    MOVE JI-BUF (JF-OFF (14):JF-LEN (14)) TO JW-DIG (1:JF-LEN (14))
    MOVE JF-LEN (14) TO JW-DIG-LEN
    PERFORM JW-UINT
    MOVE JW-UINT-OK TO JWT-OK.

*> Claim JW-NUM-K (a number's text, or NaN / Infinity / -Infinity) read as a double by sscanf (strtod).
*> now < trunc (x) holds exactly when x >= now + 1, and for doubles that are not
*> NaN, x >= y with y > 0 holds exactly when x's bit pattern, as a signed integer, is >= y's.
JW-NUM-CMP.
    MOVE JF-LEN (JW-NUM-K) TO JW-T
    MOVE JI-BUF (JF-OFF (JW-NUM-K):JW-T) TO JW-NUMZ (1:JW-T)
    MOVE X"00" TO JW-NUMZ (JW-T + 1:1)
    MOVE 0 TO JW-F-BITS
    CALL "sscanf" USING BY REFERENCE JW-NUMZ BY REFERENCE JW-K-FMT-LF BY REFERENCE JW-F RETURNING JW-RC
    COMPUTE JW-N1 = NOW-SEC + 1
    MOVE 0 TO JW-NAN JW-GE
    IF JW-F-BITS > 9218868437227405312 OR (JW-F-BITS > -4503599627370496 AND JW-F-BITS < 0)
        MOVE 1 TO JW-NAN
    END-IF
    IF JW-F-BITS >= JW-N1-BITS
        MOVE 1 TO JW-GE
    END-IF.
