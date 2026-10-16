# Pony: Stallion + Postgres

Front: direct

## Current Stack

| Piece | Version |
|-------|---------|
| ponyc | 0.77.0  |
| postgres | 3c52024d9f814fd0a2dbc01180cdd0e60a05fe4a |
| stallion | becc51753ec076fdda011f7f9d5c73a50e814368 |

## Installation and Testing

`DATABASE_URL` and `JWT_SECRET` are required. `HOST` defaults to `127.0.0.1`; `PORT` defaults to `3000`. `DB_WORKERS` defaults to 95 and accepts values from 1 through 95. On the benchmark box, direct serving uses `HOST=0.0.0.0 PORT=80`.

```sh
sudo bash submissions/pony-stallion-contact-red/install.sh
bash submissions/pony-stallion-contact-red/build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  JWT_SECRET=development-secret \
  bash submissions/pony-stallion-contact-red/start.sh
```

Run wrapper tests with `make -C submissions/pony-stallion-contact-red test`. Run the challenge suite with `bash test/run.sh submissions/pony-stallion-contact-red` after creating the dev seed and configuring PostgreSQL access as described in the repository README.

`make -C submissions/pony-stallion-contact-red test-integration` creates temporary databases from `conduit_dev`, checks prepared-statement startup and execution, round-robin assignment, reconnect and failed-query handling, article tags, atomic article failure, concurrent tag conflicts, password bytes, and HTTP pipelining, then removes the databases. It needs Python 3, psql, and PostgreSQL superuser access through the usual `PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD` variables.

## How we use multiple cores

Pony is an actor-based language which opens one scheduler per core. The actors are run by those schedulers.

Here is how I structured the application:

### Stallion

Stallion is Pony's HTTP server. Each connection opens up a separate _Connection actor. Each _Connection actor handles HTTP/1.1 protocols, keep-alive, and the application logic.  If you have 15,000 concurrent connections, there are 15,000 _Connection actors.

### _Worker

A _Worker actor manages a single database connection. We spawn 95 of them at startup. As each _Connection is brought up, it is assigned a _Worker actor by round-robin.  Each _Worker actor handles its own internal queueing, and can support hundreds of _Connection actors.

## Message Sequence Diagrams

For those who prefer pictures…

### Startup and worker preparation

```mermaid
sequenceDiagram
    participant Main
    participant Config as _Config
    participant Worker as _Worker (1 to 95)
    participant Session as pg.Session
    participant Listener as _Listener
    Main->>Config: Parse DATABASE_URL, JWT_SECRET, HOST, PORT, DB_WORKERS
    alt Invalid configuration
        Main->>Main: Print error and set exit code 1
    else Valid configuration
        loop DB_WORKERS times, default 95
            Main->>Worker: Construct worker
            Worker->>Session: Construct database session
        end
        Main->>Listener: Construct TCP listener with worker array
        Note over Listener,Worker: The listener can accept connections before workers are ready
    end
```

### Per-worker readiness

```mermaid
sequenceDiagram
    participant Session as pg.Session
    participant DB as PostgreSQL
    participant Worker as _Worker
    Session->>DB: wire connect and authenticate
    Session-->>Worker: pg_transaction_status(TransactionIdle)
    loop Each statement in _Catalog.all(), including rollback
        Worker-->>Session: prepare(name, SQL)
        Session->>DB: wire prepare
        Session-->>Worker: pg_transaction_status(TransactionIdle)
        Session-->>Worker: pg_statement_prepared(name)
    end
    Worker->>Worker: Enter Ready and submit pending queries
```

### Accepted connection and worker assignment

```mermaid
sequenceDiagram
    participant Client
    participant Listener as _Listener
    participant Conn as _Connection
    participant HTTP as Stallion HTTPServer
    participant Worker as Selected _Worker
    Client->>Listener: wire TCP connect
    Listener->>Listener: _on_accept(fd), advance round-robin index
    Listener->>Conn: Construct with selected worker and JWT secret
    Conn->>HTTP: Construct HTTPServer on accepted fd
    Note over Conn,Worker: This connection keeps the selected worker
    loop Requests on this TCP connection
        Client->>HTTP: wire HTTP request
        HTTP->>Conn: on_body_chunk and on_request_complete
        Conn-->>Worker: query when the operation needs SQL
    end
```

