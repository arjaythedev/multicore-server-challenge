*> ================= jout: JSON rendering =================
*> Every render paragraph appends to L-OUT at OUT-LEN + 1 and advances OUT-LEN. Column c is RW-OFF (c) /
*> RW-LEN (c) in L-RB. This runs for every column of every row, so it keeps to native operations (see the top of
*> conduit.cob); only numbers of 10 digits or more, negative numbers and timestamps outside 2000-2099 take
*> decimal arithmetic.

*> Start-up: digit, escape and calendar tables.
INIT-JOUT-TABLES.
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 10
        COMPUTE JO-POW (JO-K) = 10 ** (10 - JO-K)
    END-PERFORM
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 16
        COMPUTE JO-STEP (JO-K) = 2 ** (16 - JO-K)
    END-PERFORM
    PERFORM VARYING JO-K FROM 0 BY 1 UNTIL JO-K > 99
        MOVE JO-K TO JO-ED2
        MOVE JO-ED2 TO JO-D2 (JO-K + 1)
    END-PERFORM
    PERFORM VARYING JO-K FROM 0 BY 1 UNTIL JO-K > 999
        MOVE JO-K TO JO-ED3
        MOVE JO-ED3 TO JO-D3 (JO-K + 1)
    END-PERFORM
    *> escapes: short forms for " \ newline CR tab, \u00xx (lower-case hex) for the other control bytes; every
    *> other byte, 0x7F and bytes >= 0x80 included, is copied as is
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 256
        MOVE 0 TO JO-ESC-N (JO-K)
    END-PERFORM
    PERFORM VARYING JO-K FROM 0 BY 1 UNTIL JO-K > 31
        DIVIDE JO-K BY 16 GIVING JO-SI REMAINDER JO-SJ
        MOVE 6 TO JO-ESC-N (JO-K + 1)
        STRING "\u00" JO-HEX (JO-SI + 1:1) JO-HEX (JO-SJ + 1:1) DELIMITED BY SIZE INTO JO-ESC-T (JO-K + 1)
    END-PERFORM
    MOVE 2 TO JO-ESC-N (10) JO-ESC-N (11) JO-ESC-N (14) JO-ESC-N (35) JO-ESC-N (93)
    MOVE "\t" TO JO-ESC-T (10)
    MOVE "\n" TO JO-ESC-T (11)
    MOVE "\r" TO JO-ESC-T (14)
    MOVE '\"' TO JO-ESC-T (35)
    MOVE "\\" TO JO-ESC-T (93)
    *> one entry per day of 2000-2099 (2000 is a leap year and 2100 is outside, so every fourth year is one)
    MOVE 0 TO JO-SA
    MOVE 1 TO JO-K
    PERFORM VARYING JO-SYEAR FROM 2000 BY 1 UNTIL JO-SYEAR > 2099
        PERFORM VARYING JO-SMON FROM 1 BY 1 UNTIL JO-SMON > 12
            MOVE JO-MDAY (JO-SMON) TO JO-SMLEN
            IF JO-SMON = 2 AND FUNCTION MOD (JO-SYEAR, 4) = 0
                ADD 1 TO JO-SMLEN
            END-IF
            PERFORM VARYING JO-SJ FROM 1 BY 1 UNTIL JO-SJ > JO-SMLEN
                MOVE JO-SA TO JO-DAY-US (JO-K)
                MOVE JO-SYEAR TO JO-ED4
                MOVE JO-ED4 TO JO-DAY-TXT (JO-K) (1:4)
                MOVE "-" TO JO-DAY-TXT (JO-K) (5:1)
                MOVE JO-SMON TO JO-ED2
                MOVE JO-ED2 TO JO-DAY-TXT (JO-K) (6:2)
                MOVE "-" TO JO-DAY-TXT (JO-K) (8:1)
                MOVE JO-SJ TO JO-ED2
                MOVE JO-ED2 TO JO-DAY-TXT (JO-K) (9:2)
                ADD 86400000000 TO JO-SA
                ADD 1 TO JO-K
            END-PERFORM
        END-PERFORM
    END-PERFORM
    MOVE JO-SA TO JO-TS-END
    PERFORM VARYING JO-K FROM JO-K BY 1 UNTIL JO-K > 65536
        MOVE 9223372036854775807 TO JO-DAY-US (JO-K)
    END-PERFORM
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 64
        IF JO-K <= 48
            COMPUTE JO-HH-US (JO-K) = (JO-K - 1) * 1800000000
            COMPUTE JO-SJ = JO-K - 1
            DIVIDE JO-SJ BY 2 GIVING JO-SI REMAINDER JO-SJ
            MOVE JO-D2 (JO-SI + 1) TO JO-HH-TXT (JO-K)
            COMPUTE JO-HH-MOFF (JO-K) = JO-SJ * 30
        ELSE
            MOVE 9223372036854775807 TO JO-HH-US (JO-K)
        END-IF
    END-PERFORM
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 32
        IF JO-K <= 30
            COMPUTE JO-MIN-US (JO-K) = (JO-K - 1) * 60000000
        ELSE
            MOVE 2147483647 TO JO-MIN-US (JO-K)
        END-IF
    END-PERFORM
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 64
        IF JO-K <= 60
            COMPUTE JO-SEC-US (JO-K) = (JO-K - 1) * 1000000
        ELSE
            MOVE 2147483647 TO JO-SEC-US (JO-K)
        END-IF
    END-PERFORM
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 1024
        IF JO-K <= 1000
            COMPUTE JO-MS-US (JO-K) = (JO-K - 1) * 1000
        ELSE
            MOVE 2147483647 TO JO-MS-US (JO-K)
        END-IF
    END-PERFORM.

