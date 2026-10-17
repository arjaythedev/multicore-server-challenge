*> ---------- jin: JSON parser ----------
*> Inputs. JI-MODE: 1 a request body (fields of the wrapper object whose key is JI-WRAP (1:JI-WRAP-LEN)), 2 a
*> JWT header, 3 JWT claims. The text is L-JSRC (JI-SRC-OFF:JI-SRC-LEN).
01 JI-MODE           BINARY-LONG.
01 JI-WRAP           PIC X(16).
01 JI-WRAP-LEN       BINARY-LONG.
01 JI-SRC-OFF        BINARY-LONG.
01 JI-SRC-LEN        BINARY-LONG.

*> Outputs. JI-OK is 1 if the whole text is one valid JSON value, JI-TOP-OBJ if that value is an object, and
*> JI-WRAP-OK (mode 1) if the last top-level member named by JI-WRAP has an object value. JF (k) is field k:
*> in mode 1, 1 username, 2 email, 3 password, 4 bio, 5 image, 6 title, 7 description, 8 body, 9 tagList, all
*> members of the wrapper object; in mode 2, 10 alg; in mode 3, 11 exp, 12 nbf, 13 iat, 14 sub. Keys are
*> compared after unescaping, and the last occurrence of a key wins. JF-T: 0 absent, 1 null, 2 string,
*> 3 true/false/object, 4 array, 5 number. Strings (unescaped) and number texts are at JI-BUF (JF-OFF (k):JF-LEN
*> (k)). When JF-T (9) = 4, JT holds the JT-N tagList elements the same way, and JT-OK is 1 if every element is
*> a non-empty string and there are at most 65536.
01 JI-OK             BINARY-LONG.
01 JI-TOP-OBJ        BINARY-LONG.
01 JI-WRAP-OK        BINARY-LONG.
01 JI-FIELDS.
   05 JF OCCURS 14.
      10 JF-T        BINARY-LONG.
      10 JF-OFF      BINARY-LONG.
      10 JF-LEN      BINARY-LONG.
01 JT-OK             BINARY-LONG.
01 JT-N              BINARY-LONG.
01 JT-TAB.
   05 JT OCCURS 65536.
      10 JT-OFF      BINARY-LONG.
      10 JT-LEN      BINARY-LONG.
*> Kept strings and number texts; JI-BP bytes are used. Each kept byte comes from a distinct source byte, so a
*> 1 MB body needs at most 1 MB here, plus the key being compared.
01 JI-BUF            PIC X(2097152).
01 JI-BP             BINARY-LONG.

*> ---------- parser state ----------
*> JI-ST: 1 a value is next, 2 a value has ended, 3 a member key is next, 0 done, -1 failed.
*> JI-ROLE, what the value being read means: 0 nothing, 1 the wrapper's value, 2 field JI-K, 3 a tagList
*> element, 9 the top value.
01 JI-ST             BINARY-LONG.
01 JI-ROLE           BINARY-LONG.
01 JI-K              BINARY-LONG.
01 JI-P              BINARY-LONG.
01 JI-Q              BINARY-LONG.
01 JI-N              BINARY-LONG.
01 JI-O              BINARY-LONG.
01 JI-END            BINARY-LONG.
01 JI-SL             BINARY-LONG.
01 JI-R              BINARY-LONG.
01 JI-DEPTH          BINARY-LONG.
*> One entry per open container. JI-SK: 1 object, 2 array. JI-SR, what its members mean: 0 nothing,
*> 1 top object, 2 wrapper object, 3 tagList array. Yojson has no depth limit short of the stack, so the
*> limit here is as deep as a 1 MB body can nest.
78 JI-MAX-DEPTH      VALUE 1048576.
01 JI-STACK.
   05 JI-SK          BINARY-CHAR UNSIGNED OCCURS 1048576.
   05 JI-SR          BINARY-CHAR UNSIGNED OCCURS 1048576.
01 JI-BV             BINARY-CHAR UNSIGNED.
01 JI-BX REDEFINES JI-BV PIC X.
*> an output byte, computed in the low byte of a native int
01 JI-W              BINARY-LONG.
01 JI-WX REDEFINES JI-W PIC X(4).
*> \u escapes: the four hex digits, and the high surrogate's last three
01 JI-H1             BINARY-LONG.
01 JI-H2             BINARY-LONG.
01 JI-H3             BINARY-LONG.
01 JI-H4             BINARY-LONG.
01 JI-A2             BINARY-LONG.
01 JI-A3             BINARY-LONG.
01 JI-A4             BINARY-LONG.
01 JI-U              BINARY-LONG.
*> what \b \f \n \r \t stand for, as a field so the MOVE is one byte store
01 JI-CTL            PIC X(5) VALUE X"080C0A0D09".

*> ---------- tables, built on the first JI-PARSE ----------
01 JI-READY          BINARY-LONG VALUE 0.
01 JI-TI             BINARY-LONG.
*> index byte + 1: the hex digit value or -1; 2 for an identifier's first byte, 1 for a later one, else 0
01 JI-HEX            BINARY-LONG OCCURS 256.
01 JI-ID             BINARY-LONG OCCURS 256.
*> index n + 1, n = 0..19: n * 16, n * 4, n / 4, (n mod 4) * 16, (n mod 4) * 4, for building UTF-8 bytes
*> from hex digits without shifts
01 JI-M16            BINARY-LONG OCCURS 20.
01 JI-M4             BINARY-LONG OCCURS 20.
01 JI-D4             BINARY-LONG OCCURS 20.
01 JI-R16            BINARY-LONG OCCURS 20.
01 JI-R4             BINARY-LONG OCCURS 20.