### Request and response path

```mermaid
sequenceDiagram
    participant Client
    participant HTTP as Stallion HTTPServer
    participant Conn as _Connection
    participant Op as _Operation in _Connection
    participant Worker as Assigned _Worker
    loop Body chunks
        Client->>HTTP: wire body bytes
        HTTP->>Conn: on_body_chunk(data)
        Conn->>Conn: Append bytes to current body
    end
    HTTP->>Conn: on_request_complete(request, responder)
    Conn->>Conn: Move body to String, increment local request ID
    Conn->>Conn: Store responder and operation by local ID
    Conn->>Op: start()
    Op->>Op: Verify token if required, route, validate input
    opt Route needs SQL
        Op-->>Worker: query(client, ID, statement, parameters)
        Worker-->>Conn: db_result(ID, result) or db_failed(ID, failure)
        Conn->>Op: Continue operation or handle failure
    end
    Op->>Op: Store status and JSON body generated by Pony or PostgreSQL, or empty body for 204
    Conn->>Conn: _settle reads outcome and removes operation and responder
    Conn->>HTTP: responder.respond(status, headers, body)
    HTTP->>Client: wire response in request order
```

### Pipelining and close

```mermaid
sequenceDiagram
    participant Client
    participant HTTP as Stallion HTTPServer
    participant Conn as _Connection
    participant Worker as Assigned _Worker
    Client->>HTTP: wire request 1 then request 2
    HTTP->>Conn: on_request_complete(request 1)
    Conn-->>Worker: query for request 1
    HTTP->>Conn: on_request_complete(request 2)
    Conn-->>Worker: query for request 2
    Note over Worker: Session serializes the two queries
    Worker-->>Conn: db_result for request 1
    Conn->>HTTP: responder 1 responds
    Note over HTTP,Client: Response 1 may be sent while request 2 runs
    Worker-->>Conn: db_result for request 2
    Conn->>HTTP: responder 2 responds
    Note over HTTP,Client: Stallion sends response 1 before response 2
    opt TCP connection closes with work pending
        HTTP->>Conn: on_closed()
        Conn->>Conn: Clear operations and responders
        Conn-->>Worker: cancel(this connection)
        Worker->>Worker: Remove pending jobs and detach submitted jobs
    end
```

### Prepared query cycle

```mermaid
sequenceDiagram
    participant Op as _Operation in _Connection
    participant Conn as _Connection
    participant Worker as _Worker
    participant Session as pg.Session
    participant DB as PostgreSQL
    Op-->>Worker: query(client, ID, statement, parameters)
    alt Worker is Ready
        Worker->>Worker: Create named prepared query and job
        Worker-->>Session: execute(query, worker)
        Note over Session: Session queues calls and executes them in order
        Session->>DB: wire execute prepared statement
        alt Result
            DB->>Session: wire rows or command result
            Session-->>Worker: pg_query_result(session, result)
            Worker->>Worker: Retain result in job
        else SQL error
            DB->>Session: wire error
            Session-->>Worker: pg_query_failed(session, query, error)
            Worker->>Worker: Retain SQL failure in job
        end
        Session-->>Worker: pg_transaction_status(session, status)
        alt TransactionIdle
            Worker-->>Conn: db_result(ID, result) or db_failed(ID, failure)
            Conn->>Op: Run saved continuation or failure handler
        else Non-idle status after either result or SQL error
            Worker->>Worker: Retire session and fail submitted jobs
            Worker-->>Conn: db_failed(ID, connection lost)
        end
    else Worker is connecting, preparing, retiring, or backing off
        Worker->>Worker: Append query to pending list
    end
```

### Authentication and routing errors

