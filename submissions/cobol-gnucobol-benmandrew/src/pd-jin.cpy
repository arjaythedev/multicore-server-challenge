*> ================= jin: JSON parser =================
*> Reads JSON the way Yojson.Safe.from_string does: one value with whitespace around it, where whitespace also
*> covers // and /* */ comments; object keys are strings or bare identifiers ([A-Za-z_][A-Za-z0-9_]*); strings
*> hold any byte but " and \ unescaped; NaN, Infinity and -Infinity are numbers. Iterative: an explicit stack
*> holds the open containers. Only the members the caller asked for (by JI-MODE) are kept.

JI-PARSE.
    IF JI-READY = 0
        PERFORM JI-INIT-TABLES
    END-IF
    MOVE 0 TO JI-OK JI-TOP-OBJ JI-WRAP-OK JT-OK JT-N JI-BP JI-DEPTH
    MOVE LOW-VALUES TO JI-FIELDS
    MOVE JI-SRC-OFF TO JI-P
    MOVE JI-SRC-OFF TO JI-END
    ADD JI-SRC-LEN TO JI-END
    MOVE 9 TO JI-ROLE
    MOVE 1 TO JI-ST
    PERFORM JI-WS
    PERFORM UNTIL JI-ST <= 0
        EVALUATE JI-ST
            WHEN 1
                PERFORM JI-VALUE
            WHEN 2
                PERFORM JI-AFTER
            WHEN OTHER
                PERFORM JI-MEMBER
        END-EVALUATE
    END-PERFORM
    IF JI-ST = 0
        MOVE 1 TO JI-OK
    ELSE
        MOVE 0 TO JI-TOP-OBJ JI-WRAP-OK JT-OK JT-N
        MOVE LOW-VALUES TO JI-FIELDS
    END-IF.

*> Start-up work, done once per process: the byte tables.
JI-INIT-TABLES.
    PERFORM VARYING JI-TI FROM 1 BY 1 UNTIL JI-TI > 256
        MOVE -1 TO JI-HEX (JI-TI)
        MOVE 0 TO JI-ID (JI-TI)
    END-PERFORM
    *> '0'..'9' are bytes 48..57, 'A'..'F' 65..70, 'a'..'f' 97..102
    PERFORM VARYING JI-TI FROM 0 BY 1 UNTIL JI-TI > 9
        COMPUTE JI-HEX (JI-TI + 49) = JI-TI
        MOVE 1 TO JI-ID (JI-TI + 49)
    END-PERFORM
    PERFORM VARYING JI-TI FROM 0 BY 1 UNTIL JI-TI > 5
        COMPUTE JI-HEX (JI-TI + 66) = JI-TI + 10
        COMPUTE JI-HEX (JI-TI + 98) = JI-TI + 10
    END-PERFORM
    PERFORM VARYING JI-TI FROM 0 BY 1 UNTIL JI-TI > 25
        MOVE 2 TO JI-ID (JI-TI + 66)
        MOVE 2 TO JI-ID (JI-TI + 98)
    END-PERFORM
    *> '_' is byte 95
    MOVE 2 TO JI-ID (96)
    PERFORM VARYING JI-TI FROM 0 BY 1 UNTIL JI-TI > 19
        COMPUTE JI-M16 (JI-TI + 1) = JI-TI * 16
        COMPUTE JI-M4 (JI-TI + 1) = JI-TI * 4
        COMPUTE JI-D4 (JI-TI + 1) = JI-TI / 4
        COMPUTE JI-R16 (JI-TI + 1) = FUNCTION MOD (JI-TI, 4) * 16
        COMPUTE JI-R4 (JI-TI + 1) = FUNCTION MOD (JI-TI, 4) * 4
    END-PERFORM
    MOVE 1 TO JI-READY.