*> ---------- numbers ----------

*> Content-Length for RESPOND.
NUM-FMT.
    MOVE NUM-IN TO JO-U
    PERFORM JO-FMT-L
    MOVE JO-NUM (JO-NUM-OFF:JO-NUM-LEN) TO NUM-TXT (1:JO-NUM-LEN)
    MOVE JO-NUM-LEN TO NUM-TXT-LEN.

JO-INT.
    MOVE JO-INT-V TO JO-D
    PERFORM JO-FMT-D
    PERFORM JO-PUT-NUM.

*> int8, big-endian
JO-COL-INT8.
    MOVE RW-OFF (JO-C) TO JO-P
    MOVE L-RB (JO-P:1) TO JO-D-X (8:1)
    MOVE L-RB (JO-P + 1:1) TO JO-D-X (7:1)
    MOVE L-RB (JO-P + 2:1) TO JO-D-X (6:1)
    MOVE L-RB (JO-P + 3:1) TO JO-D-X (5:1)
    MOVE L-RB (JO-P + 4:1) TO JO-D-X (4:1)
    MOVE L-RB (JO-P + 5:1) TO JO-D-X (3:1)
    MOVE L-RB (JO-P + 6:1) TO JO-D-X (2:1)
    MOVE L-RB (JO-P + 7:1) TO JO-D-X (1:1)
    PERFORM JO-FMT-D
    PERFORM JO-PUT-NUM.

JO-PUT-NUM.
    MOVE JO-NUM (JO-NUM-OFF:JO-NUM-LEN) TO L-OUT (OUT-LEN + 1:JO-NUM-LEN)
    ADD JO-NUM-LEN TO OUT-LEN.

*> JO-D in decimal. Up to 2 ** 31 - 1 it is formatted from its low half; up to 10 digits the leading digit is
*> taken off by subtracting 1e9 (a 32-bit source); anything else goes through a display field.
JO-FMT-D.
    IF JO-D >= 0
        IF JO-D <= 2147483647
            MOVE JO-D-LO TO JO-U
            PERFORM JO-FMT-L
            EXIT PARAGRAPH
        END-IF
        IF JO-D < 10000000000
            MOVE 1 TO JO-DG
            PERFORM UNTIL JO-D < JO-K-1E9
                SUBTRACT JO-K-1E9 FROM JO-D
                ADD 1 TO JO-DG
            END-PERFORM
            MOVE JO-DIGITS (JO-DG:1) TO JO-NUM (11:1)
            MOVE JO-D-LO TO JO-U
            MOVE 2 TO JO-K
            PERFORM JO-FMT-RUN
            MOVE 11 TO JO-NUM-OFF
            MOVE 10 TO JO-NUM-LEN
            EXIT PARAGRAPH
        END-IF
    END-IF
    MOVE 0 TO JO-NEG
    IF JO-D < 0
        MOVE 1 TO JO-NEG
    END-IF
    MOVE JO-D TO JO-BIG
    MOVE JO-BIG TO JO-NUM (2:19)
    MOVE 2 TO JO-NUM-OFF
    PERFORM UNTIL JO-NUM-OFF = 20 OR JO-NUM (JO-NUM-OFF:1) NOT = "0"
        ADD 1 TO JO-NUM-OFF
    END-PERFORM
    IF JO-NEG = 1
        SUBTRACT 1 FROM JO-NUM-OFF
        MOVE JO-K-MINUS TO JO-NUM (JO-NUM-OFF:1)
    END-IF
    MOVE 21 TO JO-NUM-LEN
    SUBTRACT JO-NUM-OFF FROM JO-NUM-LEN.

