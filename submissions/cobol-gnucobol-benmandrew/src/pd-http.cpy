*> ================= HTTP =================

INIT-HTTP-TABLES.
    PERFORM VARYING HI FROM 1 BY 1 UNTIL HI > 256
        MOVE -1 TO HEX-VAL (HI)
        MOVE -1 TO HEX-HI (HI)
    END-PERFORM
    PERFORM VARYING HI FROM 1 BY 1 UNTIL HI > 22
        MOVE HEX-DIGITS (HI:1) TO BYTE-X
        IF HI <= 16
            COMPUTE HEX-VAL (BYTE-V + 1) = HI - 1
        ELSE
            COMPUTE HEX-VAL (BYTE-V + 1) = HI - 7
        END-IF
        COMPUTE HEX-HI (BYTE-V + 1) = HEX-VAL (BYTE-V + 1) * 16
    END-PERFORM.

*> Parses the request at IN-POS: request line, the headers this server reads (Authorization, Content-Length,
*> Connection) and the body. Sets REQ-STATE, and REQ-NEXT to the byte after the request.
PARSE-REQUEST.
    MOVE 0 TO REQ-STATE REQ-CLOSE AUTH-SET CLEN BODY-LEN
    MOVE IN-POS TO REQ-START
    MOVE IN-LEN TO REQ-REM
    SUBTRACT REQ-START FROM REQ-REM
    ADD 1 TO REQ-REM
    *> one empty line before a request is skipped
    IF REQ-REM >= 2
        IF IN-BUF (REQ-START:2) = X"0D0A"
            ADD 2 TO REQ-START
            SUBTRACT 2 FROM REQ-REM
        END-IF
    END-IF
    IF REQ-REM < 4
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO HDR-CNT
    INSPECT IN-BUF (REQ-START:REQ-REM) TALLYING HDR-CNT FOR CHARACTERS BEFORE INITIAL CRLF2
    IF HDR-CNT = REQ-REM
        IF REQ-REM > 65536
            MOVE 2 TO REQ-STATE
        END-IF
        EXIT PARAGRAPH
    END-IF
    MOVE REQ-START TO HDR-END
    ADD HDR-CNT TO HDR-END

    *> request line: method SP target SP version
    MOVE REQ-START TO HI
    PERFORM UNTIL IN-BUF (HI:1) = X"0D"
        ADD 1 TO HI
    END-PERFORM
    MOVE HI TO LN-END
    MOVE REQ-START TO HI
    PERFORM UNTIL HI >= LN-END OR IN-BUF (HI:1) = SPACE
        ADD 1 TO HI
    END-PERFORM
    IF HI >= LN-END
        MOVE 2 TO REQ-STATE
        EXIT PARAGRAPH
    END-IF
    MOVE REQ-START TO METH-OFF
    MOVE HI TO METH-LEN
    SUBTRACT REQ-START FROM METH-LEN
    MOVE HI TO TGT-OFF
    ADD 1 TO TGT-OFF
    MOVE LN-END TO HJ
    SUBTRACT 1 FROM HJ
    PERFORM UNTIL HJ < TGT-OFF OR IN-BUF (HJ:1) = SPACE
        SUBTRACT 1 FROM HJ
    END-PERFORM
    IF HJ < TGT-OFF
        MOVE 2 TO REQ-STATE
        EXIT PARAGRAPH
    END-IF
    MOVE HJ TO TGT-LEN
    SUBTRACT TGT-OFF FROM TGT-LEN
    *> HTTP/1.0 closes after the response unless the client asks to keep the connection
    MOVE LN-END TO HVAL-LEN
    SUBTRACT HJ FROM HVAL-LEN
    SUBTRACT 1 FROM HVAL-LEN
    IF HVAL-LEN = 8
        IF IN-BUF (HJ + 1:8) = "HTTP/1.0"
            MOVE 1 TO REQ-CLOSE
        END-IF
    END-IF
    *> path and query
    MOVE TGT-LEN TO PATH-LEN
    MOVE 0 TO QRY-LEN
    MOVE TGT-OFF TO HI
    MOVE TGT-OFF TO HJ
    ADD TGT-LEN TO HJ
    PERFORM UNTIL HI >= HJ OR IN-BUF (HI:1) = "?"
        ADD 1 TO HI
    END-PERFORM
    IF HI < HJ
        MOVE HI TO PATH-LEN
        SUBTRACT TGT-OFF FROM PATH-LEN
        MOVE HI TO QRY-OFF
        ADD 1 TO QRY-OFF
        MOVE HJ TO QRY-LEN
        SUBTRACT QRY-OFF FROM QRY-LEN
    END-IF

    *> header lines, each ending in CR LF; the last one's CR is at HDR-END
    MOVE LN-END TO HI
    ADD 2 TO HI
    PERFORM UNTIL HI > HDR-END
        MOVE HI TO LN-START
        MOVE 0 TO HCOLON
        PERFORM UNTIL IN-BUF (HI:1) = X"0D"
            IF HCOLON = 0
                IF IN-BUF (HI:1) = ":"
                    MOVE HI TO HCOLON
                END-IF
            END-IF
            ADD 1 TO HI
        END-PERFORM
        IF HCOLON = 0
            MOVE 2 TO REQ-STATE
            EXIT PARAGRAPH
        END-IF
        MOVE HI TO LN-END
        PERFORM HEADER-LINE
        IF REQ-STATE = 2
            EXIT PARAGRAPH
        END-IF
        ADD 2 TO HI
    END-PERFORM

    MOVE HDR-END TO BODY-OFF
    ADD 4 TO BODY-OFF
    MOVE BODY-OFF TO REQ-NEXT
    IF CLEN > 0
        MOVE CLEN TO BODY-LEN
        ADD CLEN TO REQ-NEXT
        *> a request that cannot fit in the buffer
        MOVE REQ-NEXT TO HJ
        SUBTRACT REQ-START FROM HJ
        IF HJ > IN-SIZE
            MOVE 2 TO REQ-STATE
            EXIT PARAGRAPH
        END-IF
        MOVE IN-LEN TO HJ
        ADD 1 TO HJ
        IF REQ-NEXT > HJ
            EXIT PARAGRAPH
        END-IF
    END-IF
    MOVE 1 TO REQ-STATE.

