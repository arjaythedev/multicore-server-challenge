## Entry point: one async HTTP worker with one PostgreSQL connection.
##
## start.sh runs several copies of this process.  Each binds the same
## HOST:PORT with SO_REUSEPORT, so the kernel spreads connections across
## processes and every process has independent event-loop and database state.

import std/[asynchttpserver, asyncdispatch, httpcore, nativesockets, os, strutils]
import ./api, ./pg

proc main() =
  let databaseUrl = getEnv("DATABASE_URL")
  let jwtSecret = getEnv("JWT_SECRET")
  if databaseUrl.len == 0 or jwtSecret.len == 0:
    stderr.writeLine("DATABASE_URL and JWT_SECRET are required")
    quit(2)

  let host = getEnv("HOST", "0.0.0.0")
  let port =
    try: Port(parseInt(getEnv("PORT", "80")))
    except ValueError:
      stderr.writeLine("PORT must be an integer")
      quit(2)

  var db = openDb(databaseUrl)
  db.configureSession()
  var ctx = ApiCtx(db: db, secret: jwtSecret)
  let server = newAsyncHttpServer(reuseAddr = true, reusePort = true,
                                  maxBody = 1_048_576)

  proc handler(req: Request) {.async, gcsafe.} =
    try:
      await handle(req, ctx)
    except CatchableError as e:
      stderr.writeLine("request failed: " & e.msg)
      try:
        let body = """{"errors":{"body":["internal server error"]}}"""
        await req.respond(Http500, body,
          newHttpHeaders([("Content-Type", "application/json")]))
      except CatchableError:
        discard

  echo "conduit-nim listening on ", host, ":", port,
       " pid=", getCurrentProcessId()
  waitFor server.serve(port, handler, host)

when isMainModule:
  main()
