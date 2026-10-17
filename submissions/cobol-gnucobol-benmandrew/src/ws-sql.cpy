*> ---------- sql: the prepared statements ----------
*> Statement n (1..32) is named s<n>; its text is SQ-AREA (SQ-OFF (n):SQ-LEN (n)).
01 SQ-COUNT          BINARY-LONG.
01 SQ-USED           BINARY-LONG.
01 SQ-AREA           PIC X(65536).
01 SQ-TABLE.
   05 SQ-ENT OCCURS 32.
      10 SQ-OFF      BINARY-LONG.
      10 SQ-LEN      BINARY-LONG.
      *> 1 when the text has no word INSERT, UPDATE or DELETE
      10 SQ-RO       BINARY-CHAR UNSIGNED.
      *> 1 when a parameter is a text[] (sent in binary)
      10 SQ-ARR      BINARY-CHAR UNSIGNED.
      10 SQ-NAME     PIC X(4).
      10 SQ-NAME-LEN BINARY-LONG.
      *> what a Bind for this statement holds after its length: the empty portal, the name, the format codes
      10 SQ-BH       PIC X(16).
      10 SQ-BH-LEN   BINARY-LONG.

*> start-up scratch: SQ-T is the text being built, SQ-TP the STRING pointer
01 SQ-T              PIC X(4096).
01 SQ-TP             BINARY-LONG.
01 SQ-TL             BINARY-LONG.
01 SQ-I              BINARY-LONG.
01 SQ-K              BINARY-LONG.
01 SQ-WORD           PIC X(16).
01 SQ-WLEN           BINARY-LONG.
01 SQ-NUM            PIC Z9.
*> fragments shared by several statements
01 SQ-FULL           PIC X(2048).
01 SQ-FULL-LEN       BINARY-LONG.
01 SQ-PC             PIC X(2048).
01 SQ-PC-LEN         BINARY-LONG.
01 SQ-PCFV           PIC X(2048).
01 SQ-PCFV-LEN       BINARY-LONG.
01 SQ-PCT            PIC X(2048).
01 SQ-PCT-LEN        BINARY-LONG.
01 SQ-FVJ            PIC X(256).
01 SQ-FVJ-LEN        BINARY-LONG.
01 SQ-PF             PIC X(80).
01 SQ-PF-LEN         BINARY-LONG.
01 SQ-SLUG2          PIC X(96).
01 SQ-SLUG2-LEN      BINARY-LONG.
01 SQ-TAGC           PIC X(512).
01 SQ-TAGC-LEN       BINARY-LONG.
01 SQ-AUTHC          PIC X(512).
01 SQ-AUTHC-LEN      BINARY-LONG.
01 SQ-FAVC           PIC X(512).
01 SQ-FAVC-LEN       BINARY-LONG.
01 SQ-FEEDC          PIC X(512).
01 SQ-FEEDC-LEN      BINARY-LONG.
*> arguments of SQ-PAGE-COLS (SQ-FV, SQ-FOL) and SQ-FILTERED (SQ-A1 cols, SQ-A2 join, SQ-A3 page, SQ-A4 count)
01 SQ-FV             BINARY-LONG.
01 SQ-FOL            PIC X(128).
01 SQ-FOL-LEN        BINARY-LONG.
01 SQ-A1             PIC X(2048).
01 SQ-A1-LEN         BINARY-LONG.
01 SQ-A2             PIC X(256).
01 SQ-A2-LEN         BINARY-LONG.
01 SQ-A3             PIC X(1024).
01 SQ-A3-LEN         BINARY-LONG.
01 SQ-A4             PIC X(512).
01 SQ-A4-LEN         BINARY-LONG.
