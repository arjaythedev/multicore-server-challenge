;; Conduit (RealWorld) API server: CHICKEN Scheme + Spiffy + postgresql egg.
;;
;; The parent opens the listening socket and forks WORKERS processes. Each worker
;; runs Spiffy's accept loop on the shared socket (one green thread per connection)
;; and keeps its own small pool of libpq connections.

(import scheme
        (chicken base) (chicken string) (chicken condition) (chicken io) (chicken port)
        (chicken process) (chicken process-context) (chicken tcp)
        (chicken time) (chicken bitwise) (chicken foreign)
        (only (chicken file posix) port->fileno file-control fcntl/getfl fcntl/setfl open/nonblock)
        (only srfi-1 every)
        (only srfi-13 string-null? string-prefix?)
        srfi-18 srfi-69 matchable
        spiffy intarweb uri-common
        postgresql sql-null (only medea read-json) crypt
        hmac sha2 base64)

;;; Config

(define (env name default)
  (let ((v (get-environment-variable name)))
    (if (and v (not (string-null? v))) v default)))

(define database-url (env "DATABASE_URL" "postgres://conduit:conduit@127.0.0.1:5432/conduit"))
(define jwt-secret   (env "JWT_SECRET" "multicore-server-challenge"))
(define host         (env "HOST" "127.0.0.1"))
(define port         (string->number (env "PORT" "3000")))
(define workers      (string->number (env "WORKERS" "8")))
(define pool-size    (string->number (env "DB_POOL_SIZE" "5")))

(crypt-blowfish-default-logrounds 10)

;;; Errors: (fail code msg) unwinds to the request handler, which sends the JSON error.