*> One header line: name from LN-START to HCOLON, value to LN-END, trimmed.
HEADER-LINE.
    MOVE HCOLON TO HNAME-LEN
    SUBTRACT LN-START FROM HNAME-LEN
    IF HNAME-LEN NOT = 13 AND HNAME-LEN NOT = 14 AND HNAME-LEN NOT = 10
        EXIT PARAGRAPH
    END-IF
    MOVE IN-BUF (LN-START:HNAME-LEN) TO HNAME
    INSPECT HNAME CONVERTING UPPER-AZ TO LOWER-AZ
    MOVE HCOLON TO HVAL-OFF
    ADD 1 TO HVAL-OFF
    MOVE LN-END TO HVAL-END
    PERFORM UNTIL HVAL-OFF >= HVAL-END
            OR (IN-BUF (HVAL-OFF:1) NOT = SPACE AND IN-BUF (HVAL-OFF:1) NOT = X"09"
                AND IN-BUF (HVAL-OFF:1) NOT = X"0C")
        ADD 1 TO HVAL-OFF
    END-PERFORM
    PERFORM UNTIL HVAL-END <= HVAL-OFF
            OR (IN-BUF (HVAL-END - 1:1) NOT = SPACE AND IN-BUF (HVAL-END - 1:1) NOT = X"09"
                AND IN-BUF (HVAL-END - 1:1) NOT = X"0C")
        SUBTRACT 1 FROM HVAL-END
    END-PERFORM
    MOVE HVAL-END TO HVAL-LEN
    SUBTRACT HVAL-OFF FROM HVAL-LEN
    EVALUATE HNAME-LEN ALSO HNAME
        WHEN 13 ALSO "authorization"
            MOVE 1 TO AUTH-SET
            MOVE HVAL-OFF TO AUTH-OFF
            MOVE HVAL-LEN TO AUTH-LEN
        WHEN 14 ALSO "content-length"
            *> digits only, and no more than fits in the buffer
            IF HVAL-LEN = 0 OR HVAL-LEN > 9
                MOVE 2 TO REQ-STATE
                EXIT PARAGRAPH
            END-IF
            MOVE 0 TO CLEN
            PERFORM VARYING HJ FROM HVAL-OFF BY 1 UNTIL HJ >= HVAL-END
                MOVE IN-BUF (HJ:1) TO BYTE-X
                IF BYTE-V < 48 OR BYTE-V > 57
                    MOVE 2 TO REQ-STATE
                    EXIT PARAGRAPH
                END-IF
                COMPUTE CLEN = CLEN * 10 + BYTE-V - 48
            END-PERFORM
            IF CLEN > IN-SIZE
                MOVE 2 TO REQ-STATE
            END-IF
        WHEN 10 ALSO "connection"
            IF HVAL-LEN = 5 OR HVAL-LEN = 10
                MOVE SPACES TO HVAL-LC
                MOVE IN-BUF (HVAL-OFF:HVAL-LEN) TO HVAL-LC
                INSPECT HVAL-LC CONVERTING UPPER-AZ TO LOWER-AZ
                IF HVAL-LC = "close"
                    MOVE 1 TO REQ-CLOSE
                END-IF
                IF HVAL-LC = "keep-alive"
                    MOVE 0 TO REQ-CLOSE
                END-IF
            END-IF
    END-EVALUATE.