```mermaid
sequenceDiagram
    participant HTTP as Stallion
    participant Conn as _Connection
    participant Op as _Operation
    participant JWT as _JWT
    HTTP->>Conn: on_request_complete(request, responder)
    Conn->>Op: start()
    alt Registration, login, or GET tags
        Op->>Op: No authorization required
    else GET route with optional authorization
        opt Authorization header present
            Op->>JWT: Verify Token header
            JWT->>Op: Viewer ID or error
        end
    else Route requires authorization
        Op->>JWT: Verify Token header
        JWT->>Op: Viewer ID or error
    end
    alt Missing or invalid required token, or invalid supplied token
        Op->>Op: error_reply(401, unauthorized), store outcome
    else Unsupported route or method
        Op->>Op: error_reply(404, not found), store outcome
    else Invalid application body or query input
        Op->>Op: error_reply(422, invalid request), store outcome
    else Valid route
        Op->>Op: Run endpoint sequence below
    end
    opt Error outcome recorded
        Conn->>Conn: _settle reads outcome
        Conn->>HTTP: responder.respond(error response)
    end
```

### Query failures and recovery

```mermaid
sequenceDiagram
    participant Conn as _Connection
    participant Op as _Operation in _Connection
    participant Worker as _Worker
    participant Session as pg.Session
    participant DB as PostgreSQL
    alt PostgreSQL SQL error
        Session-->>Worker: pg_query_failed(session, query, SQL error)
        Worker->>Worker: Save SQLSTATE on job
        Session-->>Worker: pg_transaction_status(session, status)
        alt TransactionIdle
            Worker-->>Conn: db_failed(ID, SQL failure)
            Conn->>Op: failed(SQL failure)
            Op->>Op: Store 422 outcome for 23505, otherwise 500
            Conn->>Conn: _settle sends response
        else Non-idle status
            Worker->>Worker: Retire session and fail submitted jobs
            Worker-->>Conn: db_failed(ID, connection lost)
            Conn->>Op: failed(connection lost)
            Op->>Op: Store 500 outcome
            Conn->>Conn: _settle sends response
        end
    else DataError while encoding or decoding
        Session-->>Worker: pg_query_failed(session, query, DataError)
        Worker->>Worker: Mark job as already reported tombstone
        Worker-->>Conn: db_failed(ID, data failure)
        Conn->>Op: failed(data failure)
        Op->>Op: Store 500 outcome
        Conn->>Conn: _settle sends response
        alt Parameter encoding failed before wire send
            Note over Session,Worker: No transaction-status callback for this failed query
            opt A later query callback arrives
                Worker->>Worker: Prune the tombstone before matching that query
            end
        else Result decoding failed after wire response
            Session-->>Worker: pg_transaction_status(session, status)
            alt TransactionIdle
                Worker->>Worker: Remove reported job and keep session
            else Non-idle status
                Worker->>Worker: Retire session and fail remaining submitted jobs
            end
        end
    else Session failure or unexpected callback or status
        Session-->>Worker: Failure or unexpected callback
        Worker->>Worker: Retire session and fail submitted jobs
        Worker-->>Session: close()
        Session-->>Worker: pg_session_shutdown(session)
        Worker->>Worker: Enter Backoff and set one-second retry timer
        Worker->>Session: Construct replacement session on retry
        Session->>DB: wire reconnect and authenticate
        Worker->>Worker: Reprepare catalog, then submit pending queries
    end
```

### Register and login

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Password as _Password
    participant Query as Query cycle
    participant JWT as _JWT
    Client->>Op: POST /api/users or /api/users/login
    alt Registration
        Op->>Op: Parse user, username, email, password
        Op->>Password: Hash password with bcrypt
        Op->>Query: _RegisterUser(username, email, hash)
        Query-->>Op: New user row
        Op->>JWT: Issue token for returned ID
        Op->>Client: reply 201 with user and token
    else Login
        Op->>Op: Parse user, email, password
        Op->>Query: _LoginUser(email)
        Query-->>Op: User row or no row
        alt Row exists
            Op->>Password: Verify password against stored hash
            alt Password matches
                Op->>JWT: Issue token for returned ID
                Op->>Client: reply 200 with user and token
            else Password differs
                Op->>Client: reply 401
            end
        else No row
            Op->>Client: reply 401
        end
    end