(define (fail code msg)
  (signal (make-property-condition 'api-error 'code code 'message msg)))

(define api-error-code (condition-property-accessor 'api-error 'code))
(define api-error-message (condition-property-accessor 'api-error 'message))

(define (unique-violation? e)
  (and ((condition-predicate 'query) e)
       (equal? (get-condition-property e 'query 'error-code #f) "23505")))

;;; Database pool

(define pool '())
(define pool-mutex (make-mutex 'pool))
(define pool-freed (make-condition-variable 'pool-freed))

(define (take-conn!)
  (mutex-lock! pool-mutex)
  (if (null? pool)
      (begin (mutex-unlock! pool-mutex pool-freed) (take-conn!))
      (let ((c (car pool)))
        (set! pool (cdr pool))
        (mutex-unlock! pool-mutex)
        c)))

(define (give-conn! c)
  (mutex-lock! pool-mutex)
  (set! pool (cons c pool))
  (condition-variable-signal! pool-freed)
  (mutex-unlock! pool-mutex))

(define (with-db proc)
  (let ((c (take-conn!)))
    (handle-exceptions e (begin (give-conn! c) (signal e))
      (let ((result (proc c)))
        (give-conn! c)
        result))))

(define (open-pool!)
  (do ((i 0 (add1 i))) ((= i pool-size))
    (let ((c (connect database-url)))
      (query c "SET TIME ZONE 'UTC'")
      (give-conn! c))))

;; Prepared statements: a connection PREPAREs each SQL string the first time it runs it, then
;; EXECUTEs it by name, so Postgres parses and plans each query once per connection instead of on
;; every request (what pgx does for the Go example). Only plans are kept, never data.
;; connection -> (hash table: SQL -> statement name). An alist rather than an eq? hash table:
;; those hash by address, which the garbage collector changes, and a worker has only a few connections.
(define statement-names '())

(define (statement-name db sql)
  (let ((names (cond ((assq db statement-names) => cdr)
                     (else (let ((names (make-hash-table string=? string-hash)))
                             (set! statement-names (cons (cons db names) statement-names))
                             names)))))
    (or (hash-table-ref/default names sql #f)
        (let ((name (string->symbol (conc "s" (hash-table-size names)))))
          (query db (conc "PREPARE " name " AS " sql))
          (hash-table-set! names sql name)
          name))))

(define (execute db sql . params)
  (query* db (statement-name db sql) params))

;; First row as a list, or #f.
(define (query-row db sql . params)
  (let ((r (apply execute db sql params)))
    (and (> (row-count r) 0) (row-values r 0))))

(define (query-rows db sql . params)
  (row-map identity (apply execute db sql params)))

(define (null->json v) (if (sql-null? v) 'null v))
(define (json->param v) (if (or (not v) (eq? v 'null)) (sql-null) v))

;;; JWT (HS256)

(define (b64url-encode s)
  (string-translate (string-translate* (base64-encode s) '(("=" . ""))) "+/" "-_"))

(define (b64url-decode s)
  (let ((pad (modulo (- 4 (modulo (string-length s) 4)) 4)))
    (and (not (= pad 3))
         (base64-decode (string-append (string-translate s "-_" "+/") (make-string pad #\=))))))

(define (hs256 msg) ((hmac jwt-secret (sha256-primitive)) msg))

(define jwt-header (b64url-encode "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"))

(define (make-token user-id)
  (let* ((now (current-seconds))
         (payload (b64url-encode
                   (json->string `((sub . ,(number->string user-id))
                                   (iat . ,now)
                                   (exp . ,(+ now (* 30 24 3600)))))))
         (signing-input (string-append jwt-header "." payload)))
    (string-append signing-input "." (b64url-encode (hs256 signing-input)))))

(define (constant-time=? a b)
  (and (= (string-length a) (string-length b))
       (let loop ((i 0) (acc 0))
         (if (= i (string-length a))
             (zero? acc)
             (loop (add1 i) (bitwise-ior acc (bitwise-xor (char->integer (string-ref a i))
                                                         (char->integer (string-ref b i)))))))))

(define (all-digits? s)
  (and (string? s) (> (string-length s) 0) (<= (string-length s) 18)
       (every char-numeric? (string->list s))))

;; The user id of a valid token, or #f.
(define (verify-token token)
  (handle-exceptions e #f
    (match (string-split token "." #t)
      ((h p sig)
       (let ((header (read-json (or (b64url-decode h) "")))
             (expected (b64url-encode (hs256 (string-append h "." p)))))
         (and (list? header)
              (equal? (alist-ref 'alg header) "HS256")
              (constant-time=? sig expected)
              (let* ((claims (read-json (or (b64url-decode p) "")))
                     (exp (and (list? claims) (alist-ref 'exp claims)))
                     (sub (and (list? claims) (alist-ref 'sub claims))))
                (and (number? exp) (> exp (current-seconds))
                     (all-digits? sub)
                     (string->number sub))))))
      (_ #f))))

;; Authorization header is kept as its raw string (see header-parsers below).
(define (auth-header)
  (header-value 'authorization (request-headers (current-request))))

;; (values viewer token); anonymous is (values 0 #f) unless required.
(define (authenticate required?)
  (let ((h (auth-header)))
    (cond ((not h) (if required? (fail 401 "authentication required") (values 0 #f)))
          ((and (string-prefix? "Token " h) (verify-token (substring h 6)))
           => (lambda (id) (values id (substring h 6))))
          (else (fail 401 "invalid token")))))

(define (viewer-required) (receive (id tok) (authenticate #t) id))
(define (viewer-optional) (receive (id tok) (authenticate #f) id))

;;; Request helpers

;; The whole body is read before routing, so an early error never leaves unread
;; bytes on a keep-alive connection.
(define request-body (make-parameter ""))

(define (read-body)
  (let* ((req (current-request))
         (len (header-value 'content-length (request-headers req))))
    (if (and len (> len 0)) (read-string len (request-port req)) "")))

;; The object under KEY in the JSON body ({"user": {...}}), or 422.
(define (body-object key)
  (let* ((parsed (handle-exceptions e #f (read-json (request-body))))
         (inner (and (pair? parsed) (alist-ref key parsed))))
    (if (and inner (or (null? inner) (pair? inner)))
        inner
        (fail 422 "invalid body"))))

;; Absent/null gives #f; a string (non-empty if required) is returned; anything else is 422.
(define (opt-string obj key non-empty?)
  (let ((v (alist-ref key obj eq? 'null)))
    (cond ((eq? v 'null) #f)
          ((and (string? v) (not (and non-empty? (string-null? v)))) v)
          (else (fail 422 (conc key " must be a string"))))))

(define (req-string obj key)
  (or (opt-string obj key #t) (fail 422 (conc key " is required"))))

(define (hash-password pw)
  (if (> (string-length pw) 72) (fail 422 "password is too long") (crypt pw)))

(define (query-param name)
  (let ((v (alist-ref name (uri-query (request-uri (current-request))))))
    (if (string? v) v (and v ""))))

;; A list filter; empty means absent.
(define (filter-param name)
  (let ((v (query-param name)))
    (and v (not (string-null? v)) v)))

(define (int-param name default lo hi)
  (let ((v (query-param name)))
    (cond ((not v) default)
          ((and (all-digits? v) (<= lo (string->number v) hi)) (string->number v))
          (else (fail 422 (conc name " out of range"))))))

;;; JSON output
;;
;; medea's writer costs about 1 ms of CPU for a 10-article list page, several times the rest of
;; the request: it re-binds the output port and copies every string for each value it writes.
;; This writer emits the same JSON (alists as objects, vectors as arrays, 'null) straight to one
;; port. medea still parses request bodies.

(define (json-escape c)
  (case c
    ((#\") "\\\"")
    ((#\\) "\\\\")
    ((#\newline) "\\n")
    ((#\return) "\\r")
    ((#\tab) "\\t")
    (else (and (char<? c #\space)
               (string-append (if (< (char->integer c) 16) "\\u000" "\\u00")
                              (number->string (char->integer c) 16))))))

;; Strings are written in runs between escapes; bytes >= 0x80 (UTF-8) pass through untouched.
(define (write-json-string s out)
  (write-char #\" out)
  (let ((n (string-length s)))
    (let loop ((start 0) (i 0))
      (cond ((= i n)
             (write-string (if (= start 0) s (substring s start n)) #f out))
            ((json-escape (string-ref s i))
             => (lambda (esc)
                  (write-string (substring s start i) #f out)
                  (write-string esc #f out)
                  (loop (add1 i) (add1 i))))
            (else (loop start (add1 i))))))
  (write-char #\" out))

(define (write-json v out)
  (cond ((string? v) (write-json-string v out))
        ((number? v) (write-string (number->string v) #f out))
        ((eq? v #t) (write-string "true" #f out))
        ((eq? v #f) (write-string "false" #f out))
        ((eq? v 'null) (write-string "null" #f out))
        ((vector? v)
         (write-char #\[ out)
         (do ((i 0 (add1 i))) ((= i (vector-length v)))
           (unless (= i 0) (write-char #\, out))
           (write-json (vector-ref v i) out))
         (write-char #\] out))
        ((list? v)
         (write-char #\{ out)
         (let loop ((members v) (first? #t))
           (unless (null? members)
             (unless first? (write-char #\, out))
             (write-json-string (symbol->string (caar members)) out)
             (write-char #\: out)
             (write-json (cdar members) out)
             (loop (cdr members) #f)))
         (write-char #\} out))
        (else (error 'write-json "cannot write as JSON" v))))

(define (json->string v)
  (call-with-output-string (lambda (out) (write-json v out))))

;;; Responses

(define reasons
  '((200 . "OK") (201 . "Created") (401 . "Unauthorized") (403 . "Forbidden")
    (404 . "Not Found") (422 . "Unprocessable Entity") (500 . "Internal Server Error")))

(define (respond code obj)
  (send-response code: code reason: (alist-ref code reasons)
                 body: (json->string obj)
                 headers: '((content-type application/json))))

(define (no-content) (send-response code: 204 reason: "No Content"))

;;; SQL

(define (ts col)
  (string-append "to_char(" col ", 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"))

(define (article-select full?)
  (string-append
   "SELECT a.slug, a.title, a.description, " (if full? "a.body, " "")
   (ts "a.created_at") ", " (ts "a.updated_at") ",
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id "))

(define article-list-select (article-select #f))
(define article-full-select (article-select #t))

(define (profile-json username bio image following)
  `((username . ,username) (bio . ,(null->json bio)) (image . ,(null->json image))
    (following . ,following)))

(define (article-json row full?)
  (match-let* (((slug title description . rest) row)
               ((body . rest) (if full? rest (cons #f rest)))
               ((created updated tags count favorited username bio image following) rest))
    `((slug . ,slug) (title . ,title) (description . ,description)
      ,@(if full? `((body . ,body)) '())
      (tagList . ,tags) (createdAt . ,created) (updatedAt . ,updated)
      (favorited . ,favorited) (favoritesCount . ,count)
      (author . ,(profile-json username bio image following)))))

(define (user-json row token)
  (match-let (((id username email bio image) row))
    `((user . ((email . ,email) (token . ,(or token (make-token id)))
               (username . ,username) (bio . ,(null->json bio)) (image . ,(null->json image)))))))

(define (full-article db viewer id)
  (article-json (query-row db (string-append article-full-select "WHERE a.id = $2") viewer id) #t))

(define (article-id-by-slug db slug)
  (match (query-row db "SELECT id FROM articles WHERE slug = $1" slug)
    ((id) id)
    (#f (fail 404 "article not found"))))

;; Fetch (id author_id) of an article the viewer owns: 404 / 403 otherwise.
(define (owned-article-id db slug viewer)
  (match (query-row db "SELECT id, author_id FROM articles WHERE slug = $1" slug)
    ((id author) (if (= author viewer) id (fail 403 "not your article")))
    (#f (fail 404 "article not found"))))

;;; Handlers: users

(define (register)
  (let* ((u (body-object 'user))
         (username (req-string u 'username))
         (email (req-string u 'email))
         (hash (hash-password (req-string u 'password))))
    (with-db
     (lambda (db)
       (condition-case
           (respond 201 (user-json (query-row db "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image" username email hash) #f))
         (e (query) (if (unique-violation? e) (fail 422 "username or email is already taken") (signal e))))))))

(define (login)
  (let* ((u (body-object 'user))
         (email (req-string u 'email))
         (password (req-string u 'password))
         (row (with-db (lambda (db)
                         (query-row db "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1" email)))))
    (match row
      ((id username email bio image hash)
       (if (string=? (crypt password hash) hash)
           (respond 200 (user-json (list id username email bio image) #f))
           (fail 401 "invalid email or password")))
      (#f (fail 401 "invalid email or password")))))

(define (current-user)
  (receive (viewer token) (authenticate #t)
    (match (with-db (lambda (db) (query-row db "SELECT id, username, email, bio, image FROM users WHERE id = $1" viewer)))
      (#f (fail 401 "user not found"))
      (row (respond 200 (user-json row token))))))

(define (update-user)
  (receive (viewer token) (authenticate #t)
    (let* ((u (body-object 'user))
           (email (opt-string u 'email #t))
           (username (opt-string u 'username #t))
           (password (opt-string u 'password #t))
           (bio (opt-string u 'bio #f))
           (image (opt-string u 'image #f))
           (hash (and password (hash-password password))))
      (with-db
       (lambda (db)
         (match (condition-case
                    (query-row db "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image"
                               viewer (json->param email) (json->param username) (json->param hash)
                               (json->param bio) (json->param image))
                  (e (query) (if (unique-violation? e) (fail 422 "username or email is already taken") (signal e))))
           (#f (fail 401 "user not found"))
           (row (respond 200 (user-json row token)))))))))

;;; Handlers: profiles

(define (get-profile username)
  (let ((viewer (viewer-optional)))
    (match (with-db (lambda (db) (query-row db "SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2" viewer username)))
      ((id name bio image following) (respond 200 `((profile . ,(profile-json name bio image following)))))
      (#f (fail 404 "profile not found")))))

(define (follow username follow?)
  (let ((viewer (viewer-required)))
    (with-db
     (lambda (db)
       (match (query-row db "SELECT id, username, bio, image FROM users WHERE username = $1" username)
         ((id name bio image)
          (if follow?
              (execute db "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING" viewer id)
              (execute db "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2" viewer id))
          (respond 200 `((profile . ,(profile-json name bio image follow?)))))
         (#f (fail 404 "profile not found")))))))

;;; Handlers: articles

(define (article-list rows count)
  (respond 200 `((articles . ,(list->vector (map (lambda (r) (article-json r #f)) rows)))
                 (articlesCount . ,count))))

(define (list-articles)
  (let* ((viewer (viewer-optional))
         (limit (int-param 'limit 20 1 100))
         (offset (int-param 'offset 0 0 999999999999999999))
         (tag (filter-param 'tag))
         (author (filter-param 'author))
         (favorited (filter-param 'favorited)))
    (with-db
     (lambda (db)
       (define (run page-sql count-sql . filter)
         (article-list (apply query-rows db (string-append article-list-select page-sql) viewer limit offset filter)
                       (car (apply query-row db count-sql filter))))
       (cond
        (tag
         (run "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
              "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
              tag))
        (author
         (run "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"
              "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
              author))
        (favorited
         (run "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
              "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
              favorited))
        (else
         (run "ORDER BY a.id DESC LIMIT $2 OFFSET $3"
              "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s")))))))

(define (feed)
  (let* ((viewer (viewer-required))
         (limit (int-param 'limit 20 1 100))
         (offset (int-param 'offset 0 0 999999999999999999)))
    (with-db
     (lambda (db)
       (article-list
        (query-rows db (string-append article-list-select "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
  WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")
                    viewer limit offset)
        (car (query-row db "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s" viewer)))))))

(define (get-article slug)
  (let ((viewer (viewer-optional)))
    (match (with-db (lambda (db) (query-row db (string-append article-full-select "WHERE a.slug = $2") viewer slug)))
      (#f (fail 404 "article not found"))
      (row (respond 200 `((article . ,(article-json row #t))))))))

(define slugify "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))")

(define (create-article)
  (let* ((viewer (viewer-required))
         (a (body-object 'article))
         (title (req-string a 'title))
         (description (req-string a 'description))
         (body (req-string a 'body))
         (tags (match (alist-ref 'tagList a eq? 'null)
                 ('null '#())
                 ((? vector? v) (if (every (lambda (t) (and (string? t) (not (string-null? t)))) (vector->list v))
                                    v
                                    (fail 422 "tagList must be non-empty strings")))
                 (_ (fail 422 "tagList must be an array")))))
    (with-db
     (lambda (db)
       (let ((id (with-transaction
                  db
                  (lambda ()
                    (let ((id (car (query-row db (string-append "INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, " slugify " || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id") viewer title description body))))
                      (when (> (vector-length tags) 0)
                        (execute db "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING" tags)
                        (execute db "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])" id tags))
                      id)))))
         (respond 201 `((article . ,(full-article db viewer id)))))))))

(define (update-article slug)
  (let* ((viewer (viewer-required))
         (a (body-object 'article))
         (title (opt-string a 'title #t))
         (description (opt-string a 'description #t))
         (body (opt-string a 'body #t)))
    (with-db
     (lambda (db)
       (let ((id (owned-article-id db slug viewer)))
         (execute db (string-append "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE " slugify " || '-' || id END,
       updated_at = now()
 WHERE id = $1")
                id (json->param title) (json->param description) (json->param body))
         (respond 200 `((article . ,(full-article db viewer id)))))))))

(define (delete-article slug)
  (let ((viewer (viewer-required)))
    (with-db
     (lambda (db)
       (execute db "DELETE FROM articles WHERE id = $1" (owned-article-id db slug viewer))
       (no-content)))))

(define (favorite slug favorite?)
  (let ((viewer (viewer-required)))
    (with-db
     (lambda (db)
       (let ((id (article-id-by-slug db slug)))
         (if favorite?
             (execute db "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING" viewer id)
             (execute db "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2" viewer id))
         (respond 200 `((article . ,(full-article db viewer id)))))))))

;;; Handlers: comments

(define (comment-json row)
  (match-let (((id body created updated username bio image following) row))
    `((id . ,id) (createdAt . ,created) (updatedAt . ,updated) (body . ,body)
      (author . ,(profile-json username bio image following)))))

(define (list-comments slug)
  (let ((viewer (viewer-optional)))
    (with-db
     (lambda (db)
       (let ((id (article-id-by-slug db slug)))
         (respond 200 `((comments . ,(list->vector
                                      (map comment-json
                                           (query-rows db (string-append "SELECT c.id, c.body, " (ts "c.created_at") ", " (ts "c.updated_at") ", u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM comments c JOIN users u ON u.id = c.author_id
 WHERE c.article_id = $2
 ORDER BY c.created_at DESC, c.id DESC
 LIMIT 100") viewer id)))))))))))

(define (create-comment slug)
  (let* ((viewer (viewer-required))
         (body (req-string (body-object 'comment) 'body)))
    (with-db
     (lambda (db)
       (let ((id (article-id-by-slug db slug)))
         (respond 201 `((comment . ,(comment-json
                                     (append (query-row db (string-append "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, " (ts "c.created_at") ", " (ts "c.updated_at") ", u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id") id viewer body)
                                             '(#f)))))))))))

(define (delete-comment slug comment-id)
  (let ((viewer (viewer-required)))
    (unless (all-digits? comment-id) (fail 404 "comment not found"))
    (with-db
     (lambda (db)
       (match (query-row db "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2" comment-id slug)
         ((author)
          (unless (= author viewer) (fail 403 "not your comment"))
          (execute db "DELETE FROM comments WHERE id = $1" comment-id)
          (no-content))
         (#f (fail 404 "comment not found")))))))

;;; Handlers: tags

(define (get-tags)
  (respond 200 `((tags . ,(list->vector
                           (with-db (lambda (db) (map car (query-rows db "SELECT name FROM tags ORDER BY name")))))))))

;;; Routing

(define (route method path)
  (match (cons method path)
    (('GET "api" "tags") (get-tags))
    (('POST "api" "users") (register))
    (('POST "api" "users" "login") (login))
    (('GET "api" "user") (current-user))
    (('PUT "api" "user") (update-user))
    (('GET "api" "profiles" u) (get-profile u))
    (('POST "api" "profiles" u "follow") (follow u #t))
    (('DELETE "api" "profiles" u "follow") (follow u #f))
    (('GET "api" "articles") (list-articles))
    (('GET "api" "articles" "feed") (feed))
    (('POST "api" "articles") (create-article))
    (('GET "api" "articles" s) (get-article s))
    (('PUT "api" "articles" s) (update-article s))
    (('DELETE "api" "articles" s) (delete-article s))
    (('POST "api" "articles" s "favorite") (favorite s #t))
    (('DELETE "api" "articles" s "favorite") (favorite s #f))
    (('GET "api" "articles" s "comments") (list-comments s))
    (('POST "api" "articles" s "comments") (create-comment s))
    (('DELETE "api" "articles" s "comments" id) (delete-comment s id))
    (_ (fail 404 "not found"))))

(define (handle-request continue)
  (let* ((req (current-request))
         (path (uri-path (request-uri req))))
    (condition-case
        (parameterize ((request-body (read-body)))
          (route (request-method req) (if (pair? path) (cdr path) '())))
      (e (api-error)
         (respond (api-error-code e) `((errors . ((body . #(,(api-error-message e))))))))
      (e ()
         (print-error-message e (current-error-port))
         (respond 500 '((errors . ((body . #("internal error"))))))))))

;;; Startup

;; Keep the raw Authorization header ("Token <jwt>") instead of intarweb's parsed form.
(header-parsers (cons (cons 'authorization (lambda (contents) (list (vector contents '()))))
                      (header-parsers)))

(vhost-map `((".*" . ,handle-request)))
(access-log #f)
;; Nginx keeps idle upstream connections for 60 s; stay open longer than that.
(tcp-read-timeout 120000)
(max-connections 4096)
;; Buffer each response and send it in one write when Spiffy flushes (unbuffered,
;; every header line is its own send()).
(tcp-buffer-size 16384)

(foreign-declare "#include <netinet/in.h>\n#include <netinet/tcp.h>\n#include <sys/socket.h>")

(define set-nodelay!
  (foreign-lambda* int ((int fd))
    "int one = 1; C_return(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one));"))

;; Without TCP_NODELAY, Nagle and delayed ACKs add ~40 ms to responses on keep-alive connections.
(define (accept-nodelay listener)
  (receive (in out) (tcp-accept listener)
    (set-nodelay! (port->fileno in))
    (values in out)))

(define (run-worker listener)
  (open-pool!)
  (accept-loop listener accept-nodelay))

(define (main)
  (let* ((listener (tcp-listen port 1024 host))
         (fd (tcp-listener-fileno listener))
         (children '()))
    ;; Every worker polls this socket and all of them wake for a new connection. CHICKEN leaves it
    ;; blocking, so the workers that lose the race would sit in accept() with all their green
    ;; threads frozen. Non-blocking, they get EAGAIN, which Spiffy's accept loop shrugs off.
    (file-control fd fcntl/setfl (bitwise-ior (file-control fd fcntl/getfl) open/nonblock))
    (do ((i 0 (add1 i))) ((= i workers))
      (set! children (cons (process-fork (lambda () (run-worker listener) (exit 0))) children)))
    ;; If any worker dies, take the whole server down rather than run degraded.
    (receive (pid ok status) (process-wait)
      (for-each (lambda (c) (handle-exceptions e #f (process-signal c))) children)
      (exit 1))))

(main)