*> ---------- routing ----------

*> Matches (method, path segments) to a route, checks the token the route needs, and runs the handler.
DISPATCH.
    PERFORM SPLIT-PATH
    IF SEG-OK = 0
        MOVE 404 TO ERR-STATUS
        MOVE "not found" TO ERR-MSG
        PERFORM RESPOND-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO METH-CODE
    EVALUATE METH-LEN ALSO IN-BUF (METH-OFF:METH-LEN)
        WHEN 3 ALSO "GET"
            MOVE 1 TO METH-CODE
        WHEN 4 ALSO "POST"
            MOVE 2 TO METH-CODE
        WHEN 3 ALSO "PUT"
            MOVE 3 TO METH-CODE
        WHEN 6 ALSO "DELETE"
            MOVE 4 TO METH-CODE
    END-EVALUATE
    MOVE 0 TO ROUTE
    EVALUATE NSEG
        WHEN 1
            EVALUATE SEG-LEN (1) ALSO SEGBUF (SEG-OFF (1):SEG-LEN (1)) ALSO METH-CODE
                WHEN 4 ALSO "tags" ALSO 1
                    MOVE 1 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 1
                    MOVE 2 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 2
                    MOVE 14 TO ROUTE
                WHEN 4 ALSO "user" ALSO 1
                    MOVE 7 TO ROUTE
                WHEN 4 ALSO "user" ALSO 3
                    MOVE 19 TO ROUTE
                WHEN 5 ALSO "users" ALSO 2
                    MOVE 17 TO ROUTE
            END-EVALUATE
        WHEN 2
            EVALUATE SEG-LEN (1) ALSO SEGBUF (SEG-OFF (1):SEG-LEN (1)) ALSO METH-CODE
                WHEN 8 ALSO "articles" ALSO 1
                    IF SEG-LEN (2) = 4 AND SEGBUF (SEG-OFF (2):4) = "feed"
                        MOVE 3 TO ROUTE
                    ELSE
                        MOVE 4 TO ROUTE
                    END-IF
                WHEN 8 ALSO "articles" ALSO 3
                    MOVE 15 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 4
                    MOVE 16 TO ROUTE
                WHEN 8 ALSO "profiles" ALSO 1
                    MOVE 6 TO ROUTE
                WHEN 5 ALSO "users" ALSO 2
                    IF SEG-LEN (2) = 5 AND SEGBUF (SEG-OFF (2):5) = "login"
                        MOVE 18 TO ROUTE
                    END-IF
            END-EVALUATE
        WHEN 3
            EVALUATE SEG-LEN (1) ALSO SEGBUF (SEG-OFF (1):SEG-LEN (1))
                     ALSO SEG-LEN (3) ALSO SEGBUF (SEG-OFF (3):SEG-LEN (3)) ALSO METH-CODE
                WHEN 8 ALSO "articles" ALSO 8 ALSO "comments" ALSO 1
                    MOVE 5 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 8 ALSO "comments" ALSO 2
                    MOVE 10 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 8 ALSO "favorite" ALSO 2
                    MOVE 8 TO ROUTE
                WHEN 8 ALSO "articles" ALSO 8 ALSO "favorite" ALSO 4
                    MOVE 9 TO ROUTE
                WHEN 8 ALSO "profiles" ALSO 6 ALSO "follow" ALSO 2
                    MOVE 12 TO ROUTE
                WHEN 8 ALSO "profiles" ALSO 6 ALSO "follow" ALSO 4
                    MOVE 13 TO ROUTE
            END-EVALUATE
        WHEN 4
            IF METH-CODE = 4 AND SEG-LEN (1) = 8 AND SEGBUF (SEG-OFF (1):8) = "articles"
                    AND SEG-LEN (3) = 8 AND SEGBUF (SEG-OFF (3):8) = "comments"
                MOVE 11 TO ROUTE
            END-IF
    END-EVALUATE
    IF ROUTE = 0
        MOVE 404 TO ERR-STATUS
        MOVE "not found" TO ERR-MSG
        PERFORM RESPOND-ERROR
        EXIT PARAGRAPH
    END-IF
    *> tags, sign-up and login read no token; four routes take one if present; the rest need one
    EVALUATE ROUTE
        WHEN 1
        WHEN 17
        WHEN 18
            MOVE 0 TO VIEWER-ID
        WHEN 2
        WHEN 4
        WHEN 5
        WHEN 6
            PERFORM AUTHENTICATE
            IF AUTH-RESULT = 1
                PERFORM RESPOND-401
                EXIT PARAGRAPH
            END-IF
            IF AUTH-RESULT = 0
                MOVE 0 TO VIEWER-ID
            END-IF
        WHEN OTHER
            PERFORM AUTHENTICATE
            IF AUTH-RESULT NOT = 2
                PERFORM RESPOND-401
                EXIT PARAGRAPH
            END-IF
    END-EVALUATE
    MOVE VIEWER-ID TO CN-VIEWER (FX)
    EVALUATE ROUTE
        WHEN 1  PERFORM H-TAGS
        WHEN 2  PERFORM H-LIST-ARTICLES
        WHEN 3  PERFORM H-FEED
        WHEN 4  PERFORM H-GET-ARTICLE
        WHEN 5  PERFORM H-LIST-COMMENTS
        WHEN 6  PERFORM H-GET-PROFILE
        WHEN 7  PERFORM H-CURRENT-USER
        WHEN 8  PERFORM H-FAVORITE
        WHEN 9  PERFORM H-UNFAVORITE
        WHEN 10 PERFORM H-CREATE-COMMENT
        WHEN 11 PERFORM H-DELETE-COMMENT
        WHEN 12 PERFORM H-FOLLOW
        WHEN 13 PERFORM H-UNFOLLOW
        WHEN 14 PERFORM H-CREATE-ARTICLE
        WHEN 15 PERFORM H-UPDATE-ARTICLE
        WHEN 16 PERFORM H-DELETE-ARTICLE
        WHEN 17 PERFORM H-REGISTER
        WHEN 18 PERFORM H-LOGIN
        WHEN 19 PERFORM H-UPDATE-USER
    END-EVALUATE.

