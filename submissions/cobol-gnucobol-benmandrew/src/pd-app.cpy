*> ================= handlers =================
*> Each H- paragraph runs from DISPATCH for client FX: it validates the request, then queues its statements
*> (PB-*, PG-SUBMIT) with a handler code, or responds at once. APP-ROW renders each row as it arrives and
*> APP-DONE answers the request, or queues its next step. A response from APP-DONE or APP-BC-DONE is followed by
*> AFTER-RESPONSE, which carries on with the client's pipelined requests; a response from an H- paragraph is
*> not, because DISPATCH's caller does that.

H-TAGS.
    MOVE 0 TO AP-ASYNC
    PERFORM PB-BEGIN
    MOVE 32 TO PB-ST
    PERFORM PB-STMT
    PERFORM PB-END-STMT
    MOVE H-K-TAGS TO PB-H
    PERFORM AP-SUBMIT.

*> GET /api/articles: one list statement for the filter (tag, then author, then favorited; empty values are
*> ignored). Its count statement, for an empty page, is kept in CN-COUNT-ST and the filter in the context.
H-LIST-ARTICLES.
    MOVE 0 TO AP-ASYNC
    PERFORM PARSE-QUERY
    PERFORM LIMIT-OFFSET
    IF LO-OK = 0
        MOVE 422 TO ERR-STATUS
        MOVE AP-LIMIT-MSG TO ERR-MSG
        PERFORM RESPOND-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 0 TO AP-FILTER
    EVALUATE TRUE
        WHEN QV-SET (3) = 1 AND QV-LEN (3) > 0
            MOVE 3 TO AP-FILTER
            MOVE 2 TO AP-ST
            MOVE 7 TO CN-COUNT-ST (FX)
        WHEN QV-SET (4) = 1 AND QV-LEN (4) > 0
            MOVE 4 TO AP-FILTER
            MOVE 3 TO AP-ST
            MOVE 8 TO CN-COUNT-ST (FX)
        WHEN QV-SET (5) = 1 AND QV-LEN (5) > 0
            MOVE 5 TO AP-FILTER
            MOVE 4 TO AP-ST
            MOVE 9 TO CN-COUNT-ST (FX)
        WHEN OTHER
            MOVE 1 TO AP-ST
            MOVE 6 TO CN-COUNT-ST (FX)
    END-EVALUATE
    PERFORM PB-BEGIN
    MOVE AP-ST TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    PERFORM AP-PB-LIMIT-OFFSET
    IF AP-FILTER > 0
        SET ADDRESS OF L-SRC TO ADDRESS OF QBUF
        MOVE QV-OFF (AP-FILTER) TO PB-OFF
        MOVE QV-LEN (AP-FILTER) TO PB-LEN
        PERFORM PB-TEXT
        PERFORM CTX-CLEAR
        MOVE 1 TO CA-PRES
        SET CA-PTR TO ADDRESS OF QBUF
        MOVE QV-OFF (AP-FILTER) TO CA-OFF
        MOVE QV-LEN (AP-FILTER) TO CA-LEN
        PERFORM CTX-ADD
        PERFORM CTX-SAVE
    END-IF
    PERFORM PB-END-STMT
    MOVE H-K-LIST TO PB-H
    PERFORM AP-SUBMIT.

H-FEED.
    MOVE 0 TO AP-ASYNC
    PERFORM PARSE-QUERY
    PERFORM LIMIT-OFFSET
    IF LO-OK = 0
        MOVE 422 TO ERR-STATUS
        MOVE AP-LIMIT-MSG TO ERR-MSG
        PERFORM RESPOND-ERROR
        EXIT PARAGRAPH
    END-IF
    MOVE 10 TO CN-COUNT-ST (FX)
    PERFORM PB-BEGIN
    MOVE 5 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    PERFORM AP-PB-LIMIT-OFFSET
    PERFORM PB-END-STMT
    MOVE H-K-LIST TO PB-H
    PERFORM AP-SUBMIT.

H-GET-ARTICLE.
    MOVE 0 TO AP-ASYNC
    PERFORM PB-BEGIN
    PERFORM AP-ARTICLE-BY-SLUG
    MOVE H-K-ARTICLE TO PB-H
    PERFORM AP-SUBMIT.

H-LIST-COMMENTS.
    MOVE 0 TO AP-ASYNC
    PERFORM PB-BEGIN
    MOVE 22 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM PB-END-STMT
    MOVE H-K-COMMENTS TO PB-H
    PERFORM AP-SUBMIT.

H-GET-PROFILE.
    MOVE 0 TO AP-ASYNC
    MOVE 29 TO AP-ST
    MOVE H-K-PROFILE TO PB-H
    PERFORM AP-PROFILE-REQUEST.

H-FOLLOW.
    MOVE 0 TO AP-ASYNC
    MOVE 30 TO AP-ST
    MOVE H-K-FOLLOW TO PB-H
    PERFORM AP-PROFILE-REQUEST.

H-UNFOLLOW.
    MOVE 0 TO AP-ASYNC
    MOVE 31 TO AP-ST
    MOVE H-K-UNFOLLOW TO PB-H
    PERFORM AP-PROFILE-REQUEST.

*> ($1 viewer, $2 username)
AP-PROFILE-REQUEST.
    PERFORM PB-BEGIN
    MOVE AP-ST TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM PB-END-STMT
    PERFORM AP-SUBMIT.

*> The response repeats the request's token, so it is kept in context item 1.
H-CURRENT-USER.
    MOVE 0 TO AP-ASYNC
    PERFORM CTX-CLEAR
    PERFORM AP-CTX-TOKEN
    PERFORM CTX-SAVE
    PERFORM PB-BEGIN
    MOVE 27 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    PERFORM PB-END-STMT
    MOVE H-K-USER TO PB-H
    PERFORM AP-SUBMIT.

H-FAVORITE.
    MOVE 0 TO AP-ASYNC
    MOVE 20 TO AP-ST
    PERFORM AP-FAVORITE-REQUEST.

H-UNFAVORITE.
    MOVE 0 TO AP-ASYNC
    MOVE 21 TO AP-ST
    PERFORM AP-FAVORITE-REQUEST.