```

### Current user and update

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Password as _Password
    participant Query as Query cycle
    Client->>Op: GET or PUT /api/user with token
    alt GET
        Op->>Query: _CurrentUser(viewer ID)
        Query-->>Op: User row or no row
    else PUT
        Op->>Op: Parse optional user fields
        opt Password supplied
            Op->>Password: Hash replacement password
        end
        Op->>Query: _UpdateUser(viewer ID, optional fields)
        Query-->>Op: Updated user row or no row
    end
    alt Row exists
        Op->>Client: reply 200 with user and existing token
    else No row
        Op->>Client: reply 401
    end
```

## Tags and profiles

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: GET /api/tags or GET /api/profiles/:username
    alt Tags
        Op->>Query: _Tags()
        Query-->>Op: One row containing JSON text generated by PostgreSQL with ordered tags
        Op->>Client: reply 200 with that JSON text
    else Profile
        Op->>Query: _Profile(viewer ID, username)
        Query-->>Op: Profile row or no row
        alt Row exists
            Op->>Client: reply 200 with profile and following flag
        else No row
            Op->>Client: reply 404
        end
    end
```

### Follow and unfollow

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: POST or DELETE /api/profiles/:username/follow
    Op->>Query: _FollowTarget(username)
    Query-->>Op: Target row or no row
    alt No target
        Op->>Client: reply 404
    else Target exists
        alt POST
            Op->>Query: _FollowInsert(viewer ID, target ID)
        else DELETE
            Op->>Query: _FollowDelete(viewer ID, target ID)
        end
        Query-->>Op: Command result
        Op->>Client: reply 200 with lookup profile and requested following value
    end
```

### Article lists and feed

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: GET /api/articles or /api/articles/feed
    Op->>Op: Parse limit and offset
    alt Feed
        Op->>Query: _ArticlePageFeed(viewer, limit, offset)
    else Articles with tag filter
        Op->>Query: _ArticlePageTag(viewer, limit, offset, tag)
    else Articles with author filter
        Op->>Query: _ArticlePageAuthor(viewer, limit, offset, author)
    else Articles with favorited filter
        Op->>Query: _ArticlePageFavorited(viewer, limit, offset, username)
    else Unfiltered articles
        Op->>Query: _ArticlePageAll(viewer, limit, offset)
    end
    Query-->>Op: One row containing JSON text generated by PostgreSQL with articles and articlesCount
    Op->>Client: reply 200 with that JSON text
```

### Read and create

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: GET /api/articles/:slug or POST /api/articles
    alt GET
        Op->>Query: _ArticleFullBySlug(viewer, slug)
        Query-->>Op: Full article row or no row
        Op->>Client: reply 200 with article, or 404
    else POST
        Op->>Query: _ArticleInsert(viewer, raw JSON body)
        Query-->>Op: Inserted article ID or no row
        alt Invalid article body
            Op->>Client: reply 422
        else Article inserted
            Op->>Query: _ArticleFullById(viewer, ID)
            Query-->>Op: Full article row or no row
            Op->>Client: reply 201 with article, or 404 if reload has no row
        end
    end
```

### Update and delete

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: PUT or DELETE /api/articles/:slug
    alt PUT
        Op->>Query: _ArticleUpdateInput(slug, raw JSON body)
        Query-->>Op: Validity, article ID, author ID, optional fields
        alt Invalid article body
            Op->>Client: reply 422
        else No article
            Op->>Client: reply 404
        else Different author
            Op->>Client: reply 403
        else Viewer owns article
            Op->>Query: _ArticleUpdate(ID, optional fields)
            Query-->>Op: Command result
            Op->>Query: _ArticleFullById(viewer, ID)
            Query-->>Op: Full article row or no row
            Op->>Client: reply 200 with article, or 404 if reload has no row
        end
    else DELETE
        Op->>Query: _ArticleIdAndAuthorBySlug(slug)
        Query-->>Op: Article ID and author ID, or no row
        alt No article
            Op->>Client: reply 404
        else Different author
            Op->>Client: reply 403
        else Viewer owns article
            Op->>Query: _ArticleDelete(ID)
            Query-->>Op: Command result
            Op->>Client: reply 204 with empty body
        end
    end