RESPOND-401.
    MOVE 401 TO ERR-STATUS
    MOVE "unauthorized" TO ERR-MSG
    PERFORM RESPOND-ERROR.

*> AUTH-RESULT: 0 no Authorization header (or an empty one), 1 anything but a valid "Token <jwt>", 2 valid.
AUTHENTICATE.
    IF AUTH-SET = 0 OR AUTH-LEN = 0
        MOVE 0 TO AUTH-RESULT
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO AUTH-RESULT
    IF AUTH-LEN > 6
        IF IN-BUF (AUTH-OFF:6) = "Token "
            MOVE AUTH-OFF TO TOK-OFF
            ADD 6 TO TOK-OFF
            MOVE AUTH-LEN TO TOK-LEN
            SUBTRACT 6 FROM TOK-LEN
            PERFORM JWT-VERIFY
            IF JWT-OK = 1
                MOVE 2 TO AUTH-RESULT
            END-IF
        END-IF
    END-IF.

*> The path must be /api followed by '/'-separated, non-empty segments; each is percent-decoded into SEGBUF.
*> SEG-OK = 0 for anything else (or more segments than any route has).
SPLIT-PATH.
    MOVE 0 TO SEG-OK NSEG
    IF PATH-LEN < 4
        EXIT PARAGRAPH
    END-IF
    IF IN-BUF (TGT-OFF:4) NOT = "/api"
        EXIT PARAGRAPH
    END-IF
    IF PATH-LEN = 4
        MOVE 1 TO SEG-OK
        EXIT PARAGRAPH
    END-IF
    IF IN-BUF (TGT-OFF + 4:1) NOT = "/"
        EXIT PARAGRAPH
    END-IF
    MOVE TGT-OFF TO PATH-END
    ADD PATH-LEN TO PATH-END
    MOVE TGT-OFF TO HI
    ADD 5 TO HI
    MOVE 1 TO UE-OUT
    PERFORM FOREVER
        ADD 1 TO NSEG
        IF NSEG > 4
            EXIT PARAGRAPH
        END-IF
        MOVE HI TO UE-OFF
        PERFORM UNTIL HI >= PATH-END OR IN-BUF (HI:1) = "/"
            ADD 1 TO HI
        END-PERFORM
        MOVE HI TO UE-LEN
        SUBTRACT UE-OFF FROM UE-LEN
        IF UE-LEN = 0
            EXIT PARAGRAPH
        END-IF
        MOVE UE-OUT TO SEG-OFF (NSEG)
        PERFORM UNESCAPE-SEG
        IF UE-OK = 0
            EXIT PARAGRAPH
        END-IF
        MOVE UE-OUT TO SEG-LEN (NSEG)
        SUBTRACT SEG-OFF (NSEG) FROM SEG-LEN (NSEG)
        IF HI >= PATH-END
            EXIT PERFORM
        END-IF
        ADD 1 TO HI
    END-PERFORM
    MOVE 1 TO SEG-OK.