*> JO-U (>= 0) in decimal, without leading zeros.
JO-FMT-L.
    IF JO-U < 100
        IF JO-U < 10
            MOVE JO-DIGITS (JO-U + 1:1) TO JO-NUM (20:1)
            MOVE 20 TO JO-NUM-OFF
            MOVE 1 TO JO-NUM-LEN
        ELSE
            MOVE JO-D2 (JO-U + 1) TO JO-NUM (19:2)
            MOVE 19 TO JO-NUM-OFF
            MOVE 2 TO JO-NUM-LEN
        END-IF
        EXIT PARAGRAPH
    END-IF
    MOVE 1 TO JO-K
    PERFORM UNTIL JO-POW (JO-K) <= JO-U
        ADD 1 TO JO-K
    END-PERFORM
    MOVE JO-K TO JO-NUM-OFF
    ADD 10 TO JO-NUM-OFF
    PERFORM JO-FMT-RUN
    MOVE 21 TO JO-NUM-LEN
    SUBTRACT JO-NUM-OFF FROM JO-NUM-LEN.

*> The digits of JO-U for the powers JO-POW (JO-K) down to 100, each counted by subtraction and written at
*> JO-NUM (JO-K + 10), then the last two from the table.
JO-FMT-RUN.
    PERFORM UNTIL JO-K > 8
        MOVE 1 TO JO-DG
        PERFORM UNTIL JO-U < JO-POW (JO-K)
            SUBTRACT JO-POW (JO-K) FROM JO-U
            ADD 1 TO JO-DG
        END-PERFORM
        MOVE JO-DIGITS (JO-DG:1) TO JO-NUM (JO-K + 10:1)
        ADD 1 TO JO-K
    END-PERFORM
    MOVE JO-D2 (JO-U + 1) TO JO-NUM (19:2).

*> ---------- booleans ----------

JO-COL-BOOL.
    MOVE RW-OFF (JO-C) TO JO-P
    IF L-RB (JO-P:1) = X"00"
        MOVE JO-K-FALSE TO L-OUT (OUT-LEN + 1:5)
        ADD 5 TO OUT-LEN
    ELSE
        MOVE JO-K-TRUE TO L-OUT (OUT-LEN + 1:4)
        ADD 4 TO OUT-LEN
    END-IF.

JO-BOOL.
    IF JO-BOOL-V = 0
        MOVE JO-K-FALSE TO L-OUT (OUT-LEN + 1:5)
        ADD 5 TO OUT-LEN
    ELSE
        MOVE JO-K-TRUE TO L-OUT (OUT-LEN + 1:4)
        ADD 4 TO OUT-LEN
    END-IF.

*> ---------- strings ----------

JO-COL.
    SET ADDRESS OF L-JS TO ADDRESS OF L-RB
    MOVE RW-OFF (JO-C) TO JO-S-OFF
    MOVE RW-LEN (JO-C) TO JO-S-LEN
    PERFORM JO-ESC.

JO-COL-OPT.
    IF RW-LEN (JO-C) = -1
        MOVE JO-K-NULL TO L-OUT (OUT-LEN + 1:4)
        ADD 4 TO OUT-LEN
    ELSE
        PERFORM JO-COL
    END-IF.

JO-STR.
    SET ADDRESS OF L-JS TO ADDRESS OF L-SRC
    MOVE JO-OFF TO JO-S-OFF
    MOVE JO-LEN TO JO-S-LEN
    PERFORM JO-ESC.

*> L-JS (JO-S-OFF:JO-S-LEN) in quotes. A string with nothing to escape (the usual case) is found by one class
*> test and copied in one MOVE.
JO-ESC.
    MOVE JO-K-QUOTE TO L-OUT (OUT-LEN + 1:1)
    ADD 1 TO OUT-LEN
    IF JO-S-LEN > 0
        IF L-JS (JO-S-OFF:JO-S-LEN) IS JSON-PLAIN
            MOVE L-JS (JO-S-OFF:JO-S-LEN) TO L-OUT (OUT-LEN + 1:JO-S-LEN)
            ADD JO-S-LEN TO OUT-LEN
        ELSE
            PERFORM JO-ESC-BYTES
        END-IF
    END-IF
    MOVE JO-K-QUOTE TO L-OUT (OUT-LEN + 1:1)
    ADD 1 TO OUT-LEN.