*> The change, then the article, in one round trip.
AP-FAVORITE-REQUEST.
    PERFORM PB-BEGIN
    MOVE AP-ST TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM PB-END-STMT
    PERFORM AP-ARTICLE-BY-SLUG
    MOVE H-K-ARTICLE TO PB-H
    PERFORM AP-SUBMIT.

*> article_by_slug ($1 viewer, $2 the slug in segment 2)
AP-ARTICLE-BY-SLUG.
    MOVE 11 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM PB-END-STMT.

H-CREATE-COMMENT.
    MOVE 0 TO AP-ASYNC
    MOVE "comment" TO JI-WRAP
    MOVE 7 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 8 TO AP-K
    PERFORM AP-REQ
    IF AP-OK = 0
        MOVE "body is required" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    *> ($1 slug, $2 viewer, $3 body)
    PERFORM PB-BEGIN
    MOVE 23 TO PB-ST
    PERFORM PB-STMT
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM AP-PB-VIEWER
    MOVE 8 TO AP-K
    PERFORM AP-PB-FIELD
    PERFORM PB-END-STMT
    MOVE H-K-NEW-COMMENT TO PB-H
    PERFORM AP-SUBMIT.

*> The id must be 1 to 18 ASCII digits; it goes to Postgres without leading zeros.
H-DELETE-COMMENT.
    MOVE 0 TO AP-ASYNC
    MOVE SEG-OFF (4) TO AP-I
    MOVE SEG-LEN (4) TO AP-K
    MOVE 1 TO AP-OK
    IF AP-K > 18
        MOVE 0 TO AP-OK
    ELSE
        PERFORM VARYING AP-C FROM AP-I BY 1 UNTIL AP-C >= AP-I + AP-K
            IF SEGBUF (AP-C:1) < "0" OR SEGBUF (AP-C:1) > "9"
                MOVE 0 TO AP-OK
            END-IF
        END-PERFORM
    END-IF
    IF AP-OK = 0
        MOVE 404 TO ERR-STATUS
        MOVE "comment not found" TO ERR-MSG
        PERFORM RESPOND-ERROR
        EXIT PARAGRAPH
    END-IF
    PERFORM UNTIL AP-K = 1 OR SEGBUF (AP-I:1) NOT = "0"
        ADD 1 TO AP-I
        SUBTRACT 1 FROM AP-K
    END-PERFORM
    *> ($1 comment id, $2 slug, $3 viewer)
    PERFORM PB-BEGIN
    MOVE 24 TO PB-ST
    PERFORM PB-STMT
    SET ADDRESS OF L-SRC TO ADDRESS OF SEGBUF
    MOVE AP-I TO PB-OFF
    MOVE AP-K TO PB-LEN
    PERFORM PB-TEXT
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM AP-PB-VIEWER
    PERFORM PB-END-STMT
    MOVE H-K-DEL-COMMENT TO PB-H
    PERFORM AP-SUBMIT.

H-CREATE-ARTICLE.
    MOVE 0 TO AP-ASYNC
    MOVE "article" TO JI-WRAP
    MOVE 7 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 6 TO AP-K
    PERFORM AP-REQ
    IF AP-OK = 1
        MOVE 7 TO AP-K
        PERFORM AP-REQ
    END-IF
    IF AP-OK = 1
        MOVE 8 TO AP-K
        PERFORM AP-REQ
    END-IF
    IF AP-OK = 0
        MOVE "title, description and body are required" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    *> tagList: absent or null is no tags; otherwise an array of non-empty strings
    EVALUATE TRUE
        WHEN JF-T (9) < 2
            MOVE 0 TO AP-K
        WHEN JF-T (9) = 4 AND JT-OK = 1
            MOVE JT-N TO AP-K
        WHEN OTHER
            MOVE "tagList must be an array of non-empty strings" TO ERR-MSG
            PERFORM AP-ERR-422
            EXIT PARAGRAPH
    END-EVALUATE
    *> One Sync: the inserts are one transaction, committed before the response is sent.
    PERFORM PB-BEGIN
    MOVE 14 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 6 TO AP-K
    PERFORM AP-PB-FIELD
    MOVE 7 TO AP-K
    PERFORM AP-PB-FIELD
    MOVE 8 TO AP-K
    PERFORM AP-PB-FIELD
    PERFORM PB-END-STMT
    IF JF-T (9) = 4 AND JT-N > 0
        MOVE 15 TO PB-ST
        PERFORM PB-STMT
        PERFORM PB-TAGS
        PERFORM PB-END-STMT
        MOVE 16 TO PB-ST
        PERFORM PB-STMT
        PERFORM PB-TAGS
        PERFORM PB-END-STMT
    END-IF
    MOVE 13 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    PERFORM PB-END-STMT
    MOVE H-K-CREATED TO PB-H
    PERFORM AP-SUBMIT.

*> The owner check first (404, 403); the fields wait in the context for the update.
H-UPDATE-ARTICLE.
    MOVE 0 TO AP-ASYNC
    MOVE "article" TO JI-WRAP
    MOVE 7 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING AP-K FROM 6 BY 1 UNTIL AP-K > 8 OR AP-OK = 0
        PERFORM AP-OPT-NE
    END-PERFORM
    IF AP-OK = 0
        MOVE "title, description and body must be non-empty strings" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    PERFORM CTX-CLEAR
    PERFORM VARYING AP-K FROM 6 BY 1 UNTIL AP-K > 8
        PERFORM AP-CTX-FIELD
    END-PERFORM
    PERFORM CTX-SAVE
    MOVE H-K-OWN-UPDATE TO PB-H
    PERFORM AP-OWNER-REQUEST.

H-DELETE-ARTICLE.
    MOVE 0 TO AP-ASYNC
    MOVE H-K-OWN-DELETE TO PB-H
    PERFORM AP-OWNER-REQUEST.

*> SELECT id, author_id FROM articles WHERE slug = $1
AP-OWNER-REQUEST.
    PERFORM PB-BEGIN
    MOVE 17 TO PB-ST
    PERFORM PB-STMT
    MOVE 2 TO AP-I
    PERFORM AP-PB-SEG
    PERFORM PB-END-STMT
    PERFORM AP-SUBMIT.

