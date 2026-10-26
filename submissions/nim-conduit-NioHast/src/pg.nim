## Minimal libpq binding and a single-connection wrapper.
##
## The challenge permits any PostgreSQL driver.  We use libpq directly so the
## code stays small and explicit: no ORM, no hidden prepared-statement cache and
## no background connection churn.  Each worker process owns one connection; the
## process count is chosen in start.sh so the total stays below the 95-connection
## application limit.

{.passL: "-lpq".}

import std/tables

type
  Cpgconn* {.importc: "PGconn", header: "<postgresql/libpq-fe.h>", incompleteStruct.} = object
  Cpgresult* {.importc: "PGresult", header: "<postgresql/libpq-fe.h>", incompleteStruct.} = object

  DbError* = object of CatchableError

  PgValue* = object
    text*: string
    isNull*: bool

  PgConn* = object
    raw*: ptr Cpgconn
    prepared*: Table[string, string]
    nextStmt: int

  QueryResult* = object
    raw*: ptr Cpgresult

proc PQconnectdb(conninfo: cstring): ptr Cpgconn
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQstatus(conn: ptr Cpgconn): cint
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQerrorMessage(conn: ptr Cpgconn): cstring
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQfinish(conn: ptr Cpgconn)
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQexec(conn: ptr Cpgconn; query: cstring): ptr Cpgresult
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQexecParams(conn: ptr Cpgconn; command: cstring; nParams: cint;
                  paramTypes: ptr cint; paramValues: ptr cstring;
                  paramLengths: ptr cint; paramFormats: ptr cint;
                  resultFormat: cint): ptr Cpgresult
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQprepare(conn: ptr Cpgconn; stmtName, query: cstring; nParams: cint;
               paramTypes: ptr cint): ptr Cpgresult
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQexecPrepared(conn: ptr Cpgconn; stmtName: cstring; nParams: cint;
                    paramValues: ptr cstring; paramLengths: ptr cint;
                    paramFormats: ptr cint; resultFormat: cint): ptr Cpgresult
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQresultStatus(res: ptr Cpgresult): cint
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQresultErrorMessage(res: ptr Cpgresult): cstring
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQresultErrorField(res: ptr Cpgresult; fieldcode: cint): cstring
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQntuples(res: ptr Cpgresult): cint
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQnfields(res: ptr Cpgresult): cint
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQgetvalue(res: ptr Cpgresult; row, col: cint): cstring
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQgetisnull(res: ptr Cpgresult; row, col: cint): cint
  {.importc, header: "<postgresql/libpq-fe.h>".}
proc PQclear(res: ptr Cpgresult)
  {.importc, header: "<postgresql/libpq-fe.h>".}

const
  ConnectionOk = 0.cint
  PgCommandOk = 1.cint
  PgTuplesOk = 2.cint
  PgDiagSqlstate = cint(ord('C'))

proc value*(v: string): PgValue =
  PgValue(text: v, isNull: false)

proc nullValue*(): PgValue =
  PgValue(text: "", isNull: true)

proc openDb*(databaseUrl: string): PgConn =
  ## Open one libpq connection.  `DATABASE_URL` is already in libpq URI form.
  result.prepared = initTable[string, string]()
  result.nextStmt = 0
  result.raw = PQconnectdb(databaseUrl.cstring)
  if result.raw == nil or PQstatus(result.raw) != ConnectionOk:
    let msg = if result.raw == nil: "PQconnectdb returned nil"
              else: $PQerrorMessage(result.raw)
    if result.raw != nil:
      PQfinish(result.raw)
    result.raw = nil
    raise newException(DbError, "PostgreSQL connection failed: " & msg)

proc close*(db: var PgConn) =
  if db.raw != nil:
    PQfinish(db.raw)
    db.raw = nil

proc close*(res: var QueryResult) =
  if res.raw != nil:
    PQclear(res.raw)
    res.raw = nil

proc close*(res: QueryResult) =
  ## Overload for temporary results, e.g. `db.execParams(...).close()`.
  if res.raw != nil:
    PQclear(res.raw)

proc raiseResultError(res: ptr Cpgresult; what: string) =
  let msg = if res == nil: "nil result" else: $PQresultErrorMessage(res)
  raise newException(DbError, what & ": " & msg)