*> Byte by byte: runs of plain bytes are copied whole, the others replaced from the table.
JO-ESC-BYTES.
    MOVE JO-S-OFF TO JO-RUN
    MOVE JO-S-OFF TO JO-S-END
    ADD JO-S-LEN TO JO-S-END
    PERFORM VARYING JO-I FROM JO-S-OFF BY 1 UNTIL JO-I >= JO-S-END
        MOVE L-JS (JO-I:1) TO JO-BX
        IF JO-ESC-N (JO-BV + 1) > 0
            IF JO-I > JO-RUN
                MOVE JO-I TO JO-RL
                SUBTRACT JO-RUN FROM JO-RL
                MOVE L-JS (JO-RUN:JO-RL) TO L-OUT (OUT-LEN + 1:JO-RL)
                ADD JO-RL TO OUT-LEN
            END-IF
            MOVE JO-ESC-T (JO-BV + 1) (1:JO-ESC-N (JO-BV + 1)) TO L-OUT (OUT-LEN + 1:JO-ESC-N (JO-BV + 1))
            ADD JO-ESC-N (JO-BV + 1) TO OUT-LEN
            MOVE JO-I TO JO-RUN
            ADD 1 TO JO-RUN
        END-IF
    END-PERFORM
    IF JO-S-END > JO-RUN
        MOVE JO-S-END TO JO-RL
        SUBTRACT JO-RUN FROM JO-RL
        MOVE L-JS (JO-RUN:JO-RL) TO L-OUT (OUT-LEN + 1:JO-RL)
        ADD JO-RL TO OUT-LEN
    END-IF.

*> text[] in binary (int32 ndim, has_null, element oid, size and lower bound per dimension, then int32 length
*> and bytes per element) as comma-separated strings, without brackets; the element count is the first
*> dimension's size, and ndim 0 writes nothing. A NULL element (length -1) is written as "".
JO-COL-TAGS.
    SET ADDRESS OF L-JS TO ADDRESS OF L-RB
    MOVE RW-OFF (JO-C) TO JO-P
    PERFORM JO-GET-I32
    IF JO-L <= 0
        EXIT PARAGRAPH
    END-IF
    MOVE JO-L TO JO-Q
    ADD 12 TO JO-P
    PERFORM JO-GET-I32
    MOVE JO-L TO JO-N
    PERFORM JO-Q TIMES
        ADD 8 TO JO-P
    END-PERFORM
    MOVE 1 TO JO-FIRST
    PERFORM JO-N TIMES
        PERFORM JO-GET-I32
        ADD 4 TO JO-P
        IF JO-FIRST = 1
            MOVE 0 TO JO-FIRST
        ELSE
            MOVE JO-K-COMMA TO L-OUT (OUT-LEN + 1:1)
            ADD 1 TO OUT-LEN
        END-IF
        MOVE JO-P TO JO-S-OFF
        IF JO-L > 0
            MOVE JO-L TO JO-S-LEN
            ADD JO-L TO JO-P
        ELSE
            MOVE 0 TO JO-S-LEN
        END-IF
        PERFORM JO-ESC
    END-PERFORM.

*> JO-L = the big-endian int32 at L-RB (JO-P)
JO-GET-I32.
    MOVE L-RB (JO-P:1) TO JO-L-X (4:1)
    MOVE L-RB (JO-P + 1:1) TO JO-L-X (3:1)
    MOVE L-RB (JO-P + 2:1) TO JO-L-X (2:1)
    MOVE L-RB (JO-P + 3:1) TO JO-L-X (1:1).

*> ---------- timestamps ----------

JO-COL-TS.
    MOVE RW-OFF (JO-C) TO JO-P
    MOVE L-RB (JO-P:1) TO JO-US-X (8:1)
    MOVE L-RB (JO-P + 1:1) TO JO-US-X (7:1)
    MOVE L-RB (JO-P + 2:1) TO JO-US-X (6:1)
    MOVE L-RB (JO-P + 3:1) TO JO-US-X (5:1)
    MOVE L-RB (JO-P + 4:1) TO JO-US-X (4:1)
    MOVE L-RB (JO-P + 5:1) TO JO-US-X (3:1)
    MOVE L-RB (JO-P + 6:1) TO JO-US-X (2:1)
    MOVE L-RB (JO-P + 7:1) TO JO-US-X (1:1)
    PERFORM JO-TS.