*> Hash first, on the bcrypt process; the insert follows in APP-BC-DONE.
H-REGISTER.
    MOVE 0 TO AP-ASYNC
    MOVE "user" TO JI-WRAP
    MOVE 4 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING AP-K FROM 1 BY 1 UNTIL AP-K > 3 OR AP-OK = 0
        PERFORM AP-REQ
    END-PERFORM
    IF AP-OK = 0
        MOVE "username, email and password are required" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    PERFORM AP-PW-USABLE
    IF BC-USABLE-OK = 0
        MOVE "password is too long" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    PERFORM CTX-CLEAR
    PERFORM VARYING AP-K FROM 1 BY 1 UNTIL AP-K > 2
        PERFORM AP-CTX-FIELD
    END-PERFORM
    PERFORM CTX-SAVE
    MOVE AP-STEP-REGISTER TO CN-STEP (FX)
    MOVE 1 TO BC-MODE
    PERFORM AP-BC-SUBMIT-FIELD.

*> The user row first; the password is checked against its hash on the bcrypt process.
H-LOGIN.
    MOVE 0 TO AP-ASYNC
    MOVE "user" TO JI-WRAP
    MOVE 4 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    MOVE 2 TO AP-K
    PERFORM AP-REQ
    IF AP-OK = 1
        MOVE 3 TO AP-K
        PERFORM AP-REQ
    END-IF
    IF AP-OK = 0
        MOVE "email and password are required" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    PERFORM CTX-CLEAR
    MOVE 3 TO AP-K
    PERFORM AP-CTX-FIELD
    PERFORM CTX-SAVE
    PERFORM PB-BEGIN
    MOVE 26 TO PB-ST
    PERFORM PB-STMT
    MOVE 2 TO AP-K
    PERFORM AP-PB-FIELD
    PERFORM PB-END-STMT
    MOVE H-K-LOGIN TO PB-H
    PERFORM AP-SUBMIT.

*> Context: 1 token, 2 email, 3 username, 4 bio, 5 image, 6 password. A new password is hashed first.
H-UPDATE-USER.
    MOVE 0 TO AP-ASYNC
    MOVE "user" TO JI-WRAP
    MOVE 4 TO JI-WRAP-LEN
    PERFORM AP-BODY
    IF AP-OK = 0
        EXIT PARAGRAPH
    END-IF
    PERFORM VARYING AP-K FROM 1 BY 1 UNTIL AP-K > 3 OR AP-OK = 0
        PERFORM AP-OPT-NE
    END-PERFORM
    PERFORM VARYING AP-K FROM 4 BY 1 UNTIL AP-K > 5 OR AP-OK = 0
        PERFORM AP-OPT
    END-PERFORM
    IF AP-OK = 0
        MOVE "invalid user fields" TO ERR-MSG
        PERFORM AP-ERR-422
        EXIT PARAGRAPH
    END-IF
    IF JF-T (3) = 2
        PERFORM AP-PW-USABLE
        IF BC-USABLE-OK = 0
            MOVE "password is too long" TO ERR-MSG
            PERFORM AP-ERR-422
            EXIT PARAGRAPH
        END-IF
    END-IF
    PERFORM CTX-CLEAR
    PERFORM AP-CTX-TOKEN
    MOVE 2 TO AP-K
    PERFORM AP-CTX-FIELD
    MOVE 1 TO AP-K
    PERFORM AP-CTX-FIELD
    MOVE 4 TO AP-K
    PERFORM AP-CTX-FIELD
    MOVE 5 TO AP-K
    PERFORM AP-CTX-FIELD
    PERFORM CTX-SAVE
    IF JF-T (3) = 2
        MOVE AP-STEP-UPDATE TO CN-STEP (FX)
        MOVE 1 TO BC-MODE
        PERFORM AP-BC-SUBMIT-FIELD
    ELSE
        MOVE 0 TO AP-HASH-PRES
        PERFORM AP-UPDATE-USER-REQUEST
    END-IF.

*> update_user ($1 viewer, $2 email, $3 username, $4 password hash, $5 bio, $6 image) from the context, and the
*> hash in BC-RESULT if AP-HASH-PRES = 1.
AP-UPDATE-USER-REQUEST.
    PERFORM CTX-LOAD
    PERFORM PB-BEGIN
    MOVE 28 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE 2 TO AP-I
    PERFORM AP-PB-CTX
    MOVE 3 TO AP-I
    PERFORM AP-PB-CTX
    IF AP-HASH-PRES = 1
        SET ADDRESS OF L-SRC TO ADDRESS OF BC-RESULT
        MOVE 1 TO PB-OFF
        MOVE BC-RESULT-LEN TO PB-LEN
        PERFORM PB-TEXT
    ELSE
        PERFORM PB-NULL
    END-IF
    MOVE 4 TO AP-I
    PERFORM AP-PB-CTX
    MOVE 5 TO AP-I
    PERFORM AP-PB-CTX
    PERFORM PB-END-STMT
    MOVE H-K-USER TO PB-H
    PERFORM AP-SUBMIT.

*> ---------- request helpers ----------

*> Parses the body against the wrapper in JI-WRAP; AP-OK = 0 after answering 422 "invalid body".
AP-BODY.
    SET ADDRESS OF L-JSRC TO ADDRESS OF IN-BUF
    MOVE BODY-OFF TO JI-SRC-OFF
    MOVE BODY-LEN TO JI-SRC-LEN
    MOVE 1 TO JI-MODE
    PERFORM JI-PARSE
    MOVE 1 TO AP-OK
    IF JI-OK = 0 OR JI-TOP-OBJ = 0 OR JI-WRAP-OK = 0
        MOVE 0 TO AP-OK
        MOVE "invalid body" TO ERR-MSG
        PERFORM AP-ERR-422
    END-IF.

*> field AP-K: a non-empty string
AP-REQ.
    MOVE 1 TO AP-OK
    IF JF-T (AP-K) NOT = 2 OR JF-LEN (AP-K) = 0
        MOVE 0 TO AP-OK
    END-IF.

*> field AP-K: absent, null or a non-empty string
AP-OPT-NE.
    MOVE 1 TO AP-OK
    IF JF-T (AP-K) > 2 OR (JF-T (AP-K) = 2 AND JF-LEN (AP-K) = 0)
        MOVE 0 TO AP-OK
    END-IF.