*> Percent-decoding of IN-BUF (UE-OFF:UE-LEN) into SEGBUF at UE-OUT, which ends one past the last byte. A '+' stays a
*> '+' in a path.
UNESCAPE-SEG.
    MOVE 1 TO UE-OK
    MOVE UE-OFF TO UE-I
    MOVE UE-OFF TO UE-END
    ADD UE-LEN TO UE-END
    PERFORM UNTIL UE-I >= UE-END
        MOVE IN-BUF (UE-I:1) TO BYTE-X
        EVALUATE BYTE-X
            WHEN "%"
                MOVE UE-END TO HJ
                SUBTRACT UE-I FROM HJ
                IF HJ < 3
                    MOVE 0 TO UE-OK
                    EXIT PARAGRAPH
                END-IF
                MOVE IN-BUF (UE-I + 1:1) TO BYTE2-X
                MOVE IN-BUF (UE-I + 2:1) TO BYTE3-X
                IF HEX-VAL (BYTE2-V + 1) < 0 OR HEX-VAL (BYTE3-V + 1) < 0
                    MOVE 0 TO UE-OK
                    EXIT PARAGRAPH
                END-IF
                MOVE HEX-HI (BYTE2-V + 1) TO L32
                ADD HEX-VAL (BYTE3-V + 1) TO L32
                MOVE L32-X (1:1) TO SEGBUF (UE-OUT:1)
                ADD 3 TO UE-I
            WHEN OTHER
                MOVE BYTE-X TO SEGBUF (UE-OUT:1)
                ADD 1 TO UE-I
        END-EVALUATE
        ADD 1 TO UE-OUT
    END-PERFORM.