*> JO-US as "YYYY-MM-DDTHH:MM:SS.mmmZ" in quotes, truncated to the millisecond.
JO-TS.
    IF JO-US < 0 OR JO-US >= JO-TS-END
        PERFORM JO-TS-SLOW
    ELSE
        PERFORM JO-TS-FAST
    END-IF
    MOVE JO-TS-X TO L-OUT (OUT-LEN + 1:26)
    ADD 26 TO OUT-LEN.

JO-TS-FAST.
    *> the last day that starts at or before JO-US
    MOVE 1 TO JO-PD
    PERFORM VARYING JO-K FROM 1 BY 1 UNTIL JO-K > 16
        MOVE JO-PD TO JO-Q
        ADD JO-STEP (JO-K) TO JO-Q
        IF JO-DAY-US (JO-Q) <= JO-US
            MOVE JO-Q TO JO-PD
        END-IF
    END-PERFORM
    MOVE JO-DAY-TXT (JO-PD) TO JO-TS-DATE
    *> JO-DF = JO-US - the day's start, on the halves with a borrow
    MOVE JO-US-LO TO JO-DF-LO
    SUBTRACT JO-DAY-LO (JO-PD) FROM JO-DF-LO
    MOVE JO-US-HI TO JO-DF-HI
    SUBTRACT JO-DAY-HI (JO-PD) FROM JO-DF-HI
    IF JO-US-LO < JO-DAY-LO (JO-PD)
        SUBTRACT 1 FROM JO-DF-HI
    END-IF
    *> the half hour; what is left is under 1.8e9, so the difference of the low halves is exact
    MOVE 1 TO JO-PH
    PERFORM VARYING JO-K FROM 11 BY 1 UNTIL JO-K > 16
        MOVE JO-PH TO JO-Q
        ADD JO-STEP (JO-K) TO JO-Q
        IF JO-HH-US (JO-Q) <= JO-DF
            MOVE JO-Q TO JO-PH
        END-IF
    END-PERFORM
    MOVE JO-HH-TXT (JO-PH) TO JO-TS-HH
    MOVE JO-DF-LO TO JO-R-U
    SUBTRACT JO-HH-LO (JO-PH) FROM JO-R-U
    MOVE 1 TO JO-PM
    PERFORM VARYING JO-K FROM 12 BY 1 UNTIL JO-K > 16
        MOVE JO-PM TO JO-Q
        ADD JO-STEP (JO-K) TO JO-Q
        IF JO-MIN-US (JO-Q) <= JO-R-S
            MOVE JO-Q TO JO-PM
        END-IF
    END-PERFORM
    SUBTRACT JO-MIN-US (JO-PM) FROM JO-R-S
    MOVE JO-PM TO JO-Q
    ADD JO-HH-MOFF (JO-PH) TO JO-Q
    MOVE JO-D2 (JO-Q) TO JO-TS-MI
    MOVE 1 TO JO-PS
    PERFORM VARYING JO-K FROM 11 BY 1 UNTIL JO-K > 16
        MOVE JO-PS TO JO-Q
        ADD JO-STEP (JO-K) TO JO-Q
        IF JO-SEC-US (JO-Q) <= JO-R-S
            MOVE JO-Q TO JO-PS
        END-IF
    END-PERFORM
    SUBTRACT JO-SEC-US (JO-PS) FROM JO-R-S
    MOVE JO-D2 (JO-PS) TO JO-TS-SS
    MOVE 1 TO JO-PMS
    PERFORM VARYING JO-K FROM 7 BY 1 UNTIL JO-K > 16
        MOVE JO-PMS TO JO-Q
        ADD JO-STEP (JO-K) TO JO-Q
        IF JO-MS-US (JO-Q) <= JO-R-S
            MOVE JO-Q TO JO-PMS
        END-IF
    END-PERFORM
    MOVE JO-D3 (JO-PMS) TO JO-TS-MS.