*> field AP-K: absent, null or a string
AP-OPT.
    MOVE 1 TO AP-OK
    IF JF-T (AP-K) > 2
        MOVE 0 TO AP-OK
    END-IF.

AP-ERR-422.
    MOVE 422 TO ERR-STATUS
    PERFORM RESPOND-ERROR.

*> the password (field 3) is one bcrypt accepts
AP-PW-USABLE.
    SET ADDRESS OF L-SRC TO ADDRESS OF JI-BUF
    MOVE JF-OFF (3) TO BC-PW-OFF
    MOVE JF-LEN (3) TO BC-PW-LEN
    PERFORM BC-USABLE.

*> Sends the password in field 3 to the bcrypt process with BC-MODE.
AP-BC-SUBMIT-FIELD.
    SET ADDRESS OF L-SRC TO ADDRESS OF JI-BUF
    MOVE JF-OFF (3) TO BC-PW-OFF
    MOVE JF-LEN (3) TO BC-PW-LEN
    PERFORM BC-SUBMIT
    IF BC-SUBMIT-OK = 0
        PERFORM AP-FAIL-500
    END-IF.

AP-SUBMIT.
    PERFORM PG-SUBMIT
    IF PG-SUBMIT-OK = 0
        PERFORM AP-FAIL-500
    END-IF.

AP-FAIL-500.
    IF AP-ASYNC = 1
        PERFORM AP-DONE-500
    ELSE
        PERFORM RESPOND-500
    END-IF.

AP-PB-VIEWER.
    MOVE CN-VIEWER (FX) TO PB-INT-V
    PERFORM PB-INT.

AP-PB-LIMIT-OFFSET.
    SET ADDRESS OF L-SRC TO ADDRESS OF LIMIT-TXT
    MOVE 1 TO PB-OFF
    MOVE LIMIT-LEN TO PB-LEN
    PERFORM PB-TEXT
    SET ADDRESS OF L-SRC TO ADDRESS OF OFFSET-TXT
    MOVE OFFSET-LEN TO PB-LEN
    PERFORM PB-TEXT.

*> path segment AP-I
AP-PB-SEG.
    SET ADDRESS OF L-SRC TO ADDRESS OF SEGBUF
    MOVE SEG-OFF (AP-I) TO PB-OFF
    MOVE SEG-LEN (AP-I) TO PB-LEN
    PERFORM PB-TEXT.

*> body field AP-K: its string, or NULL
AP-PB-FIELD.
    IF JF-T (AP-K) = 2
        SET ADDRESS OF L-SRC TO ADDRESS OF JI-BUF
        MOVE JF-OFF (AP-K) TO PB-OFF
        MOVE JF-LEN (AP-K) TO PB-LEN
        PERFORM PB-TEXT
    ELSE
        PERFORM PB-NULL
    END-IF.

*> context item AP-I (L-CTX loaded): its bytes, or NULL
AP-PB-CTX.
    IF LC-PRES (AP-I) = 0
        PERFORM PB-NULL
    ELSE
        SET ADDRESS OF L-SRC TO ADDRESS OF LC-DATA
        MOVE LC-OFF (AP-I) TO PB-OFF
        ADD 1 TO PB-OFF
        MOVE LC-LEN (AP-I) TO PB-LEN
        PERFORM PB-TEXT
    END-IF.

*> body field AP-K into the context being built (absent for anything but a string)
AP-CTX-FIELD.
    IF JF-T (AP-K) = 2
        MOVE 1 TO CA-PRES
        SET CA-PTR TO ADDRESS OF JI-BUF
        MOVE JF-OFF (AP-K) TO CA-OFF
        MOVE JF-LEN (AP-K) TO CA-LEN
    ELSE
        MOVE 0 TO CA-PRES
    END-IF
    PERFORM CTX-ADD.

AP-CTX-TOKEN.
    MOVE 1 TO CA-PRES
    SET CA-PTR TO ADDRESS OF IN-BUF
    MOVE TOK-OFF TO CA-OFF
    MOVE TOK-LEN TO CA-LEN
    PERFORM CTX-ADD.

*> ---------- answers ----------