```

### Favorite and unfavorite

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: POST or DELETE /api/articles/:slug/favorite
    Op->>Query: _ArticleIdBySlug(slug)
    Query-->>Op: Article ID or no row
    alt No row
        Op->>Client: reply 404
    else Article exists
        alt POST
            Op->>Query: _FavoriteInsert(viewer, article ID)
        else DELETE
            Op->>Query: _FavoriteDelete(viewer, article ID)
        end
        Query-->>Op: Command result
        Op->>Query: _ArticleFullById(viewer, article ID)
        Query-->>Op: Full article row
        Op->>Client: reply 200 with article, or 404 if reload has no row
    end
```

### List and create comments

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: GET or POST /api/articles/:slug/comments
    alt GET
        Op->>Query: _ArticleIdBySlug(slug)
        Query-->>Op: Article ID or no row
        alt No article
            Op->>Client: reply 404
        else Article exists
            Op->>Query: _CommentsByArticle(viewer, article ID)
            Query-->>Op: Newest 100 comments, ordered by creation time then ID
            Op->>Client: reply 200 with comments array
        end
    else POST
        Op->>Query: _CommentInput(slug, raw JSON body)
        Query-->>Op: Validity, article ID, comment body
        alt Invalid comment body
            Op->>Client: reply 422
        else No article
            Op->>Client: reply 404
        else Article exists
            Op->>Query: _CommentInsert(article ID, viewer, body)
            Query-->>Op: New comment row
            Op->>Client: reply 201 with comment
        end
    end
```

### Delete comments

```mermaid
sequenceDiagram
    participant Client
    participant Op as _Operation in _Connection
    participant Query as Query cycle
    Client->>Op: DELETE /api/articles/:slug/comments/:id
    Op->>Op: Parse numeric comment ID
    Op->>Query: _CommentOwner(comment ID, slug)
    Query-->>Op: Author ID or no row
    alt No row
        Op->>Client: reply 404
    else Different author
        Op->>Client: reply 403
    else Viewer owns comment
        Op->>Query: _CommentDelete(comment ID)
        Query-->>Op: Command result
        Op->>Client: reply 204 with empty body
    end
```

## Route index

| HTTP route | Sequence |
| --- | --- |
| `POST /api/users` | [Register and login](#register-and-login) |
| `POST /api/users/login` | [Register and login](#register-and-login) |
| `GET /api/user` | [Current user and update](#current-user-and-update) |
| `PUT /api/user` | [Current user and update](#current-user-and-update) |
| `GET /api/profiles/:username` | [Tags and profiles](#tags-and-profiles) |
| `POST /api/profiles/:username/follow` | [Follow and unfollow](#follow-and-unfollow) |
| `DELETE /api/profiles/:username/follow` | [Follow and unfollow](#follow-and-unfollow) |
| `GET /api/articles` | [Article lists and feed](#article-lists-and-feed) |
| `GET /api/articles/feed` | [Article lists and feed](#article-lists-and-feed) |
| `GET /api/articles/:slug` | [Read and create](#read-and-create) |
| `POST /api/articles` | [Read and create](#read-and-create) |
| `PUT /api/articles/:slug` | [Update and delete](#update-and-delete) |
| `DELETE /api/articles/:slug` | [Update and delete](#update-and-delete) |
| `POST /api/articles/:slug/favorite` | [Favorite and unfavorite](#favorite-and-unfavorite) |
| `DELETE /api/articles/:slug/favorite` | [Favorite and unfavorite](#favorite-and-unfavorite) |
| `GET /api/articles/:slug/comments` | [List and create](#list-and-create) |
| `POST /api/articles/:slug/comments` | [List and create](#list-and-create) |
| `DELETE /api/articles/:slug/comments/:id` | [Delete](#delete) |
| `GET /api/tags` | [Tags and profiles](#tags-and-profiles) |