*> Any other instant: floor division, then civil_from_days. Each output digit is the byte 48 + n, unchecked, so
*> a year outside 0-9999 gives bytes that are not digits rather than a longer field.
JO-TS-SLOW.
    MOVE 1000 TO JO-SN
    MOVE JO-US TO JO-SA
    PERFORM JO-FDIV
    MOVE JO-SQ TO JO-SMS
    MOVE JO-SMS TO JO-SA
    PERFORM JO-FDIV
    MOVE JO-SQ TO JO-SSECS
    COMPUTE JO-SMS = JO-SMS - JO-SSECS * 1000
    MOVE 86400 TO JO-SN
    MOVE JO-SSECS TO JO-SA
    PERFORM JO-FDIV
    MOVE JO-SQ TO JO-SDAYS
    COMPUTE JO-SSOD = JO-SSECS - JO-SDAYS * 86400
    COMPUTE JO-SZ = JO-SDAYS + 10957 + 719468
    MOVE 146097 TO JO-SN
    MOVE JO-SZ TO JO-SA
    PERFORM JO-FDIV
    MOVE JO-SQ TO JO-SERA
    COMPUTE JO-SDOE = JO-SZ - JO-SERA * 146097
    DIVIDE JO-SDOE BY 1460 GIVING JO-ST1
    DIVIDE JO-SDOE BY 36524 GIVING JO-ST2
    DIVIDE JO-SDOE BY 146096 GIVING JO-ST3
    COMPUTE JO-ST4 = JO-SDOE - JO-ST1 + JO-ST2 - JO-ST3
    DIVIDE JO-ST4 BY 365 GIVING JO-SYOE
    DIVIDE JO-SYOE BY 4 GIVING JO-ST1
    DIVIDE JO-SYOE BY 100 GIVING JO-ST2
    COMPUTE JO-SDOY = JO-SDOE - (365 * JO-SYOE + JO-ST1 - JO-ST2)
    COMPUTE JO-ST4 = 5 * JO-SDOY + 2
    DIVIDE JO-ST4 BY 153 GIVING JO-SMP
    COMPUTE JO-ST4 = 153 * JO-SMP + 2
    DIVIDE JO-ST4 BY 5 GIVING JO-ST1
    COMPUTE JO-SD = JO-SDOY - JO-ST1 + 1
    IF JO-SMP < 10
        COMPUTE JO-SM = JO-SMP + 3
    ELSE
        COMPUTE JO-SM = JO-SMP - 9
    END-IF
    COMPUTE JO-SY = JO-SYOE + JO-SERA * 400
    IF JO-SM <= 2
        ADD 1 TO JO-SY
    END-IF
    DIVIDE JO-SY BY 100 GIVING JO-SV
    MOVE 2 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    COMPUTE JO-SV = FUNCTION REM (JO-SY, 100)
    MOVE 4 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    MOVE "-" TO JO-TS-X (6:1)
    MOVE JO-SM TO JO-SV
    MOVE 7 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    MOVE "-" TO JO-TS-X (9:1)
    MOVE JO-SD TO JO-SV
    MOVE 10 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    DIVIDE JO-SSOD BY 3600 GIVING JO-SV
    MOVE 13 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    DIVIDE JO-SSOD BY 60 GIVING JO-SV
    COMPUTE JO-SV = FUNCTION REM (JO-SV, 60)
    MOVE 16 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    COMPUTE JO-SV = FUNCTION REM (JO-SSOD, 60)
    MOVE 19 TO JO-SPOS
    PERFORM JO-SLOW-TWO
    DIVIDE JO-SMS BY 100 GIVING JO-SA
    MOVE 22 TO JO-SPOS
    PERFORM JO-SLOW-DIGIT
    COMPUTE JO-SV = FUNCTION REM (JO-SMS, 100)
    MOVE 23 TO JO-SPOS
    PERFORM JO-SLOW-TWO.

*> JO-SQ = floor (JO-SA / JO-SN), JO-SN > 0
JO-FDIV.
    DIVIDE JO-SA BY JO-SN GIVING JO-SQ REMAINDER JO-SR
    IF JO-SR < 0
        SUBTRACT 1 FROM JO-SQ
    END-IF.

*> JO-SV / 10 and JO-SV mod 10 (both truncating) as digit bytes at JO-SPOS and JO-SPOS + 1
JO-SLOW-TWO.
    DIVIDE JO-SV BY 10 GIVING JO-SA
    PERFORM JO-SLOW-DIGIT
    COMPUTE JO-SA = FUNCTION REM (JO-SV, 10)
    ADD 1 TO JO-SPOS
    PERFORM JO-SLOW-DIGIT.

*> byte 48 + JO-SA (modulo 256, as a char store keeps the low byte) at JO-TS-X (JO-SPOS)
JO-SLOW-DIGIT.
    COMPUTE JO-SBV = FUNCTION MOD (48 + JO-SA, 256)
    MOVE JO-SBX TO JO-TS-X (JO-SPOS:1).