*> Rows of the request at the head of a Postgres connection, rendered as they arrive.
APP-ROW.
    EVALUATE RQ-H
        WHEN H-K-LIST
            IF RQ-ROW = 1
                MOVE LIT-ARTICLES TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-ARTICLES)
                ADD LENGTH OF LIT-ARTICLES TO OUT-LEN
                *> the total, in the last column
                MOVE 14 TO AP-C
                PERFORM AP-GET-INT8
                MOVE AP-D64 TO CN-AUX (FX)
            ELSE
                MOVE LIT-COMMA TO L-OUT (OUT-LEN + 1:1)
                ADD 1 TO OUT-LEN
            END-IF
            MOVE 0 TO AP-K
            PERFORM AP-ARTICLE-ROW
        WHEN H-K-ARTICLE
            PERFORM AP-SINGLE-ARTICLE-ROW
        WHEN H-K-CREATED
            *> statement 1 is the insert, whose row is the new id
            IF RQ-STMT > 1
                PERFORM AP-SINGLE-ARTICLE-ROW
            END-IF
        WHEN H-K-TAGS
            *> the whole body, built by Postgres
            MOVE RW-LEN (1) TO AP-I
            MOVE L-RB (RW-OFF (1):AP-I) TO L-OUT (OUT-LEN + 1:AP-I)
            ADD AP-I TO OUT-LEN
        WHEN H-K-COMMENTS
            IF RQ-ROW = 1
                MOVE LIT-COMMENTS TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-COMMENTS)
                ADD LENGTH OF LIT-COMMENTS TO OUT-LEN
            ELSE
                MOVE LIT-COMMA TO L-OUT (OUT-LEN + 1:1)
                ADD 1 TO OUT-LEN
            END-IF
            *> an article with no comments is one row of NULLs after the article id
            IF RW-LEN (2) >= 0
                MOVE 1 TO AP-K
                MOVE 2 TO AP-FOLLOWING
                PERFORM AP-COMMENT-ROW
            END-IF
        WHEN H-K-NEW-COMMENT
            MOVE LIT-COMMENT TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-COMMENT)
            ADD LENGTH OF LIT-COMMENT TO OUT-LEN
            MOVE 0 TO AP-K AP-FOLLOWING
            PERFORM AP-COMMENT-ROW
            MOVE LIT-CLOSE1 TO L-OUT (OUT-LEN + 1:1)
            ADD 1 TO OUT-LEN
        WHEN H-K-DEL-COMMENT
        WHEN H-K-COUNT
            MOVE 1 TO AP-C
            PERFORM AP-GET-INT8
            MOVE AP-D64 TO CN-AUX (FX)
        WHEN H-K-PROFILE
            MOVE 0 TO AP-K
            MOVE 2 TO AP-FOLLOWING
            PERFORM AP-PROFILE-ROW
        WHEN H-K-FOLLOW
            MOVE -1 TO AP-K
            MOVE 1 TO AP-FOLLOWING
            PERFORM AP-PROFILE-ROW
        WHEN H-K-UNFOLLOW
            MOVE -1 TO AP-K
            MOVE 0 TO AP-FOLLOWING
            PERFORM AP-PROFILE-ROW
        WHEN H-K-USER
            PERFORM CTX-LOAD
            SET AP-TOK-PTR TO ADDRESS OF LC-DATA
            MOVE LC-OFF (1) TO AP-TOK-OFF
            ADD 1 TO AP-TOK-OFF
            MOVE LC-LEN (1) TO AP-TOK-LEN
            PERFORM AP-USER-ROW
        WHEN H-K-REGISTER
            PERFORM AP-SIGN-ROW
            PERFORM AP-USER-ROW
        WHEN H-K-LOGIN
            *> New context: 1 password (from the old one), 2 stored hash, 3 the whole response body, which is
            *> rendered now so that the row need not be kept.
            PERFORM CTX-LOAD
            PERFORM CTX-CLEAR
            MOVE LC-PRES (1) TO CA-PRES
            SET CA-PTR TO ADDRESS OF LC-DATA
            MOVE LC-OFF (1) TO CA-OFF
            ADD 1 TO CA-OFF
            MOVE LC-LEN (1) TO CA-LEN
            PERFORM CTX-ADD
            MOVE 1 TO CA-PRES
            SET CA-PTR TO ADDRESS OF L-RB
            MOVE RW-OFF (6) TO CA-OFF
            MOVE RW-LEN (6) TO CA-LEN
            PERFORM CTX-ADD
            MOVE OUT-LEN TO AP-SAVE-LEN
            PERFORM AP-SIGN-ROW
            PERFORM AP-USER-ROW
            SET CA-PTR TO ADDRESS OF L-OUT
            MOVE AP-SAVE-LEN TO CA-OFF
            ADD 1 TO CA-OFF
            MOVE OUT-LEN TO CA-LEN
            SUBTRACT AP-SAVE-LEN FROM CA-LEN
            PERFORM CTX-ADD
            PERFORM CTX-SAVE
            MOVE AP-SAVE-LEN TO OUT-LEN
        WHEN H-K-OWN-UPDATE
        WHEN H-K-OWN-DELETE
            MOVE 1 TO AP-C
            PERFORM AP-GET-INT8
            MOVE AP-D64 TO CN-AUX (FX)
            MOVE 2 TO AP-C
            PERFORM AP-GET-INT8
            MOVE AP-D64 TO CN-AUX2 (FX)
    END-EVALUATE.

APP-DONE.
    IF RQ-ERR = 1
        IF RQ-SQLSTATE = "23505" AND (RQ-H = H-K-REGISTER OR RQ-H = H-K-USER)
            MOVE 422 TO ERR-STATUS
            MOVE "username or email is already taken" TO ERR-MSG
            PERFORM AP-DONE-ERR
        ELSE
            DISPLAY "error: " RQ-SQLSTATE UPON SYSERR
            PERFORM AP-DONE-500
        END-IF
        EXIT PARAGRAPH
    END-IF
    EVALUATE RQ-H
        WHEN H-K-TAGS
            MOVE 200 TO AP-STATUS
            PERFORM AP-DONE-OUT
        WHEN H-K-LIST
            IF RQ-NROWS (1) = 0
                PERFORM AP-COUNT-REQUEST
            ELSE
                MOVE LIT-COUNT TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-COUNT)
                ADD LENGTH OF LIT-COUNT TO OUT-LEN
                MOVE CN-AUX (FX) TO JO-INT-V
                PERFORM JO-INT
                MOVE LIT-CLOSE1 TO L-OUT (OUT-LEN + 1:1)
                ADD 1 TO OUT-LEN
                MOVE 200 TO AP-STATUS
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-COUNT
            MOVE LIT-NO-ARTICLES TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-NO-ARTICLES)
            ADD LENGTH OF LIT-NO-ARTICLES TO OUT-LEN
            MOVE CN-AUX (FX) TO JO-INT-V
            PERFORM JO-INT
            MOVE LIT-CLOSE1 TO L-OUT (OUT-LEN + 1:1)
            ADD 1 TO OUT-LEN
            MOVE 200 TO AP-STATUS
            PERFORM AP-DONE-OUT
        WHEN H-K-ARTICLE
        WHEN H-K-CREATED
            IF OUT-LEN = 0
                MOVE 404 TO ERR-STATUS
                MOVE "article not found" TO ERR-MSG
                PERFORM AP-DONE-ERR
            ELSE
                IF RQ-H = H-K-CREATED
                    MOVE 201 TO AP-STATUS
                ELSE
                    MOVE 200 TO AP-STATUS
                END-IF
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-COMMENTS
            IF RQ-NROWS (1) = 0
                MOVE 404 TO ERR-STATUS
                MOVE "article not found" TO ERR-MSG
                PERFORM AP-DONE-ERR
            ELSE
                MOVE LIT-COMMENTS-END TO L-OUT (OUT-LEN + 1:2)
                ADD 2 TO OUT-LEN
                MOVE 200 TO AP-STATUS
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-NEW-COMMENT
            IF RQ-NROWS (1) = 0
                MOVE 404 TO ERR-STATUS
                MOVE "article not found" TO ERR-MSG
                PERFORM AP-DONE-ERR
            ELSE
                MOVE 201 TO AP-STATUS
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-DEL-COMMENT
            EVALUATE TRUE
                WHEN RQ-NROWS (1) = 0
                    MOVE 404 TO ERR-STATUS
                    MOVE "comment not found" TO ERR-MSG
                    PERFORM AP-DONE-ERR
                WHEN CN-AUX (FX) NOT = CN-VIEWER (FX)
                    MOVE 403 TO ERR-STATUS
                    MOVE "not the author" TO ERR-MSG
                    PERFORM AP-DONE-ERR
                WHEN OTHER
                    PERFORM AP-DONE-204
            END-EVALUATE
        WHEN H-K-PROFILE
        WHEN H-K-FOLLOW
        WHEN H-K-UNFOLLOW
            IF RQ-NROWS (1) = 0
                MOVE 404 TO ERR-STATUS
                MOVE "profile not found" TO ERR-MSG
                PERFORM AP-DONE-ERR
            ELSE
                MOVE 200 TO AP-STATUS
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-USER
            IF RQ-NROWS (1) = 0
                MOVE 401 TO ERR-STATUS
                MOVE "unauthorized" TO ERR-MSG
                PERFORM AP-DONE-ERR
            ELSE
                MOVE 200 TO AP-STATUS
                PERFORM AP-DONE-OUT
            END-IF
        WHEN H-K-REGISTER
            MOVE 201 TO AP-STATUS
            PERFORM AP-DONE-OUT
        WHEN H-K-LOGIN
            PERFORM AP-LOGIN-VERIFY
        WHEN H-K-OWN-UPDATE
        WHEN H-K-OWN-DELETE
            EVALUATE TRUE
                WHEN RQ-NROWS (1) = 0
                    MOVE 404 TO ERR-STATUS
                    MOVE "article not found" TO ERR-MSG
                    PERFORM AP-DONE-ERR
                WHEN CN-AUX2 (FX) NOT = CN-VIEWER (FX)
                    MOVE 403 TO ERR-STATUS
                    MOVE "not the author" TO ERR-MSG
                    PERFORM AP-DONE-ERR
                WHEN RQ-H = H-K-OWN-DELETE
                    PERFORM AP-DELETE-REQUEST
                WHEN OTHER
                    PERFORM AP-UPDATE-REQUEST
            END-EVALUATE
        WHEN H-K-DELETED
            PERFORM AP-DONE-204
    END-EVALUATE.