*> The same decoding into QBUF, for query keys and values, where a '+' is a space.
UNESCAPE-QRY.
    MOVE 1 TO UE-OK
    MOVE UE-OFF TO UE-I
    MOVE UE-OFF TO UE-END
    ADD UE-LEN TO UE-END
    PERFORM UNTIL UE-I >= UE-END
        MOVE IN-BUF (UE-I:1) TO BYTE-X
        EVALUATE BYTE-X
            WHEN "%"
                MOVE UE-END TO HJ
                SUBTRACT UE-I FROM HJ
                IF HJ < 3
                    MOVE 0 TO UE-OK
                    EXIT PARAGRAPH
                END-IF
                MOVE IN-BUF (UE-I + 1:1) TO BYTE2-X
                MOVE IN-BUF (UE-I + 2:1) TO BYTE3-X
                IF HEX-VAL (BYTE2-V + 1) < 0 OR HEX-VAL (BYTE3-V + 1) < 0
                    MOVE 0 TO UE-OK
                    EXIT PARAGRAPH
                END-IF
                MOVE HEX-HI (BYTE2-V + 1) TO L32
                ADD HEX-VAL (BYTE3-V + 1) TO L32
                MOVE L32-X (1:1) TO QBUF (UE-OUT:1)
                ADD 3 TO UE-I
            WHEN "+"
                MOVE SPACE TO QBUF (UE-OUT:1)
                ADD 1 TO UE-I
            WHEN OTHER
                MOVE BYTE-X TO QBUF (UE-OUT:1)
                ADD 1 TO UE-I
        END-EVALUATE
        ADD 1 TO UE-OUT
    END-PERFORM.

*> ---------- query ----------

*> The first valid occurrence of limit, offset, tag, author and favorited in the query. Pairs that are empty,
*> hold a ';' or have a malformed escape are dropped, as Go's url.ParseQuery drops them.
PARSE-QUERY.
    MOVE 0 TO QV-SET (1) QV-SET (2) QV-SET (3) QV-SET (4) QV-SET (5) QB-LEN
    IF QRY-LEN = 0
        EXIT PARAGRAPH
    END-IF
    MOVE QRY-OFF TO QP-I
    MOVE QRY-OFF TO QP-END
    ADD QRY-LEN TO QP-END
    PERFORM UNTIL QP-I > QP-END
        MOVE QP-I TO QP-PS
        MOVE 0 TO QP-EQ QP-SEMI
        PERFORM UNTIL QP-I >= QP-END OR IN-BUF (QP-I:1) = "&"
            IF IN-BUF (QP-I:1) = ";"
                MOVE 1 TO QP-SEMI
            END-IF
            IF IN-BUF (QP-I:1) = "=" AND QP-EQ = 0
                MOVE QP-I TO QP-EQ
            END-IF
            ADD 1 TO QP-I
        END-PERFORM
        MOVE QP-I TO QP-PE
        ADD 1 TO QP-I
        IF QP-PE > QP-PS AND QP-SEMI = 0
            PERFORM QUERY-PAIR
        END-IF
    END-PERFORM.

QUERY-PAIR.
    *> the key, decoded into QBUF past the values kept so far
    MOVE QP-PS TO UE-OFF
    IF QP-EQ > 0
        MOVE QP-EQ TO UE-LEN
    ELSE
        MOVE QP-PE TO UE-LEN
    END-IF
    SUBTRACT QP-PS FROM UE-LEN
    IF UE-LEN > 27
        EXIT PARAGRAPH
    END-IF
    MOVE QB-LEN TO UE-OUT
    ADD 1 TO UE-OUT
    PERFORM UNESCAPE-QRY
    IF UE-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE UE-OUT TO QKEY-LEN
    SUBTRACT QB-LEN FROM QKEY-LEN
    SUBTRACT 1 FROM QKEY-LEN
    MOVE SPACES TO QKEY
    IF QKEY-LEN > 0 AND QKEY-LEN <= 16
        MOVE QBUF (QB-LEN + 1:QKEY-LEN) TO QKEY
    END-IF
    MOVE 0 TO QP-WHICH
    EVALUATE QKEY-LEN ALSO QKEY
        WHEN 5 ALSO "limit"
            MOVE 1 TO QP-WHICH
        WHEN 6 ALSO "offset"
            MOVE 2 TO QP-WHICH
        WHEN 3 ALSO "tag"
            MOVE 3 TO QP-WHICH
        WHEN 6 ALSO "author"
            MOVE 4 TO QP-WHICH
        WHEN 9 ALSO "favorited"
            MOVE 5 TO QP-WHICH
    END-EVALUATE
    IF QP-WHICH = 0
        EXIT PARAGRAPH
    END-IF
    IF QV-SET (QP-WHICH) = 1
        EXIT PARAGRAPH
    END-IF
    *> the value
    MOVE QB-LEN TO UE-OUT
    ADD 1 TO UE-OUT
    IF QP-EQ > 0
        MOVE QP-EQ TO UE-OFF
        ADD 1 TO UE-OFF
        MOVE QP-PE TO UE-LEN
        SUBTRACT UE-OFF FROM UE-LEN
        PERFORM UNESCAPE-QRY
        IF UE-OK = 0
            EXIT PARAGRAPH
        END-IF
    END-IF
    MOVE 1 TO QV-SET (QP-WHICH)
    MOVE QB-LEN TO QV-OFF (QP-WHICH)
    ADD 1 TO QV-OFF (QP-WHICH)
    MOVE UE-OUT TO QV-LEN (QP-WHICH)
    SUBTRACT QV-OFF (QP-WHICH) FROM QV-LEN (QP-WHICH)
    MOVE UE-OUT TO QB-LEN
    SUBTRACT 1 FROM QB-LEN.

