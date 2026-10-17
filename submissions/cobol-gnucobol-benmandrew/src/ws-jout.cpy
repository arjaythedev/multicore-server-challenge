*> ---------- jout: JSON rendering into L-OUT ----------
*> Every render paragraph appends to L-OUT at OUT-LEN + 1 and advances OUT-LEN. Inputs: JO-C, the column for
*> the JO-COL paragraphs (c = column number + 1); JO-OFF / JO-LEN, the text in L-SRC for JO-STR; JO-INT-V for
*> JO-INT; JO-BOOL-V (0 or 1) for JO-BOOL. NUM-FMT writes NUM-IN (>= 0) to NUM-TXT (1:NUM-TXT-LEN) instead.
01 OUT-LEN           BINARY-LONG.
01 JO-C              BINARY-LONG.
01 JO-OFF            BINARY-LONG.
01 JO-LEN            BINARY-LONG.
01 JO-INT-V          BINARY-DOUBLE.
01 JO-BOOL-V         BINARY-LONG.
01 NUM-IN            BINARY-LONG.
01 NUM-TXT           PIC X(20).
01 NUM-TXT-LEN       BINARY-LONG.

*> Literals as fields: a MOVE from a field of the target's length is a memcpy, a MOVE of a literal is not.
01 JO-K-QUOTE        PIC X VALUE '"'.
01 JO-K-COMMA        PIC X VALUE ','.
01 JO-K-MINUS        PIC X VALUE '-'.
01 JO-K-TRUE         PIC X(4) VALUE 'true'.
01 JO-K-FALSE        PIC X(5) VALUE 'false'.
01 JO-K-NULL         PIC X(4) VALUE 'null'.
01 JO-K-1E9          BINARY-LONG VALUE 1000000000.

*> ---------- numbers ----------
*> JO-FMT-L formats JO-U (>= 0), JO-FMT-D formats JO-D (any value): the text is JO-NUM (JO-NUM-OFF:JO-NUM-LEN),
*> right-aligned in JO-NUM. Both clobber their input.
01 JO-U              BINARY-LONG.
01 JO-D              BINARY-DOUBLE.
01 JO-D-X REDEFINES JO-D PIC X(8).
01 JO-D-PARTS REDEFINES JO-D.
   05 JO-D-LO        BINARY-LONG.
   05 FILLER         BINARY-LONG.
01 JO-NUM            PIC X(20).
01 JO-NUM-OFF        BINARY-LONG.
01 JO-NUM-LEN        BINARY-LONG.
01 JO-K              BINARY-LONG.
01 JO-DG             BINARY-LONG.
*> numbers too large or negative for the native path go through a display field (MOVE keeps the absolute value)
01 JO-BIG            PIC 9(19).
01 JO-NEG            BINARY-LONG.
*> JO-POW (k) = 10 ** (10 - k)
01 JO-POWS.
   05 JO-POW         BINARY-LONG OCCURS 10.
01 JO-DIGITS         PIC X(10) VALUE "0123456789".
*> JO-D2 (n + 1) is n in two digits, JO-D3 (n + 1) in three
01 JO-D2-TABLE.
   05 JO-D2          PIC X(2) OCCURS 100.
01 JO-D3-TABLE.
   05 JO-D3          PIC X(3) OCCURS 1000.

*> ---------- strings ----------
*> JO-ESC writes L-JS (JO-S-OFF:JO-S-LEN) as a JSON string.
01 JO-S-OFF          BINARY-LONG.
01 JO-S-LEN          BINARY-LONG.
01 JO-S-END          BINARY-LONG.
01 JO-I              BINARY-LONG.
01 JO-RUN            BINARY-LONG.
01 JO-RL             BINARY-LONG.
01 JO-BV             BINARY-CHAR UNSIGNED.
01 JO-BX REDEFINES JO-BV PIC X.
*> per byte (index byte + 1): the escape and its length, 0 for a byte copied as is
01 JO-ESC-TABLE.
   05 JO-ESC-E OCCURS 256.
      10 JO-ESC-N    BINARY-LONG.
      10 JO-ESC-T    PIC X(6).
01 JO-HEX            PIC X(16) VALUE "0123456789abcdef".

*> ---------- binary columns ----------
01 JO-P              BINARY-LONG.
01 JO-N              BINARY-LONG.
01 JO-L              BINARY-LONG.
01 JO-L-X REDEFINES JO-L PIC X(4).
01 JO-FIRST          BINARY-LONG.

*> ---------- timestamps ----------
*> Microseconds since 2000-01-01 UTC. A value in 2000-2099 is placed by binary search: its day in JO-DAY, then
*> its half hour, minute, second and millisecond in small tables. The searches compare 64-bit fields; the
*> subtractions are on 32-bit halves, because ADD and SUBTRACT with a 64-bit source are not native. The
*> remainder after the day is under 2 ** 37 and is put together from the halves with a borrow; after the half
*> hour it is under 1.8e9, so its low half alone is exact.
01 JO-US             BINARY-DOUBLE.
01 JO-US-X REDEFINES JO-US PIC X(8).
01 JO-US-PARTS REDEFINES JO-US.
   05 JO-US-LO       BINARY-LONG UNSIGNED.
   05 JO-US-HI       BINARY-LONG.