proc exec*(db: var PgConn; sql: string): QueryResult =
  ## Execute a statement without parameters.  Used for BEGIN/COMMIT/ROLLBACK
  ## and for statements whose values were already validated locally.
  if db.raw == nil:
    raise newException(DbError, "database is closed")
  result.raw = PQexec(db.raw, sql.cstring)
  if result.raw == nil:
    raise newException(DbError, "PQexec returned nil")
  let status = PQresultStatus(result.raw)
  if status != PgCommandOk and status != PgTuplesOk:
    let msg = $PQresultErrorMessage(result.raw)
    PQclear(result.raw)
    result.raw = nil
    raise newException(DbError, "SQL failed: " & msg)

proc execParams*(db: var PgConn; sql: string;
                 params: openArray[PgValue]): QueryResult =
  ## Execute a parameterized statement in PostgreSQL text format.
  ## NULL is represented by a nil `paramValues` entry.
  if db.raw == nil:
    raise newException(DbError, "database is closed")

  var values = newSeq[cstring](params.len)
  var lengths = newSeq[cint](params.len)
  var formats = newSeq[cint](params.len)
  for i, p in params:
    formats[i] = 0
    if p.isNull:
      values[i] = nil
      lengths[i] = 0
    else:
      values[i] = p.text.cstring
      lengths[i] = cint(p.text.len)

  let valuePtr =
    if params.len == 0: nil
    else: cast[ptr cstring](addr values[0])
  let lengthPtr =
    if params.len == 0: nil
    else: cast[ptr cint](addr lengths[0])
  let formatPtr =
    if params.len == 0: nil
    else: cast[ptr cint](addr formats[0])

  var stmtName: string
  if db.prepared.hasKey(sql):
    stmtName = db.prepared[sql]
  else:
    inc db.nextStmt
    stmtName = "nim_stmt_" & $db.nextStmt
    let prep = PQprepare(db.raw, stmtName.cstring, sql.cstring,
                         cint(params.len), nil)
    if prep == nil or PQresultStatus(prep) != PgCommandOk:
      let msg = if prep == nil: "nil prepare result" else: $PQresultErrorMessage(prep)
      if prep != nil: PQclear(prep)
      raise newException(DbError, "PREPARE failed: " & msg)
    PQclear(prep)
    db.prepared[sql] = stmtName

  result.raw = PQexecPrepared(db.raw, stmtName.cstring, cint(params.len),
                              valuePtr, lengthPtr, formatPtr, 0)
  if result.raw == nil:
    raise newException(DbError, "PQexecPrepared returned nil")
  let status = PQresultStatus(result.raw)
  if status != PgCommandOk and status != PgTuplesOk:
    let msg = $PQresultErrorMessage(result.raw)
    PQclear(result.raw)
    result.raw = nil
    raise newException(DbError, "SQL failed: " & msg)

proc sqlState*(res: QueryResult): string =
  ## SQLSTATE such as 23505 (unique violation), or "" when unavailable.
  if res.raw == nil: return ""
  let p = PQresultErrorField(res.raw, PgDiagSqlstate)
  if p == nil: "" else: $p

proc rowCount*(res: QueryResult): int =
  if res.raw == nil: 0 else: int(PQntuples(res.raw))

proc fieldCount*(res: QueryResult): int =
  if res.raw == nil: 0 else: int(PQnfields(res.raw))

proc get*(res: QueryResult; row, col: int): string =
  ## Text value at `row`, `col`; NULL becomes the empty string.
  if res.raw == nil: return ""
  let p = PQgetvalue(res.raw, cint(row), cint(col))
  if p == nil: "" else: $p

proc isNull*(res: QueryResult; row, col: int): bool =
  if res.raw == nil: true
  else: PQgetisnull(res.raw, cint(row), cint(col)) != 0

proc execCommand*(db: var PgConn; sql: string) =
  var r = db.exec(sql)
  r.close()

proc configureSession*(db: var PgConn) =
  ## Session-local settings allowed by SPEC rule 2.  Generic plans avoid
  ## repeated planning of identical parameterized statements; JIT and parallel
  ## workers are counterproductive for these short OLTP queries.
  db.execCommand("SET plan_cache_mode = force_generic_plan")
  db.execCommand("SET jit = off")
  db.execCommand("SET max_parallel_workers_per_gather = 0")
  db.execCommand("SET client_encoding = 'UTF8'")

proc beginTx*(db: var PgConn) = db.execCommand("BEGIN")
proc commitTx*(db: var PgConn) = db.execCommand("COMMIT")
proc rollbackTx*(db: var PgConn) =
  try: db.execCommand("ROLLBACK")
  except DbError: discard