*> limit: 1 to 100, default 20; offset: >= 0, default 0. Both are passed to Postgres as text, without leading
*> zeros. LO-OK = 0 if either is invalid.
LIMIT-OFFSET.
    MOVE 1 TO LO-OK
    IF QV-SET (1) = 0
        MOVE "20" TO LIMIT-TXT
        MOVE 2 TO LIMIT-LEN
    ELSE
        MOVE QV-OFF (1) TO UI-OFF
        MOVE QV-LEN (1) TO UI-LEN
        PERFORM PARSE-UINT
        IF UI-OK = 0
            MOVE 0 TO LO-OK
            EXIT PARAGRAPH
        END-IF
        MOVE UI-LEN TO LIMIT-LEN
        SUBTRACT UI-SKIP FROM LIMIT-LEN
        IF LIMIT-LEN > 3
            MOVE 0 TO LO-OK
            EXIT PARAGRAPH
        END-IF
        MOVE QBUF (UI-OFF + UI-SKIP:LIMIT-LEN) TO LIMIT-TXT
        IF LIMIT-TXT (1:LIMIT-LEN) = "0"
            MOVE 0 TO LO-OK
            EXIT PARAGRAPH
        END-IF
        IF LIMIT-LEN = 3 AND LIMIT-TXT (1:3) NOT = "100"
            MOVE 0 TO LO-OK
            EXIT PARAGRAPH
        END-IF
    END-IF
    IF QV-SET (2) = 0
        MOVE "0" TO OFFSET-TXT
        MOVE 1 TO OFFSET-LEN
    ELSE
        MOVE QV-OFF (2) TO UI-OFF
        MOVE QV-LEN (2) TO UI-LEN
        PERFORM PARSE-UINT
        IF UI-OK = 0
            MOVE 0 TO LO-OK
            EXIT PARAGRAPH
        END-IF
        MOVE UI-LEN TO OFFSET-LEN
        SUBTRACT UI-SKIP FROM OFFSET-LEN
        MOVE QBUF (UI-OFF + UI-SKIP:OFFSET-LEN) TO OFFSET-TXT
    END-IF.

*> An unsigned integer: 1 to 18 ASCII digits. UI-SKIP leading zeros are skipped, leaving at least one digit.
PARSE-UINT.
    MOVE 0 TO UI-OK UI-SKIP
    IF UI-LEN = 0 OR UI-LEN > 18
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING UI-I FROM UI-OFF BY 1 UNTIL UI-I >= UI-OFF + UI-LEN
        MOVE QBUF (UI-I:1) TO BYTE-X
        IF BYTE-V < 48 OR BYTE-V > 57
            EXIT PARAGRAPH
        END-IF
    END-PERFORM
    MOVE 1 TO UI-OK
    PERFORM UNTIL UI-SKIP >= UI-LEN - 1 OR QBUF (UI-OFF + UI-SKIP:1) NOT = "0"
        ADD 1 TO UI-SKIP
    END-PERFORM.