01 JO-DF             BINARY-DOUBLE.
01 JO-DF-PARTS REDEFINES JO-DF.
   05 JO-DF-LO       BINARY-LONG UNSIGNED.
   05 JO-DF-HI       BINARY-LONG.
01 JO-R-U            BINARY-LONG UNSIGNED.
01 JO-R-S REDEFINES JO-R-U BINARY-LONG.
01 JO-Q              BINARY-LONG.
01 JO-PD             BINARY-LONG.
01 JO-PH             BINARY-LONG.
01 JO-PM             BINARY-LONG.
01 JO-PS             BINARY-LONG.
01 JO-PMS            BINARY-LONG.
*> start of 2100-01-01: the end of the table
01 JO-TS-END         BINARY-DOUBLE.
*> binary search steps: JO-STEP (k) = 2 ** (16 - k)
01 JO-STEPS.
   05 JO-STEP        BINARY-LONG OCCURS 16.
*> day i (1 = 2000-01-01) starts at JO-DAY-US (i); entries past 2099-12-31 hold the largest value, so a search
*> never stops there
01 JO-DAY-TABLE.
   05 JO-DAY OCCURS 65536.
      10 JO-DAY-US   BINARY-DOUBLE.
      10 JO-DAY-PARTS REDEFINES JO-DAY-US.
         15 JO-DAY-LO BINARY-LONG UNSIGNED.
         15 JO-DAY-HI BINARY-LONG.
01 JO-DTXT-TABLE.
   05 JO-DAY-TXT     PIC X(10) OCCURS 36525.
*> half hour h of a day starts at JO-HH-US (h); its hour as text, and 0 or 30 to add to the minute index
01 JO-HH-TABLE.
   05 JO-HH OCCURS 64.
      10 JO-HH-US    BINARY-DOUBLE.
      10 JO-HH-PARTS REDEFINES JO-HH-US.
         15 JO-HH-LO BINARY-LONG UNSIGNED.
         15 FILLER   BINARY-LONG.
      10 JO-HH-TXT   PIC X(2).
      10 JO-HH-MOFF  BINARY-LONG.
01 JO-MIN-TABLE.
   05 JO-MIN-US      BINARY-LONG OCCURS 32.
01 JO-SEC-TABLE.
   05 JO-SEC-US      BINARY-LONG OCCURS 64.
01 JO-MS-TABLE.
   05 JO-MS-US       BINARY-LONG OCCURS 1024.
*> "YYYY-MM-DDTHH:MM:SS.mmmZ" with its quotes, filled in place and copied in one MOVE
01 JO-TS-BUF.
   05 FILLER         PIC X VALUE '"'.
   05 JO-TS-DATE     PIC X(10).
   05 FILLER         PIC X VALUE 'T'.
   05 JO-TS-HH       PIC X(2).
   05 FILLER         PIC X VALUE ':'.
   05 JO-TS-MI       PIC X(2).
   05 FILLER         PIC X VALUE ':'.
   05 JO-TS-SS       PIC X(2).
   05 FILLER         PIC X VALUE '.'.
   05 JO-TS-MS       PIC X(3).
   05 FILLER         PIC X(2) VALUE 'Z"'.
01 JO-TS-X REDEFINES JO-TS-BUF PIC X(26).
*> the slow path (and table building): Hinnant's civil_from_days
01 JO-SA             BINARY-DOUBLE.
01 JO-SN             BINARY-DOUBLE.
01 JO-SQ             BINARY-DOUBLE.
01 JO-SR             BINARY-DOUBLE.
01 JO-SMS            BINARY-DOUBLE.
01 JO-SSECS          BINARY-DOUBLE.
01 JO-SDAYS          BINARY-DOUBLE.
01 JO-SSOD           BINARY-DOUBLE.
01 JO-SZ             BINARY-DOUBLE.
01 JO-SERA           BINARY-DOUBLE.
01 JO-SDOE           BINARY-DOUBLE.
01 JO-SYOE           BINARY-DOUBLE.
01 JO-SDOY           BINARY-DOUBLE.
01 JO-SMP            BINARY-DOUBLE.
01 JO-ST1            BINARY-DOUBLE.
01 JO-ST2            BINARY-DOUBLE.
01 JO-ST3            BINARY-DOUBLE.
01 JO-ST4            BINARY-DOUBLE.
01 JO-SY             BINARY-DOUBLE.
01 JO-SM             BINARY-DOUBLE.
01 JO-SD             BINARY-DOUBLE.
*> JO-SLOW-TWO writes JO-SV at JO-TS-X (JO-SPOS:2) as two digit bytes, JO-SV / 10 and JO-SV mod 10
01 JO-SV             BINARY-DOUBLE.
01 JO-SPOS           BINARY-LONG.
01 JO-SBV            BINARY-CHAR UNSIGNED.
01 JO-SBX REDEFINES JO-SBV PIC X.
01 JO-SI             BINARY-LONG.
01 JO-SJ             BINARY-LONG.
01 JO-SMLEN          BINARY-LONG.
01 JO-SYEAR          BINARY-LONG.
01 JO-SMON           BINARY-LONG.
01 JO-ED4            PIC 9(4).
01 JO-ED2            PIC 9(2).
01 JO-ED3            PIC 9(3).
01 JO-MDAYS-V        PIC X(24) VALUE "312831303130313130313031".
01 JO-MDAYS REDEFINES JO-MDAYS-V.
   05 JO-MDAY        PIC 99 OCCURS 12.