*> Skips whitespace and comments. An unterminated /* comment, or a / that starts no comment, fails.
JI-WS.
    PERFORM UNTIL JI-P >= JI-END
        EVALUATE L-JSRC (JI-P:1)
            WHEN SPACE
            WHEN X"0A"
            WHEN X"0D"
            WHEN X"09"
                ADD 1 TO JI-P
            WHEN "/"
                PERFORM JI-COMMENT
                IF JI-ST < 0
                    EXIT PARAGRAPH
                END-IF
            WHEN OTHER
                EXIT PARAGRAPH
        END-EVALUATE
    END-PERFORM.

*> The comment at JI-P. A // comment stops before its newline, which JI-WS then skips.
JI-COMMENT.
    MOVE JI-P TO JI-Q
    ADD 1 TO JI-Q
    IF JI-Q >= JI-END
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    EVALUATE L-JSRC (JI-Q:1)
        WHEN "/"
            ADD 2 TO JI-P
            PERFORM UNTIL JI-P >= JI-END OR L-JSRC (JI-P:1) = X"0A"
                ADD 1 TO JI-P
            END-PERFORM
        WHEN "*"
            ADD 2 TO JI-P
            PERFORM UNTIL JI-ST < 0
                IF JI-P >= JI-END
                    MOVE -1 TO JI-ST
                    EXIT PARAGRAPH
                END-IF
                IF L-JSRC (JI-P:1) = "*"
                    MOVE JI-P TO JI-Q
                    ADD 1 TO JI-Q
                    IF JI-Q < JI-END AND L-JSRC (JI-Q:1) = "/"
                        ADD 2 TO JI-P
                        EXIT PARAGRAPH
                    END-IF
                END-IF
                ADD 1 TO JI-P
            END-PERFORM
        WHEN OTHER
            MOVE -1 TO JI-ST
    END-EVALUATE.

*> A value starts at JI-P (whitespace already skipped). Records it as JI-ROLE says.
JI-VALUE.
    IF JI-P >= JI-END
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    EVALUATE L-JSRC (JI-P:1)
        WHEN '"'
            PERFORM JI-STRING
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            EVALUATE JI-ROLE
                WHEN 2
                    MOVE 2 TO JF-T (JI-K)
                    MOVE JI-BP TO JF-OFF (JI-K)
                    ADD 1 TO JF-OFF (JI-K)
                    MOVE JI-SL TO JF-LEN (JI-K)
                    ADD JI-SL TO JI-BP
                WHEN 3
                    IF JI-SL = 0 OR JT-N >= 65536
                        MOVE 0 TO JT-OK
                    ELSE
                        ADD 1 TO JT-N
                        MOVE JI-BP TO JT-OFF (JT-N)
                        ADD 1 TO JT-OFF (JT-N)
                        MOVE JI-SL TO JT-LEN (JT-N)
                        ADD JI-SL TO JI-BP
                    END-IF
            END-EVALUATE
            MOVE 2 TO JI-ST
        WHEN "{"
            PERFORM JI-PUSH
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            MOVE 1 TO JI-SK (JI-DEPTH)
            MOVE 0 TO JI-SR (JI-DEPTH)
            EVALUATE JI-ROLE
                WHEN 9
                    MOVE 1 TO JI-TOP-OBJ
                    MOVE 1 TO JI-SR (JI-DEPTH)
                WHEN 1
                    MOVE 1 TO JI-WRAP-OK
                    MOVE 2 TO JI-SR (JI-DEPTH)
                WHEN 2
                    MOVE 3 TO JF-T (JI-K)
                WHEN 3
                    MOVE 0 TO JT-OK
            END-EVALUATE
            ADD 1 TO JI-P
            PERFORM JI-WS
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            IF JI-P < JI-END AND L-JSRC (JI-P:1) = "}"
                ADD 1 TO JI-P
                SUBTRACT 1 FROM JI-DEPTH
                MOVE 2 TO JI-ST
            ELSE
                MOVE 3 TO JI-ST
            END-IF
        WHEN "["
            PERFORM JI-PUSH
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            MOVE 2 TO JI-SK (JI-DEPTH)
            MOVE 0 TO JI-SR (JI-DEPTH)
            EVALUATE JI-ROLE
                WHEN 2
                    MOVE 4 TO JF-T (JI-K)
                    IF JI-K = 9
                        MOVE 3 TO JI-SR (JI-DEPTH)
                        MOVE 1 TO JT-OK
                        MOVE 0 TO JT-N
                    END-IF
                WHEN 3
                    MOVE 0 TO JT-OK
            END-EVALUATE
            ADD 1 TO JI-P
            PERFORM JI-WS
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            IF JI-P < JI-END AND L-JSRC (JI-P:1) = "]"
                ADD 1 TO JI-P
                SUBTRACT 1 FROM JI-DEPTH
                MOVE 2 TO JI-ST
            ELSE
                PERFORM JI-ELEM-ROLE
                MOVE 1 TO JI-ST
            END-IF
        WHEN "t"
            MOVE 4 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:4) = "true"
                    PERFORM JI-SCALAR-T3
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
        WHEN "f"
            MOVE 5 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:5) = "false"
                    PERFORM JI-SCALAR-T3
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
        WHEN "n"
            MOVE 4 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:4) = "null"
                    EVALUATE JI-ROLE
                        WHEN 2
                            MOVE 1 TO JF-T (JI-K)
                        WHEN 3
                            MOVE 0 TO JT-OK
                    END-EVALUATE
                    ADD 4 TO JI-P
                    MOVE 2 TO JI-ST
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
        WHEN "N"
            MOVE 3 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:3) = "NaN"
                    MOVE JI-P TO JI-Q
                    ADD 3 TO JI-P
                    PERFORM JI-SCALAR-NUM
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
        WHEN "I"
            MOVE 8 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:8) = "Infinity"
                    MOVE JI-P TO JI-Q
                    ADD 8 TO JI-P
                    PERFORM JI-SCALAR-NUM
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
        WHEN "-"
        WHEN "0" THRU "9"
            PERFORM JI-NUMBER
        WHEN OTHER
            MOVE -1 TO JI-ST
    END-EVALUATE.

*> Fails unless JI-N bytes remain at JI-P.
JI-ROOM.
    MOVE JI-END TO JI-R
    SUBTRACT JI-P FROM JI-R
    IF JI-R < JI-N
        MOVE -1 TO JI-ST
    END-IF.

*> true or false, JI-N bytes long, at JI-P.
JI-SCALAR-T3.
    EVALUATE JI-ROLE
        WHEN 2
            MOVE 3 TO JF-T (JI-K)
        WHEN 3
            MOVE 0 TO JT-OK
    END-EVALUATE
    ADD JI-N TO JI-P
    MOVE 2 TO JI-ST.

*> A number from JI-Q to JI-P (exclusive): its text is kept for a field.
JI-SCALAR-NUM.
    EVALUATE JI-ROLE
        WHEN 2
            MOVE JI-P TO JI-N
            SUBTRACT JI-Q FROM JI-N
            MOVE 5 TO JF-T (JI-K)
            MOVE JI-BP TO JF-OFF (JI-K)
            ADD 1 TO JF-OFF (JI-K)
            MOVE JI-N TO JF-LEN (JI-K)
            MOVE L-JSRC (JI-Q:JI-N) TO JI-BUF (JI-BP + 1:JI-N)
            ADD JI-N TO JI-BP
        WHEN 3
            MOVE 0 TO JT-OK
    END-EVALUATE
    MOVE 2 TO JI-ST.

*> -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?, or -Infinity. Whatever follows must be a separator, which
*> JI-AFTER checks, so the longest match Yojson's lexer takes gives the same verdict.
JI-NUMBER.
    MOVE JI-P TO JI-Q
    IF L-JSRC (JI-P:1) = "-"
        ADD 1 TO JI-P
        IF JI-P >= JI-END
            MOVE -1 TO JI-ST
            EXIT PARAGRAPH
        END-IF
        IF L-JSRC (JI-P:1) = "I"
            MOVE 8 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST > 0
                IF L-JSRC (JI-P:8) = "Infinity"
                    ADD 8 TO JI-P
                    PERFORM JI-SCALAR-NUM
                ELSE
                    MOVE -1 TO JI-ST
                END-IF
            END-IF
            EXIT PARAGRAPH
        END-IF
    END-IF
    EVALUATE L-JSRC (JI-P:1)
        WHEN "0"
            ADD 1 TO JI-P
        WHEN "1" THRU "9"
            ADD 1 TO JI-P
            PERFORM UNTIL JI-P >= JI-END OR L-JSRC (JI-P:1) < "0" OR L-JSRC (JI-P:1) > "9"
                ADD 1 TO JI-P
            END-PERFORM
        WHEN OTHER
            MOVE -1 TO JI-ST
            EXIT PARAGRAPH
    END-EVALUATE
    IF JI-P < JI-END AND L-JSRC (JI-P:1) = "."
        ADD 1 TO JI-P
        PERFORM JI-DIGITS
        IF JI-ST < 0
            EXIT PARAGRAPH
        END-IF
    END-IF
    IF JI-P < JI-END AND (L-JSRC (JI-P:1) = "e" OR L-JSRC (JI-P:1) = "E")
        ADD 1 TO JI-P
        IF JI-P < JI-END AND (L-JSRC (JI-P:1) = "+" OR L-JSRC (JI-P:1) = "-")
            ADD 1 TO JI-P
        END-IF
        PERFORM JI-DIGITS
        IF JI-ST < 0
            EXIT PARAGRAPH
        END-IF
    END-IF
    PERFORM JI-SCALAR-NUM.

*> One or more digits at JI-P.
JI-DIGITS.
    IF JI-P >= JI-END OR L-JSRC (JI-P:1) < "0" OR L-JSRC (JI-P:1) > "9"
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    PERFORM UNTIL JI-P >= JI-END OR L-JSRC (JI-P:1) < "0" OR L-JSRC (JI-P:1) > "9"
        ADD 1 TO JI-P
    END-PERFORM.

JI-PUSH.
    IF JI-DEPTH >= JI-MAX-DEPTH
        MOVE -1 TO JI-ST
    ELSE
        ADD 1 TO JI-DEPTH
    END-IF.

*> The role of the next element of the array on top of the stack.
JI-ELEM-ROLE.
    IF JI-SR (JI-DEPTH) = 3
        MOVE 3 TO JI-ROLE
    ELSE
        MOVE 0 TO JI-ROLE
    END-IF.

*> A value has ended: the input ends (at the top), or a separator or closing bracket follows.
JI-AFTER.
    PERFORM JI-WS
    IF JI-ST < 0
        EXIT PARAGRAPH
    END-IF
    IF JI-DEPTH = 0
        IF JI-P >= JI-END
            MOVE 0 TO JI-ST
        ELSE
            MOVE -1 TO JI-ST
        END-IF
        EXIT PARAGRAPH
    END-IF
    IF JI-P >= JI-END
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    IF JI-SK (JI-DEPTH) = 1
        EVALUATE L-JSRC (JI-P:1)
            WHEN ","
                ADD 1 TO JI-P
                PERFORM JI-WS
                IF JI-ST > 0
                    MOVE 3 TO JI-ST
                END-IF
            WHEN "}"
                ADD 1 TO JI-P
                SUBTRACT 1 FROM JI-DEPTH
            WHEN OTHER
                MOVE -1 TO JI-ST
        END-EVALUATE
    ELSE
        EVALUATE L-JSRC (JI-P:1)
            WHEN ","
                ADD 1 TO JI-P
                PERFORM JI-WS
                IF JI-ST > 0
                    PERFORM JI-ELEM-ROLE
                    MOVE 1 TO JI-ST
                END-IF
            WHEN "]"
                ADD 1 TO JI-P
                SUBTRACT 1 FROM JI-DEPTH
            WHEN OTHER
                MOVE -1 TO JI-ST
        END-EVALUATE
    END-IF.

*> A member key starts at JI-P: a string or an identifier, read into JI-BUF (JI-BP + 1:JI-SL) without keeping
*> it. Sets JI-ROLE for the member's value, then reads the colon.
JI-MEMBER.
    IF JI-P >= JI-END
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    IF L-JSRC (JI-P:1) = '"'
        PERFORM JI-STRING
        IF JI-ST < 0
            EXIT PARAGRAPH
        END-IF
    ELSE
        MOVE L-JSRC (JI-P:1) TO JI-BX
        IF JI-ID (JI-BV + 1) NOT = 2
            MOVE -1 TO JI-ST
            EXIT PARAGRAPH
        END-IF
        MOVE JI-P TO JI-Q
        ADD 1 TO JI-P
        PERFORM UNTIL JI-P >= JI-END
            MOVE L-JSRC (JI-P:1) TO JI-BX
            IF JI-ID (JI-BV + 1) = 0
                EXIT PERFORM
            END-IF
            ADD 1 TO JI-P
        END-PERFORM
        MOVE JI-P TO JI-SL
        SUBTRACT JI-Q FROM JI-SL
        MOVE L-JSRC (JI-Q:JI-SL) TO JI-BUF (JI-BP + 1:JI-SL)
    END-IF
    MOVE 0 TO JI-ROLE
    EVALUATE JI-SR (JI-DEPTH)
        WHEN 1
            IF JI-MODE = 1
                *> a later wrapper member replaces an earlier one entirely
                IF JI-SL = JI-WRAP-LEN AND JI-SL > 0
                    IF JI-BUF (JI-BP + 1:JI-SL) = JI-WRAP (1:JI-SL)
                        MOVE 1 TO JI-ROLE
                        MOVE 0 TO JI-WRAP-OK JT-OK JT-N
                        MOVE LOW-VALUES TO JI-FIELDS
                    END-IF
                END-IF
            ELSE
                PERFORM JI-KEY
            END-IF
        WHEN 2
            PERFORM JI-KEY
    END-EVALUATE
    PERFORM JI-WS
    IF JI-ST < 0
        EXIT PARAGRAPH
    END-IF
    IF JI-P >= JI-END OR L-JSRC (JI-P:1) NOT = ":"
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO JI-P
    PERFORM JI-WS
    IF JI-ST > 0
        MOVE 1 TO JI-ST
    END-IF.

*> The key in JI-BUF (JI-BP + 1:JI-SL): if it names a field of this mode, JI-K and JI-ROLE = 2.
JI-KEY.
    MOVE 0 TO JI-K
    MOVE JI-BP TO JI-Q
    ADD 1 TO JI-Q
    EVALUATE JI-MODE
        WHEN 1
            EVALUATE JI-SL
                WHEN 3
                    IF JI-BUF (JI-Q:3) = "bio"
                        MOVE 4 TO JI-K
                    END-IF
                WHEN 4
                    IF JI-BUF (JI-Q:4) = "body"
                        MOVE 8 TO JI-K
                    END-IF
                WHEN 5
                    EVALUATE JI-BUF (JI-Q:5)
                        WHEN "email"
                            MOVE 2 TO JI-K
                        WHEN "image"
                            MOVE 5 TO JI-K
                        WHEN "title"
                            MOVE 6 TO JI-K
                    END-EVALUATE
                WHEN 7
                    IF JI-BUF (JI-Q:7) = "tagList"
                        MOVE 9 TO JI-K
                        MOVE 0 TO JT-OK JT-N
                    END-IF
                WHEN 8
                    EVALUATE JI-BUF (JI-Q:8)
                        WHEN "username"
                            MOVE 1 TO JI-K
                        WHEN "password"
                            MOVE 3 TO JI-K
                    END-EVALUATE
                WHEN 11
                    IF JI-BUF (JI-Q:11) = "description"
                        MOVE 7 TO JI-K
                    END-IF
            END-EVALUATE
        WHEN 2
            IF JI-SL = 3
                IF JI-BUF (JI-Q:3) = "alg"
                    MOVE 10 TO JI-K
                END-IF
            END-IF
        WHEN 3
            IF JI-SL = 3
                EVALUATE JI-BUF (JI-Q:3)
                    WHEN "exp"
                        MOVE 11 TO JI-K
                    WHEN "nbf"
                        MOVE 12 TO JI-K
                    WHEN "iat"
                        MOVE 13 TO JI-K
                    WHEN "sub"
                        MOVE 14 TO JI-K
                END-EVALUATE
            END-IF
    END-EVALUATE
    IF JI-K > 0
        MOVE 2 TO JI-ROLE
    END-IF.

*> The string whose opening quote is at JI-P, unescaped into JI-BUF from JI-BP + 1; JI-SL is its length and
*> JI-P ends past the closing quote. Runs of plain bytes are copied in one MOVE each.
JI-STRING.
    ADD 1 TO JI-P
    MOVE JI-BP TO JI-O
    PERFORM UNTIL JI-ST < 0
        MOVE JI-P TO JI-Q
        PERFORM UNTIL JI-P >= JI-END OR L-JSRC (JI-P:1) = '"' OR L-JSRC (JI-P:1) = "\"
            ADD 1 TO JI-P
        END-PERFORM
        IF JI-P > JI-Q
            MOVE JI-P TO JI-N
            SUBTRACT JI-Q FROM JI-N
            MOVE L-JSRC (JI-Q:JI-N) TO JI-BUF (JI-O + 1:JI-N)
            ADD JI-N TO JI-O
        END-IF
        IF JI-P >= JI-END
            MOVE -1 TO JI-ST
            EXIT PARAGRAPH
        END-IF
        IF L-JSRC (JI-P:1) = '"'
            ADD 1 TO JI-P
            MOVE JI-O TO JI-SL
            SUBTRACT JI-BP FROM JI-SL
            EXIT PARAGRAPH
        END-IF
        PERFORM JI-ESCAPE
    END-PERFORM.

*> The escape whose backslash is at JI-P; JI-P ends past it.
JI-ESCAPE.
    ADD 1 TO JI-P
    IF JI-P >= JI-END
        MOVE -1 TO JI-ST
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO JI-O
    EVALUATE L-JSRC (JI-P:1)
        WHEN '"'
        WHEN "\"
        WHEN "/"
            MOVE L-JSRC (JI-P:1) TO JI-BUF (JI-O:1)
        WHEN "b"
            MOVE JI-CTL (1:1) TO JI-BUF (JI-O:1)
        WHEN "f"
            MOVE JI-CTL (2:1) TO JI-BUF (JI-O:1)
        WHEN "n"
            MOVE JI-CTL (3:1) TO JI-BUF (JI-O:1)
        WHEN "r"
            MOVE JI-CTL (4:1) TO JI-BUF (JI-O:1)
        WHEN "t"
            MOVE JI-CTL (5:1) TO JI-BUF (JI-O:1)
        WHEN "u"
            SUBTRACT 1 FROM JI-O
            PERFORM JI-UESC
        WHEN OTHER
            MOVE -1 TO JI-ST
            EXIT PARAGRAPH
    END-EVALUATE
    ADD 1 TO JI-P.

*> Four hex digits after the "u" at JI-P into JI-H1..JI-H4; JI-P ends on the last digit.
JI-HEX4.
    MOVE 5 TO JI-N
    PERFORM JI-ROOM
    IF JI-ST < 0
        EXIT PARAGRAPH
    END-IF
    ADD 1 TO JI-P
    MOVE L-JSRC (JI-P:1) TO JI-BX
    MOVE JI-HEX (JI-BV + 1) TO JI-H1
    ADD 1 TO JI-P
    MOVE L-JSRC (JI-P:1) TO JI-BX
    MOVE JI-HEX (JI-BV + 1) TO JI-H2
    ADD 1 TO JI-P
    MOVE L-JSRC (JI-P:1) TO JI-BX
    MOVE JI-HEX (JI-BV + 1) TO JI-H3
    ADD 1 TO JI-P
    MOVE L-JSRC (JI-P:1) TO JI-BX
    MOVE JI-HEX (JI-BV + 1) TO JI-H4
    IF JI-H1 < 0 OR JI-H2 < 0 OR JI-H3 < 0 OR JI-H4 < 0
        MOVE -1 TO JI-ST
    END-IF.

*> \uXXXX at JI-P (on the "u") as UTF-8, as Yojson writes it: a high surrogate must be followed by \u and a
*> low one, and the pair becomes one 4-byte sequence; a lone low surrogate is written as a 3-byte sequence.
*> With hex digits a b c d (code point a<<12 | b<<8 | c<<4 | d), the bytes are built from table lookups.
JI-UESC.
    PERFORM JI-HEX4
    IF JI-ST < 0
        EXIT PARAGRAPH
    END-IF
    EVALUATE TRUE
        WHEN JI-H1 = 0 AND JI-H2 = 0 AND JI-H3 < 8
            *> 0xxxxxxx
            MOVE JI-M16 (JI-H3 + 1) TO JI-W
            ADD JI-H4 TO JI-W
            PERFORM JI-PUT
        WHEN JI-H1 = 0 AND JI-H2 < 8
            *> 110bbbcc 10ccdddd
            MOVE 192 TO JI-W
            ADD JI-M4 (JI-H2 + 1) TO JI-W
            ADD JI-D4 (JI-H3 + 1) TO JI-W
            PERFORM JI-PUT
            MOVE 128 TO JI-W
            ADD JI-R16 (JI-H3 + 1) TO JI-W
            ADD JI-H4 TO JI-W
            PERFORM JI-PUT
        WHEN JI-H1 = 13 AND JI-H2 >= 8 AND JI-H2 <= 11
            MOVE JI-H2 TO JI-A2
            MOVE JI-H3 TO JI-A3
            MOVE JI-H4 TO JI-A4
            MOVE 3 TO JI-N
            PERFORM JI-ROOM
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            IF L-JSRC (JI-P + 1:2) NOT = "\u"
                MOVE -1 TO JI-ST
                EXIT PARAGRAPH
            END-IF
            ADD 2 TO JI-P
            PERFORM JI-HEX4
            IF JI-ST < 0
                EXIT PARAGRAPH
            END-IF
            IF JI-H1 NOT = 13 OR JI-H2 < 12
                MOVE -1 TO JI-ST
                EXIT PARAGRAPH
            END-IF
            *> code point 0x10000 + hi10 << 10 + lo10; u = its bits 16..20 = 1 + (b - 8) << 2 + c >> 2
            MOVE JI-A2 TO JI-U
            SUBTRACT 8 FROM JI-U
            MOVE JI-M4 (JI-U + 1) TO JI-U
            ADD JI-D4 (JI-A3 + 1) TO JI-U
            ADD 1 TO JI-U
            *> 11110uuu 10uuccdd 10ddbbcc 10ccdddd (the second b, c, d from the low surrogate)
            MOVE 240 TO JI-W
            ADD JI-D4 (JI-U + 1) TO JI-W
            PERFORM JI-PUT
            MOVE 128 TO JI-W
            ADD JI-R16 (JI-U + 1) TO JI-W
            ADD JI-R4 (JI-A3 + 1) TO JI-W
            ADD JI-D4 (JI-A4 + 1) TO JI-W
            PERFORM JI-PUT
            SUBTRACT 12 FROM JI-H2
            MOVE 128 TO JI-W
            ADD JI-R16 (JI-A4 + 1) TO JI-W
            ADD JI-M4 (JI-H2 + 1) TO JI-W
            ADD JI-D4 (JI-H3 + 1) TO JI-W
            PERFORM JI-PUT
            MOVE 128 TO JI-W
            ADD JI-R16 (JI-H3 + 1) TO JI-W
            ADD JI-H4 TO JI-W
            PERFORM JI-PUT
        WHEN OTHER
            *> 1110aaaa 10bbbbcc 10ccdddd
            MOVE 224 TO JI-W
            ADD JI-H1 TO JI-W
            PERFORM JI-PUT
            MOVE 128 TO JI-W
            ADD JI-M4 (JI-H2 + 1) TO JI-W
            ADD JI-D4 (JI-H3 + 1) TO JI-W
            PERFORM JI-PUT
            MOVE 128 TO JI-W
            ADD JI-R16 (JI-H3 + 1) TO JI-W
            ADD JI-H4 TO JI-W
            PERFORM JI-PUT
    END-EVALUATE.

*> Appends the low byte of JI-W (little-endian) to the string being unescaped.
JI-PUT.
    ADD 1 TO JI-O
    MOVE JI-WX (1:1) TO JI-BUF (JI-O:1).