*> The count statement for an empty list page: ($1 filter) from the context, ($1 viewer) for the feed, or none.
AP-COUNT-REQUEST.
    MOVE 1 TO AP-ASYNC
    PERFORM PB-BEGIN
    MOVE CN-COUNT-ST (FX) TO PB-ST
    PERFORM PB-STMT
    EVALUATE CN-COUNT-ST (FX)
        WHEN 6
            CONTINUE
        WHEN 10
            PERFORM AP-PB-VIEWER
        WHEN OTHER
            PERFORM CTX-LOAD
            MOVE 1 TO AP-I
            PERFORM AP-PB-CTX
    END-EVALUATE
    PERFORM PB-END-STMT
    MOVE H-K-COUNT TO PB-H
    PERFORM AP-SUBMIT.

*> DELETE FROM articles WHERE id = $1
AP-DELETE-REQUEST.
    MOVE 1 TO AP-ASYNC
    PERFORM PB-BEGIN
    MOVE 19 TO PB-ST
    PERFORM PB-STMT
    MOVE CN-AUX (FX) TO PB-INT-V
    PERFORM PB-INT
    PERFORM PB-END-STMT
    MOVE H-K-DELETED TO PB-H
    PERFORM AP-SUBMIT.

*> update_article ($1 id, $2 title, $3 description, $4 body), then article_by_id ($1 viewer, $2 id).
AP-UPDATE-REQUEST.
    MOVE 1 TO AP-ASYNC
    PERFORM CTX-LOAD
    PERFORM PB-BEGIN
    MOVE 18 TO PB-ST
    PERFORM PB-STMT
    MOVE CN-AUX (FX) TO PB-INT-V
    PERFORM PB-INT
    PERFORM VARYING AP-I FROM 1 BY 1 UNTIL AP-I > 3
        PERFORM AP-PB-CTX
    END-PERFORM
    PERFORM PB-END-STMT
    MOVE 12 TO PB-ST
    PERFORM PB-STMT
    PERFORM AP-PB-VIEWER
    MOVE CN-AUX (FX) TO PB-INT-V
    PERFORM PB-INT
    PERFORM PB-END-STMT
    MOVE H-K-ARTICLE TO PB-H
    PERFORM AP-SUBMIT.

*> After user_by_email: no row is 401; otherwise the password goes to the bcrypt process with the stored hash.
AP-LOGIN-VERIFY.
    IF RQ-NROWS (1) = 0
        PERFORM AP-DONE-401-LOGIN
        EXIT PARAGRAPH
    END-IF
    PERFORM CTX-LOAD
    SET ADDRESS OF L-SRC TO ADDRESS OF LC-DATA
    MOVE LC-OFF (1) TO BC-PW-OFF
    ADD 1 TO BC-PW-OFF
    MOVE LC-LEN (1) TO BC-PW-LEN
    PERFORM BC-USABLE
    IF BC-USABLE-OK = 0 OR LC-LEN (2) = 0 OR LC-LEN (2) > LENGTH OF BC-SETTING
        PERFORM AP-DONE-401-LOGIN
        EXIT PARAGRAPH
    END-IF
    MOVE LC-LEN (2) TO BC-SETTING-LEN
    MOVE LC-OFF (2) TO AP-I
    MOVE LC-DATA (AP-I + 1:BC-SETTING-LEN) TO BC-SETTING (1:BC-SETTING-LEN)
    MOVE AP-STEP-LOGIN TO CN-STEP (FX)
    MOVE 2 TO BC-MODE
    PERFORM BC-SUBMIT
    IF BC-SUBMIT-OK = 0
        PERFORM AP-DONE-500
    END-IF.

