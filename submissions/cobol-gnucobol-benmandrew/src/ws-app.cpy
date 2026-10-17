*> ---------- handler codes (PB-H, RQ-H) ----------
78 H-K-TAGS          VALUE 1.
*> a list page; an empty one goes on to its count statement
78 H-K-LIST          VALUE 2.
78 H-K-COUNT         VALUE 3.
*> {"article":...} from whichever statement returns the row; 404 if none does
78 H-K-ARTICLE       VALUE 4.
*> the same with 201, after an insert whose RETURNING row (statement 1) is not the article
78 H-K-CREATED       VALUE 5.
78 H-K-COMMENTS      VALUE 6.
78 H-K-NEW-COMMENT   VALUE 7.
78 H-K-DEL-COMMENT   VALUE 8.
78 H-K-PROFILE       VALUE 9.
78 H-K-FOLLOW        VALUE 10.
78 H-K-UNFOLLOW      VALUE 11.
*> {"user":...} with the request's own token, kept in context item 1
78 H-K-USER          VALUE 12.
78 H-K-REGISTER      VALUE 13.
78 H-K-LOGIN         VALUE 14.
78 H-K-OWN-UPDATE    VALUE 15.
78 H-K-OWN-DELETE    VALUE 16.
78 H-K-DELETED       VALUE 17.

*> bcrypt steps (CN-STEP)
78 AP-STEP-REGISTER  VALUE 1.
78 AP-STEP-LOGIN     VALUE 2.
78 AP-STEP-UPDATE    VALUE 3.

01 AP-STATUS         BINARY-LONG.
*> 1 while answering from APP-DONE or APP-BC-DONE, where a response is followed by AFTER-RESPONSE
01 AP-ASYNC          BINARY-LONG.
01 AP-SAVE-LEN       BINARY-LONG.
*> the token AP-USER-ROW writes: L-SRC (AP-TOK-OFF:AP-TOK-LEN) at AP-TOK-PTR
01 AP-TOK-PTR        USAGE POINTER.
01 AP-TOK-OFF        BINARY-LONG.
01 AP-TOK-LEN        BINARY-LONG.
01 AP-K              BINARY-LONG.
01 AP-C              BINARY-LONG.
01 AP-I              BINARY-LONG.
01 AP-D64            BINARY-DOUBLE.
01 AP-D64-X REDEFINES AP-D64 PIC X(8).
01 AP-FOLLOWING      BINARY-LONG.
01 AP-ST             BINARY-LONG.
01 AP-OK             BINARY-LONG.
01 AP-HASH-PRES      BINARY-LONG.
*> the filter of a list: QV index (3 tag, 4 author, 5 favorited), 0 for none
01 AP-FILTER         BINARY-LONG.

*> JSON pieces, appended with MOVE ... (OUT-LEN + 1:LENGTH OF ...)
01 LIT-ARTICLES      PIC X(13)  VALUE '{"articles":['.
01 LIT-COUNT         PIC X(18)  VALUE '],"articlesCount":'.
01 LIT-NO-ARTICLES   PIC X(31)  VALUE '{"articles":[],"articlesCount":'.
01 LIT-ARTICLE       PIC X(11)  VALUE '{"article":'.
01 LIT-SLUG          PIC X(8)   VALUE '{"slug":'.
01 LIT-TITLE         PIC X(9)   VALUE ',"title":'.
01 LIT-DESC          PIC X(15)  VALUE ',"description":'.
01 LIT-BODY          PIC X(8)   VALUE ',"body":'.
01 LIT-TAGS          PIC X(12)  VALUE ',"tagList":['.
01 LIT-CREATED       PIC X(14)  VALUE '],"createdAt":'.
01 LIT-CREATED2      PIC X(13)  VALUE ',"createdAt":'.
01 LIT-UPDATED       PIC X(13)  VALUE ',"updatedAt":'.
01 LIT-FAVORITED     PIC X(13)  VALUE ',"favorited":'.
01 LIT-FAV-COUNT     PIC X(18)  VALUE ',"favoritesCount":'.
01 LIT-AUTHOR        PIC X(22)  VALUE ',"author":{"username":'.
01 LIT-BIO           PIC X(7)   VALUE ',"bio":'.
01 LIT-IMAGE         PIC X(9)   VALUE ',"image":'.
01 LIT-FOLLOWING     PIC X(13)  VALUE ',"following":'.
01 LIT-CLOSE2        PIC X(2)   VALUE '}}'.
01 LIT-CLOSE1        PIC X(1)   VALUE '}'.
01 LIT-COMMA         PIC X(1)   VALUE ','.
01 LIT-COMMENTS      PIC X(13)  VALUE '{"comments":['.
01 LIT-COMMENTS-END  PIC X(2)   VALUE ']}'.
01 LIT-COMMENT       PIC X(11)  VALUE '{"comment":'.
01 LIT-ID            PIC X(6)   VALUE '{"id":'.
01 LIT-PROFILE       PIC X(23)  VALUE '{"profile":{"username":'.
01 LIT-USER          PIC X(17)  VALUE '{"user":{"email":'.
01 LIT-TOKEN         PIC X(9)   VALUE ',"token":'.
01 LIT-USERNAME      PIC X(12)  VALUE ',"username":'.

01 AP-LIMIT-MSG      PIC X(64) VALUE "limit must be 1-100 and offset >= 0".