*> A hash from the bcrypt process, for the step in CN-STEP.
APP-BC-DONE.
    MOVE 1 TO AP-ASYNC
    MOVE CN-STEP (FX) TO AP-I
    MOVE 0 TO CN-STEP (FX)
    *> an empty hash for a new password: bcrypt refused it
    IF BC-RESULT-LEN = 0 AND (AP-I = AP-STEP-REGISTER OR AP-I = AP-STEP-UPDATE)
        MOVE 422 TO ERR-STATUS
        MOVE "password is too long" TO ERR-MSG
        PERFORM AP-DONE-ERR
        EXIT PARAGRAPH
    END-IF
    EVALUATE AP-I
        WHEN AP-STEP-REGISTER
            *> insert_user ($1 username, $2 email, $3 password hash)
            PERFORM CTX-LOAD
            PERFORM PB-BEGIN
            MOVE 25 TO PB-ST
            PERFORM PB-STMT
            MOVE 1 TO AP-I
            PERFORM AP-PB-CTX
            MOVE 2 TO AP-I
            PERFORM AP-PB-CTX
            SET ADDRESS OF L-SRC TO ADDRESS OF BC-RESULT
            MOVE 1 TO PB-OFF
            MOVE BC-RESULT-LEN TO PB-LEN
            PERFORM PB-TEXT
            PERFORM PB-END-STMT
            MOVE H-K-REGISTER TO PB-H
            PERFORM AP-SUBMIT
        WHEN AP-STEP-UPDATE
            MOVE 1 TO AP-HASH-PRES
            PERFORM AP-UPDATE-USER-REQUEST
        WHEN AP-STEP-LOGIN
            *> crypt(password, stored) must give the stored hash, compared in constant time
            PERFORM CTX-LOAD
            MOVE 0 TO AP-OK
            IF BC-RESULT-LEN > 0 AND BC-RESULT-LEN = LC-LEN (2)
                MOVE LC-OFF (2) TO AP-I
                MOVE 0 TO SIZE-T
                ADD BC-RESULT-LEN TO SIZE-T
                CALL "CRYPTO_memcmp" USING BY REFERENCE BC-RESULT BY REFERENCE LC-DATA (AP-I + 1:1)
                    BY VALUE SIZE-T RETURNING RC
                IF RC = 0
                    MOVE 1 TO AP-OK
                END-IF
            END-IF
            IF AP-OK = 0
                PERFORM AP-DONE-401-LOGIN
            ELSE
                MOVE LC-OFF (3) TO AP-I
                MOVE 0 TO CLOSED
                MOVE 200 TO RESP-STATUS
                SET RESP-PTR TO ADDRESS OF LC-DATA (AP-I + 1:1)
                MOVE LC-LEN (3) TO RESP-LEN
                PERFORM RESPOND
                PERFORM AFTER-RESPONSE
            END-IF
    END-EVALUATE.

AP-DONE-OUT.
    MOVE 0 TO CLOSED
    MOVE AP-STATUS TO RESP-STATUS
    SET RESP-PTR TO ADDRESS OF L-OUT
    MOVE OUT-LEN TO RESP-LEN
    PERFORM RESPOND
    PERFORM AFTER-RESPONSE.

AP-DONE-ERR.
    MOVE 0 TO CLOSED
    PERFORM RESPOND-ERROR
    PERFORM AFTER-RESPONSE.

AP-DONE-500.
    MOVE 0 TO CLOSED
    PERFORM RESPOND-500
    PERFORM AFTER-RESPONSE.

AP-DONE-204.
    MOVE 0 TO CLOSED
    PERFORM RESPOND-204
    PERFORM AFTER-RESPONSE.

AP-DONE-401-LOGIN.
    MOVE 401 TO ERR-STATUS
    MOVE "invalid email or password" TO ERR-MSG
    PERFORM AP-DONE-ERR.

*> ---------- rendering ----------

*> int8 column AP-C to AP-D64
AP-GET-INT8.
    MOVE RW-OFF (AP-C) TO AP-I
    MOVE L-RB (AP-I:1) TO AP-D64-X (8:1)
    MOVE L-RB (AP-I + 1:1) TO AP-D64-X (7:1)
    MOVE L-RB (AP-I + 2:1) TO AP-D64-X (6:1)
    MOVE L-RB (AP-I + 3:1) TO AP-D64-X (5:1)
    MOVE L-RB (AP-I + 4:1) TO AP-D64-X (4:1)
    MOVE L-RB (AP-I + 5:1) TO AP-D64-X (3:1)
    MOVE L-RB (AP-I + 6:1) TO AP-D64-X (2:1)
    MOVE L-RB (AP-I + 7:1) TO AP-D64-X (1:1).

*> Signs a token for the user id in column 1: AP-TOK-* point at JW-TOKEN.
AP-SIGN-ROW.
    MOVE 1 TO AP-C
    PERFORM AP-GET-INT8
    MOVE AP-D64 TO JW-SUB
    PERFORM JWT-SIGN
    SET AP-TOK-PTR TO ADDRESS OF JW-TOKEN
    MOVE 1 TO AP-TOK-OFF
    MOVE JW-TOKEN-LEN TO AP-TOK-LEN.

AP-SINGLE-ARTICLE-ROW.
    MOVE LIT-ARTICLE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-ARTICLE)
    ADD LENGTH OF LIT-ARTICLE TO OUT-LEN
    MOVE 1 TO AP-K
    PERFORM AP-ARTICLE-ROW
    MOVE LIT-CLOSE1 TO L-OUT (OUT-LEN + 1:1)
    ADD 1 TO OUT-LEN.

*> An article from RW (1) on: id, slug, title, description, then body only if AP-K = 1 (the full_select
*> statements s11 to s13; AP-K = 0 for the list pages), created_at, updated_at, tag_list, favorites_count,
*> favorited, username, bio, image, following.
AP-ARTICLE-ROW.
    MOVE LIT-SLUG TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-SLUG)
    ADD LENGTH OF LIT-SLUG TO OUT-LEN
    MOVE 2 TO JO-C
    PERFORM JO-COL
    MOVE LIT-TITLE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-TITLE)
    ADD LENGTH OF LIT-TITLE TO OUT-LEN
    MOVE 3 TO JO-C
    PERFORM JO-COL
    MOVE LIT-DESC TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-DESC)
    ADD LENGTH OF LIT-DESC TO OUT-LEN
    MOVE 4 TO JO-C
    PERFORM JO-COL
    IF AP-K = 1
        MOVE LIT-BODY TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BODY)
        ADD LENGTH OF LIT-BODY TO OUT-LEN
        MOVE 5 TO JO-C
        PERFORM JO-COL
    END-IF
    MOVE LIT-TAGS TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-TAGS)
    ADD LENGTH OF LIT-TAGS TO OUT-LEN
    MOVE 7 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-TAGS
    MOVE LIT-CREATED TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-CREATED)
    ADD LENGTH OF LIT-CREATED TO OUT-LEN
    MOVE 5 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-TS
    MOVE LIT-UPDATED TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-UPDATED)
    ADD LENGTH OF LIT-UPDATED TO OUT-LEN
    MOVE 6 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-TS
    MOVE LIT-FAVORITED TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-FAVORITED)
    ADD LENGTH OF LIT-FAVORITED TO OUT-LEN
    MOVE 9 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-BOOL
    MOVE LIT-FAV-COUNT TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-FAV-COUNT)
    ADD LENGTH OF LIT-FAV-COUNT TO OUT-LEN
    MOVE 8 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-INT8
    MOVE LIT-AUTHOR TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-AUTHOR)
    ADD LENGTH OF LIT-AUTHOR TO OUT-LEN
    MOVE 10 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL
    MOVE LIT-BIO TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BIO)
    ADD LENGTH OF LIT-BIO TO OUT-LEN
    MOVE 11 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-IMAGE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-IMAGE)
    ADD LENGTH OF LIT-IMAGE TO OUT-LEN
    MOVE 12 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-FOLLOWING TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-FOLLOWING)
    ADD LENGTH OF LIT-FOLLOWING TO OUT-LEN
    MOVE 13 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-BOOL
    MOVE LIT-CLOSE2 TO L-OUT (OUT-LEN + 1:2)
    ADD 2 TO OUT-LEN.

*> A comment from RW (AP-K + 1) on: id, body, created_at, updated_at, username, bio, image. AP-K is 1 for s22,
*> after its article id, and 0 for s23. AP-FOLLOWING: 0 false, 1 true, 2 from RW (9), s22's following.
AP-COMMENT-ROW.
    MOVE LIT-ID TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-ID)
    ADD LENGTH OF LIT-ID TO OUT-LEN
    MOVE 1 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-INT8
    MOVE LIT-CREATED2 TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-CREATED2)
    ADD LENGTH OF LIT-CREATED2 TO OUT-LEN
    MOVE 3 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-TS
    MOVE LIT-UPDATED TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-UPDATED)
    ADD LENGTH OF LIT-UPDATED TO OUT-LEN
    MOVE 4 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-TS
    MOVE LIT-BODY TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BODY)
    ADD LENGTH OF LIT-BODY TO OUT-LEN
    MOVE 2 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL
    MOVE LIT-AUTHOR TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-AUTHOR)
    ADD LENGTH OF LIT-AUTHOR TO OUT-LEN
    MOVE 5 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL
    MOVE LIT-BIO TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BIO)
    ADD LENGTH OF LIT-BIO TO OUT-LEN
    MOVE 6 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-IMAGE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-IMAGE)
    ADD LENGTH OF LIT-IMAGE TO OUT-LEN
    MOVE 7 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-FOLLOWING TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-FOLLOWING)
    ADD LENGTH OF LIT-FOLLOWING TO OUT-LEN
    MOVE 9 TO JO-C
    PERFORM AP-FOLLOWING-OUT
    MOVE LIT-CLOSE2 TO L-OUT (OUT-LEN + 1:2)
    ADD 2 TO OUT-LEN.

*> A profile from RW (AP-K + 2) on: username, bio, image. AP-K is 0 for s29, after its user id, and -1 for s30
*> and s31. AP-FOLLOWING as for comments, 2 meaning RW (5), s29's following.
AP-PROFILE-ROW.
    MOVE LIT-PROFILE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-PROFILE)
    ADD LENGTH OF LIT-PROFILE TO OUT-LEN
    MOVE 2 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL
    MOVE LIT-BIO TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BIO)
    ADD LENGTH OF LIT-BIO TO OUT-LEN
    MOVE 3 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-IMAGE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-IMAGE)
    ADD LENGTH OF LIT-IMAGE TO OUT-LEN
    MOVE 4 TO JO-C
    ADD AP-K TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-FOLLOWING TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-FOLLOWING)
    ADD LENGTH OF LIT-FOLLOWING TO OUT-LEN
    MOVE 5 TO JO-C
    PERFORM AP-FOLLOWING-OUT
    MOVE LIT-CLOSE2 TO L-OUT (OUT-LEN + 1:2)
    ADD 2 TO OUT-LEN.

*> AP-FOLLOWING as a JSON boolean: 0 false, 1 true, 2 the bool column JO-C.
AP-FOLLOWING-OUT.
    IF AP-FOLLOWING = 2
        PERFORM JO-COL-BOOL
    ELSE
        MOVE AP-FOLLOWING TO JO-BOOL-V
        PERFORM JO-BOOL
    END-IF.

*> {"user":{...}} from (id, username, email, bio, image) and the token at AP-TOK-PTR.
AP-USER-ROW.
    MOVE LIT-USER TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-USER)
    ADD LENGTH OF LIT-USER TO OUT-LEN
    MOVE 3 TO JO-C
    PERFORM JO-COL
    MOVE LIT-TOKEN TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-TOKEN)
    ADD LENGTH OF LIT-TOKEN TO OUT-LEN
    SET ADDRESS OF L-SRC TO AP-TOK-PTR
    MOVE AP-TOK-OFF TO JO-OFF
    MOVE AP-TOK-LEN TO JO-LEN
    PERFORM JO-STR
    MOVE LIT-USERNAME TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-USERNAME)
    ADD LENGTH OF LIT-USERNAME TO OUT-LEN
    MOVE 2 TO JO-C
    PERFORM JO-COL
    MOVE LIT-BIO TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-BIO)
    ADD LENGTH OF LIT-BIO TO OUT-LEN
    MOVE 4 TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-IMAGE TO L-OUT (OUT-LEN + 1:LENGTH OF LIT-IMAGE)
    ADD LENGTH OF LIT-IMAGE TO OUT-LEN
    MOVE 5 TO JO-C
    PERFORM JO-COL-OPT
    MOVE LIT-CLOSE2 TO L-OUT (OUT-LEN + 1:2)
    ADD 2 TO OUT-LEN.
