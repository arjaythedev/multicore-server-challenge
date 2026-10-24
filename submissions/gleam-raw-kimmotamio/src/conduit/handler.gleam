//// Routing, validation and the per-endpoint flows. `handle` returns what the connection process should do next:
//// write a response, or nothing because the Postgres connection process that ran the query has already rendered
//// and written it (`conn.Render`). The hot endpoints all take that second path; the handler only parses,
//// authenticates, validates and chooses the statement, and the rows never reach this process.

import conduit/bcrypt
import conduit/jsonw
import conduit/jwt
import conduit/pg/conn.{type PgError, type Request, Exec, PgError, Render}
import conduit/pg/proto.{type Param, type Row}
import conduit/response.{type Response, type Socket}
import conduit/sql
import conduit/util
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string_tree.{type StringTree}

pub type Ctx {
  Ctx(secret: BitArray, hibernate_words: Int, min_heap_words: Int)
}

/// What the connection process does after `handle`.
pub type Outcome {
  /// Write this response.
  Reply(response: Response)
  /// Write these already framed bytes (a Postgres connection process rendered them but found the socket busy).
  Prepared(data: StringTree)
  /// Nothing: a Postgres connection process wrote the response.
  Done
  /// The client socket failed while the response was being written: close it.
  Broken
  /// Write this and close: a late result for this request must not reach the client.
  ReplyAndClose(response: Response)
}

@external(erlang, "conduit_ffi", "pick_read")
fn pick_read(group: Int) -> Subject(Request)

@external(erlang, "conduit_ffi", "pick_write")
fn pick_write() -> Subject(Request)

@external(erlang, "conduit_ffi", "now_seconds")
fn now() -> Int

@external(erlang, "conduit_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// How long a request may wait for a connection and its result before the handler answers 503.
const db_timeout_ms = 10_000

@external(erlang, "conduit_ffi", "log")
fn log(msg: String) -> Nil

type Req {
  Req(ctx: Ctx, sock: Socket, query: String, auth: String, body: BitArray, now: Int)
}

pub fn handle(ctx: Ctx, sock: Socket, method: String, segments: List(String), query: String, auth: String, body: BitArray) -> Outcome {
  let r = Req(ctx, sock, query, auth, body, now())
  let outcome = case segments {
    ["", "api", ..rest] -> route(method, rest, r)
    _ -> Error(fail(404, "not found"))
  }
  case outcome {
    Ok(outcome) -> outcome
    Error(resp) -> Reply(resp)
  }
}

fn fail(status: Int, msg: String) -> Response {
  #(status, jsonw.error(msg))
}

fn reply(status: Int, body: StringTree) -> Result(Outcome, Response) {
  Ok(Reply(#(status, body)))
}

fn pg_error(e: PgError) -> Response {
  case e.code {
    "23505" -> fail(422, "has already been taken")
    "23503" -> fail(404, "not found")
    "57014" | "55P03" | "53300" -> fail(503, "database busy")
    "08000" | "08003" | "08006" -> fail(503, "database unavailable")
    code -> {
      log("postgres error " <> code <> ": " <> e.message)
      fail(500, "database error")
    }
  }
}

// ---------------------------------------------------------------- database

/// Runs statements and gets the rows back here (the flows that need them for a follow-up).
fn exec(pool: Subject(Request), statements: List(#(Int, List(Param)))) -> Result(List(List(Row)), Response) {
  let reply = process.new_subject()
  process.send(pool, Exec(monotonic_ms() + db_timeout_ms, statements, reply))
  case process.receive(reply, db_timeout_ms) {
    Ok(Ok(results)) -> Ok(results)
    Ok(Error(e)) -> Error(pg_error(e))
    Error(_) -> Error(fail(503, "database timeout"))
  }
}

fn read(statement: Int, params: List(Param)) -> Result(List(Row), Response) {
  case exec(pick_read(sql.read_group(statement)), [#(statement, params)]) {
    Ok([rows]) -> Ok(rows)
    Ok(_) -> Error(fail(500, "database error"))
    Error(e) -> Error(e)
  }
}

fn write(statement: Int, params: List(Param)) -> Result(List(Row), Response) {
  case exec(pick_write(), [#(statement, params)]) {
    Ok([rows]) -> Ok(rows)
    Ok(_) -> Error(fail(500, "database error"))
    Error(e) -> Error(e)
  }
}

/// Runs one statement on a read connection, which renders the rows with `render` and writes the response.
fn read_then(r: Req, statement: Int, params: List(Param), render: fn(List(Row)) -> Response) -> Result(Outcome, Response) {
  defer(r, pick_read(sql.read_group(statement)), statement, params, render)
}

fn write_then(r: Req, statement: Int, params: List(Param), render: fn(List(Row)) -> Response) -> Result(Outcome, Response) {
  defer(r, pick_write(), statement, params, render)
}

fn defer(r: Req, pool: Subject(Request), statement: Int, params: List(Param), render: fn(List(Row)) -> Response) -> Result(Outcome, Response) {
  let notify = process.new_subject()
  let deadline = monotonic_ms() + db_timeout_ms
  let render_results = fn(results: List(List(Row))) -> Response {
    case results {
      [rows] -> render(rows)
      _ -> fail(500, "database error")
    }
  }
  process.send(pool, Render(deadline, [#(statement, params)], render_results, r.sock, notify))
  // The connection process never writes past the deadline, so once this wait is over nothing can trail it.
  case process.receive(notify, db_timeout_ms + 1000) {
    Ok(conn.Written) -> Ok(Done)
    Ok(conn.Busy(data)) -> Ok(Prepared(data))
    Ok(conn.Gone) -> Ok(Broken)
    Ok(conn.Crashed) -> Error(fail(500, "internal error"))
    Ok(conn.Expired) -> Error(fail(503, "database timeout"))
    Ok(conn.Failed(e)) -> Error(pg_error(e))
    Error(_) -> Ok(ReplyAndClose(fail(503, "database timeout")))
  }
}

// ---------------------------------------------------------------- routes

fn route(method: String, segments: List(String), r: Req) -> Result(Outcome, Response) {
  case method, segments {
    "GET", ["tags"] -> tags(r)
    "POST", ["users"] -> register(r)
    "POST", ["users", "login"] -> login(r)
    "GET", ["user"] -> current_user(r)
    "PUT", ["user"] -> update_user(r)
    "GET", ["profiles", u] -> get_profile(r, u)
    "POST", ["profiles", u, "follow"] -> follow(r, u, True)
    "DELETE", ["profiles", u, "follow"] -> follow(r, u, False)
    "GET", ["articles"] -> list_articles(r)
    "POST", ["articles"] -> create_article(r)
    "GET", ["articles", "feed"] -> feed(r)
    "GET", ["articles", slug] -> get_article(r, slug)
    "PUT", ["articles", slug] -> update_article(r, slug)
    "DELETE", ["articles", slug] -> delete_article(r, slug)
    "POST", ["articles", slug, "favorite"] -> favorite(r, slug, True)
    "DELETE", ["articles", slug, "favorite"] -> favorite(r, slug, False)
    "GET", ["articles", slug, "comments"] -> list_comments(r, slug)
    "POST", ["articles", slug, "comments"] -> create_comment(r, slug)
    "DELETE", ["articles", slug, "comments", id] -> delete_comment(r, slug, id)
    _, _ -> Error(fail(404, "not found"))
  }
}

fn tags(r: Req) -> Result(Outcome, Response) {
  use rows <- read_then(r, sql.tags, [])
  case rows {
    [[names]] ->
      #(
        200,
        string_tree.from_string("{\"tags\":")
          |> string_tree.append_tree(jsonw.str_array(proto.col_text_array(names)))
          |> string_tree.append("}"),
      )
    _ -> fail(500, "database error")
  }
}

// ---------------------------------------------------------------- users

type Credentials {
  Credentials(username: Option(String), email: String, password: String)
}

fn register(r: Req) -> Result(Outcome, Response) {
  let decoder = {
    use username <- decode.field("username", decode.string)
    use email <- decode.field("email", decode.string)
    use password <- decode.field("password", decode.string)
    decode.success(Credentials(Some(username), email, password))
  }
  let msg = "username, email and password are required"
  use c <- result.try(body(r, "user", decoder, msg))
  let assert Some(username) = c.username
  use username <- result.try(nonempty(username, msg))
  use email <- result.try(nonempty(c.email, msg))
  use password <- result.try(nonempty(c.password, msg))
  use password <- result.try(password_ok(password))
  use hash <- result.try(hash_password(password))
  use rows <- result.try(write(sql.user_insert, [
    proto.text_param(username),
    proto.text_param(email),
    Some(hash),
  ]))
  case rows {
    [[id, username, email, bio, image]] ->
      reply(
        201,
        user_json(proto.col_text(email), jwt.issue(r.ctx.secret, proto.col_int(id), r.now), proto.col_text(username), bio, image),
      )
    _ -> Error(fail(500, "database error"))
  }
}

fn login(r: Req) -> Result(Outcome, Response) {
  let decoder = {
    use email <- decode.field("email", decode.string)
    use password <- decode.field("password", decode.string)
    decode.success(Credentials(None, email, password))
  }
  let msg = "email and password are required"
  use c <- result.try(body(r, "user", decoder, msg))
  use email <- result.try(nonempty(c.email, msg))
  use password <- result.try(nonempty(c.password, msg))
  use rows <- result.try(read(sql.user_by_email, [proto.text_param(email)]))
  case rows {
    [[id, username, email, bio, image, hash]] ->
      case bcrypt.verify(util.to_bits(password), proto.col_text(hash)) {
        True ->
          reply(
            200,
            user_json(proto.col_text(email), jwt.issue(r.ctx.secret, proto.col_int(id), r.now), proto.col_text(username), bio, image),
          )
        False -> Error(fail(401, "invalid email or password"))
      }
    _ -> Error(fail(401, "invalid email or password"))
  }
}

fn current_user(r: Req) -> Result(Outcome, Response) {
  use #(viewer, token) <- result.try(required(r))
  use rows <- read_then(r, sql.user_by_id, [proto.int_param(viewer)])
  case rows {
    [[_id, username, email, bio, image]] ->
      #(200, user_json(proto.col_text(email), token, proto.col_text(username), bio, image))
    _ -> fail(401, "unauthorized")
  }
}

type UserUpdate {
  UserUpdate(
    email: Option(String),
    username: Option(String),
    password: Option(String),
    bio: Option(String),
    image: Option(String),
  )
}

fn update_user(r: Req) -> Result(Outcome, Response) {
  use #(viewer, token) <- result.try(required(r))
  let decoder = {
    use email <- opt_field("email")
    use username <- opt_field("username")
    use password <- opt_field("password")
    use bio <- opt_field("bio")
    use image <- opt_field("image")
    decode.success(UserUpdate(email, username, password, bio, image))
  }
  let msg = "invalid user fields"
  use u <- result.try(body(r, "user", decoder, msg))
  use email <- result.try(opt_nonempty(u.email, msg))
  use username <- result.try(opt_nonempty(u.username, msg))
  use password <- result.try(opt_nonempty(u.password, msg))
  use bio <- result.try(opt_clean(u.bio, msg))
  use image <- result.try(opt_clean(u.image, msg))
  use hash <- result.try(case password {
    None -> Ok(None)
    Some(p) -> {
      use p <- result.try(password_ok(p))
      use h <- result.try(hash_password(p))
      Ok(Some(h))
    }
  })
  use rows <- result.try(write(sql.user_update, [
    proto.int_param(viewer),
    proto.opt_text_param(email),
    proto.opt_text_param(username),
    hash,
    proto.opt_text_param(bio),
    proto.opt_text_param(image),
  ]))
  case rows {
    [[_id, username, email, bio, image]] ->
      reply(200, user_json(proto.col_text(email), token, proto.col_text(username), bio, image))
    _ -> Error(fail(401, "unauthorized"))
  }
}

// ---------------------------------------------------------------- profiles

fn get_profile(r: Req, u: String) -> Result(Outcome, Response) {
  use u <- result.try(segment(u, "not found"))
  use viewer <- result.try(optional(r))
  use rows <- read_then(r, sql.profile, [proto.int_param(viewer), proto.text_param(u)])
  case rows {
    [[_id, username, bio, image, following]] ->
      #(200, wrap("profile", profile(proto.col_text(username), bio, image, proto.col_bool(following))))
    _ -> fail(404, "profile not found")
  }
}

fn follow(r: Req, u: String, following: Bool) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  use u <- result.try(segment(u, "not found"))
  let statement = case following {
    True -> sql.follow
    False -> sql.unfollow
  }
  use rows <- write_then(r, statement, [proto.int_param(viewer), proto.text_param(u)])
  case rows {
    [[username, bio, image]] -> #(200, wrap("profile", profile(proto.col_text(username), bio, image, following)))
    _ -> fail(404, "profile not found")
  }
}

// ---------------------------------------------------------------- articles

fn list_articles(r: Req) -> Result(Outcome, Response) {
  use viewer <- result.try(optional(r))
  let q = util.parse_query(r.query)
  use #(limit, offset) <- result.try(page(q))
  let base = [proto.int_param(viewer), proto.int_param(limit), proto.int_param(offset)]
  let #(statement, params) = case q.tag, q.author, q.favorited {
    Some(t), _, _ -> #(sql.list_tag, list.append(base, [proto.text_param(filter_value(t))]))
    None, Some(a), _ -> #(sql.list_author, list.append(base, [proto.text_param(filter_value(a))]))
    None, None, Some(f) -> #(sql.list_favorited, list.append(base, [proto.text_param(filter_value(f))]))
    None, None, None -> #(sql.list_all, base)
  }
  read_then(r, statement, params, article_list)
}

// Postgres text can't hold NUL, so a filter containing one can't match a tag or user; U+FFFD matches nothing either.
fn filter_value(v: String) -> String {
  case util.has_nul(util.to_bits(v)) {
    True -> "\u{FFFD}"
    False -> v
  }
}

fn feed(r: Req) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  use #(limit, offset) <- result.try(page(util.parse_query(r.query)))
  let window = case offset > util.max_i64 - limit {
    True -> util.max_i64
    False -> limit + offset
  }
  read_then(
    r,
    sql.feed,
    [proto.int_param(viewer), proto.int_param(limit), proto.int_param(offset), proto.int_param(window)],
    article_list,
  )
}

fn page(q: util.Query) -> Result(#(Int, Int), Response) {
  case util.page(q) {
    Ok(p) -> Ok(p)
    Error(_) -> Error(fail(422, "limit/offset must be integers in range"))
  }
}

fn article_list(rows: List(Row)) -> Response {
  let count = case rows {
    [[n, ..], ..] -> proto.col_int(n)
    _ -> 0
  }
  let items =
    list.filter_map(rows, fn(row) {
      case row {
        [_n, None, ..] -> Error(Nil)
        [_n, ..rest] -> Ok(list_article(rest))
        _ -> Error(Nil)
      }
    })
  #(
    200,
    string_tree.from_string("{\"articles\":[")
      |> string_tree.append_tree(string_tree.join(items, ","))
      |> string_tree.append("],\"articlesCount\":")
      |> string_tree.append_tree(jsonw.int(count))
      |> string_tree.append("}"),
  )
}

fn get_article(r: Req, slug: String) -> Result(Outcome, Response) {
  use slug <- result.try(segment(slug, "not found"))
  use viewer <- result.try(optional(r))
  use rows <- read_then(r, sql.article_by_slug, [proto.int_param(viewer), proto.text_param(slug)])
  case rows {
    [row] -> #(200, wrap("article", full_article(row)))
    _ -> fail(404, "article not found")
  }
}

type NewArticle {
  NewArticle(title: String, description: String, body: String, tags: Option(List(String)))
}

fn create_article(r: Req) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  let decoder = {
    use title <- decode.field("title", decode.string)
    use description <- decode.field("description", decode.string)
    use body <- decode.field("body", decode.string)
    use tags <- decode.optional_field("tagList", None, decode.optional(decode.list(decode.string)))
    decode.success(NewArticle(title, description, body, tags))
  }
  let msg = "title, description and body are required"
  use a <- result.try(body(r, "article", decoder, msg))
  use title <- result.try(nonempty(a.title, msg))
  use description <- result.try(nonempty(a.description, msg))
  use text <- result.try(nonempty(a.body, msg))
  use tags <- result.try(tag_list(a.tags))
  use row <- result.try(create_article_rows(viewer, title, description, text, tags, 0))
  reply(201, wrap("article", full_article(row)))
}

// With tags the insert is two statements in one Sync group (one transaction); a deadlock or serialization
// failure between concurrent creates is retried once.
fn create_article_rows(
  viewer: Int,
  title: String,
  description: String,
  text: String,
  tags: List(String),
  attempt: Int,
) -> Result(Row, Response) {
  let article = [proto.int_param(viewer), proto.text_param(title), proto.text_param(description), proto.text_param(text)]
  let result = case tags {
    [] -> exec(pick_write(), [#(sql.article_create_plain, article)])
    _ -> {
      let tag_param = proto.text_array_param(tags)
      let reply = process.new_subject()
      process.send(
        pick_write(),
        Exec(
          monotonic_ms() + db_timeout_ms,
          [#(sql.tags_upsert, [tag_param]), #(sql.article_create_tagged, list.append(article, [tag_param]))],
          reply,
        ),
      )
      case process.receive(reply, db_timeout_ms) {
        Ok(Ok(results)) -> Ok(results)
        Ok(Error(PgError(code, _))) if attempt == 0 && { code == "40P01" || code == "40001" } ->
          case create_article_rows(viewer, title, description, text, tags, 1) {
            Ok(row) -> Ok([[row]])
            Error(e) -> Error(e)
          }
        Ok(Error(e)) -> Error(pg_error(e))
        Error(_) -> Error(fail(503, "database timeout"))
      }
    }
  }
  case result {
    Ok(results) ->
      case list.last(results) {
        Ok([row]) -> Ok(row)
        _ -> Error(fail(500, "database error"))
      }
    Error(e) -> Error(e)
  }
}

fn tag_list(tags: Option(List(String))) -> Result(List(String), Response) {
  let bad = fail(422, "tagList must be an array of non-empty strings")
  case tags {
    None -> Ok([])
    Some(list) ->
      case list.all(list, fn(t) { t != "" && !util.has_nul(util.to_bits(t)) }) {
        True -> Ok(list)
        False -> Error(bad)
      }
  }
}

type ArticleUpdate {
  ArticleUpdate(title: Option(String), description: Option(String), body: Option(String))
}

fn update_article(r: Req, slug: String) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  let decoder = {
    use title <- opt_field("title")
    use description <- opt_field("description")
    use body <- opt_field("body")
    decode.success(ArticleUpdate(title, description, body))
  }
  let msg = "title, description and body must be non-empty strings"
  use a <- result.try(body(r, "article", decoder, msg))
  use title <- result.try(opt_nonempty(a.title, msg))
  use description <- result.try(opt_nonempty(a.description, msg))
  use text <- result.try(opt_nonempty(a.body, msg))
  use slug <- result.try(segment(slug, "article not found"))
  use rows <- result.try(write(sql.article_update, [
    proto.int_param(viewer),
    proto.text_param(slug),
    proto.opt_text_param(title),
    proto.opt_text_param(description),
    proto.opt_text_param(text),
  ]))
  case rows {
    [row] -> reply(200, wrap("article", full_article(row)))
    _ -> probe(sql.article_probe, [proto.text_param(slug)], viewer)
  }
}

fn delete_article(r: Req, slug: String) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  use slug <- result.try(segment(slug, "not found"))
  use rows <- result.try(write(sql.article_delete, [proto.int_param(viewer), proto.text_param(slug)]))
  case rows {
    [] -> probe(sql.article_probe, [proto.text_param(slug)], viewer)
    _ -> reply(204, string_tree.new())
  }
}

// After a 0-row ownership-checked write: either it doesn't exist (404) or it isn't the viewer's (403).
fn probe(statement: Int, params: List(Param), viewer: Int) -> Result(Outcome, Response) {
  use rows <- result.try(read(statement, params))
  case rows {
    [[author]] ->
      case proto.col_int(author) == viewer {
        True -> Error(fail(404, "not found"))
        False -> Error(fail(403, "forbidden"))
      }
    _ -> Error(fail(404, "not found"))
  }
}

// ---------------------------------------------------------------- favorites

fn favorite(r: Req, slug: String, favorited: Bool) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  use slug <- result.try(segment(slug, "not found"))
  let statement = case favorited {
    True -> sql.favorite
    False -> sql.unfavorite
  }
  use rows <- write_then(r, statement, [proto.int_param(viewer), proto.text_param(slug)])
  case rows {
    [row] -> #(200, wrap("article", full_article(row)))
    _ -> fail(404, "article not found")
  }
}

// ---------------------------------------------------------------- comments

fn list_comments(r: Req, slug: String) -> Result(Outcome, Response) {
  use slug <- result.try(segment(slug, "not found"))
  use viewer <- result.try(optional(r))
  use rows <- read_then(r, sql.comments, [proto.int_param(viewer), proto.text_param(slug)])
  case rows {
    [] -> fail(404, "article not found")
    _ -> {
      let items =
        list.filter_map(rows, fn(row) {
          case row {
            [_aid, None, ..] -> Error(Nil)
            [_aid, cid, body, created, updated, username, bio, image, following] ->
              Ok(comment(cid, body, created, updated, username, bio, image, proto.col_bool(following)))
            _ -> Error(Nil)
          }
        })
      #(
        200,
        string_tree.from_string("{\"comments\":[")
          |> string_tree.append_tree(string_tree.join(items, ","))
          |> string_tree.append("]}"),
      )
    }
  }
}

fn create_comment(r: Req, slug: String) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  // Body before article: an invalid body on an unknown article is 422.
  let decoder = {
    use body <- decode.field("body", decode.string)
    decode.success(body)
  }
  use text <- result.try(body(r, "comment", decoder, "body is required"))
  use text <- result.try(nonempty(text, "body is required"))
  use slug <- result.try(segment(slug, "article not found"))
  use rows <- write_then(r, sql.comment_create, [
    proto.int_param(viewer),
    proto.text_param(slug),
    proto.text_param(text),
  ])
  case rows {
    [[id, body, created, updated, username, bio, image]] ->
      #(201, wrap("comment", comment(id, body, created, updated, username, bio, image, False)))
    _ -> fail(404, "article not found")
  }
}

fn delete_comment(r: Req, slug: String, id: String) -> Result(Outcome, Response) {
  use #(viewer, _) <- result.try(required(r))
  case util.parse_digits(id), util.decode_segment(slug) {
    Ok(id), Ok(slug) -> {
      use rows <- result.try(write(sql.comment_delete, [
        proto.int_param(viewer),
        proto.int_param(id),
        proto.text_param(slug),
      ]))
      case rows {
        [] -> probe(sql.comment_probe, [proto.int_param(id), proto.text_param(slug)], viewer)
        _ -> reply(204, string_tree.new())
      }
    }
    _, _ -> Error(fail(404, "comment not found"))
  }
}

// ---------------------------------------------------------------- request helpers

fn required(r: Req) -> Result(#(Int, String), Response) {
  case jwt.check(r.auth, r.ctx.secret, r.now) {
    jwt.User(id, token) -> Ok(#(id, token))
    _ -> Error(fail(401, "unauthorized"))
  }
}

fn optional(r: Req) -> Result(Int, Response) {
  case jwt.check(r.auth, r.ctx.secret, r.now) {
    jwt.User(id, _) -> Ok(id)
    jwt.Anonymous -> Ok(0)
    jwt.Invalid -> Error(fail(401, "unauthorized"))
  }
}

fn segment(seg: String, msg: String) -> Result(String, Response) {
  case util.decode_segment(seg) {
    Ok(s) -> Ok(s)
    Error(_) -> Error(fail(404, msg))
  }
}

/// Decodes `{"<key>": {...}}`; any shape problem is a 422.
fn body(r: Req, key: String, decoder: decode.Decoder(t), msg: String) -> Result(t, Response) {
  let wrapped = {
    use inner <- decode.field(key, decoder)
    decode.success(inner)
  }
  case json.parse_bits(r.body, wrapped) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(fail(422, msg))
  }
}

/// Absent or null: unchanged (`None`). A string is kept; any other type fails the decode.
fn opt_field(key: String, next: fn(Option(String)) -> decode.Decoder(t)) -> decode.Decoder(t) {
  decode.optional_field(key, None, decode.optional(decode.string), next)
}

fn clean(s: String) -> Bool {
  !util.has_nul(util.to_bits(s))
}

fn nonempty(s: String, msg: String) -> Result(String, Response) {
  case s != "" && clean(s) {
    True -> Ok(s)
    False -> Error(fail(422, msg))
  }
}

fn opt_nonempty(s: Option(String), msg: String) -> Result(Option(String), Response) {
  case s {
    None -> Ok(None)
    Some(v) ->
      case nonempty(v, msg) {
        Ok(v) -> Ok(Some(v))
        Error(e) -> Error(e)
      }
  }
}

fn opt_clean(s: Option(String), msg: String) -> Result(Option(String), Response) {
  case s {
    Some(v) ->
      case clean(v) {
        True -> Ok(s)
        False -> Error(fail(422, msg))
      }
    None -> Ok(None)
  }
}

fn hash_password(p: String) -> Result(BitArray, Response) {
  case bcrypt.hash(util.to_bits(p)) {
    Ok(h) -> Ok(h)
    Error(_) -> Error(fail(503, "password hashing unavailable"))
  }
}

fn password_ok(p: String) -> Result(String, Response) {
  case bit_array.byte_size(util.to_bits(p)) > 72 {
    True -> Error(fail(422, "password is too long"))
    False -> Ok(p)
  }
}

// ---------------------------------------------------------------- response writers

fn wrap(key: String, inner: StringTree) -> StringTree {
  string_tree.from_strings(["{\"", key, "\":"])
  |> string_tree.append_tree(inner)
  |> string_tree.append("}")
}

fn profile(username: BitArray, bio: Option(BitArray), image: Option(BitArray), following: Bool) -> StringTree {
  string_tree.concat([
    string_tree.from_string("{\"username\":"),
    jsonw.str(username),
    string_tree.from_string(",\"bio\":"),
    jsonw.opt_str(bio),
    string_tree.from_string(",\"image\":"),
    jsonw.opt_str(image),
    string_tree.from_string(",\"following\":"),
    jsonw.bool(following),
    string_tree.from_string("}"),
  ])
}

// [id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following]
fn list_article(row: Row) -> StringTree {
  case row {
    [_id, slug, title, description, created, updated, tags, favc, favd, username, bio, image, following] ->
      string_tree.concat([
        string_tree.from_string("{\"slug\":"),
        jsonw.str(proto.col_text(slug)),
        string_tree.from_string(",\"title\":"),
        jsonw.str(proto.col_text(title)),
        string_tree.from_string(",\"description\":"),
        jsonw.str(proto.col_text(description)),
        article_tail(tags, created, updated, favd, favc, username, bio, image, following),
      ])
    _ -> string_tree.from_string("null")
  }
}

// The same columns with `body` after `description`.
fn full_article(row: Row) -> StringTree {
  case row {
    [_id, slug, title, description, body, created, updated, tags, favc, favd, username, bio, image, following] ->
      string_tree.concat([
        string_tree.from_string("{\"slug\":"),
        jsonw.str(proto.col_text(slug)),
        string_tree.from_string(",\"title\":"),
        jsonw.str(proto.col_text(title)),
        string_tree.from_string(",\"description\":"),
        jsonw.str(proto.col_text(description)),
        string_tree.from_string(",\"body\":"),
        jsonw.str(proto.col_text(body)),
        article_tail(tags, created, updated, favd, favc, username, bio, image, following),
      ])
    _ -> string_tree.from_string("null")
  }
}

fn article_tail(
  tags: Option(BitArray),
  created: Option(BitArray),
  updated: Option(BitArray),
  favd: Option(BitArray),
  favc: Option(BitArray),
  username: Option(BitArray),
  bio: Option(BitArray),
  image: Option(BitArray),
  following: Option(BitArray),
) -> StringTree {
  string_tree.concat([
    string_tree.from_string(",\"tagList\":"),
    jsonw.str_array(proto.col_text_array(tags)),
    string_tree.from_string(",\"createdAt\":"),
    jsonw.ts(proto.col_micros(created)),
    string_tree.from_string(",\"updatedAt\":"),
    jsonw.ts(proto.col_micros(updated)),
    string_tree.from_string(",\"favorited\":"),
    jsonw.bool(proto.col_bool(favd)),
    string_tree.from_string(",\"favoritesCount\":"),
    jsonw.int(proto.col_int(favc)),
    string_tree.from_string(",\"author\":"),
    profile(proto.col_text(username), bio, image, proto.col_bool(following)),
    string_tree.from_string("}"),
  ])
}

fn comment(
  id: Option(BitArray),
  body: Option(BitArray),
  created: Option(BitArray),
  updated: Option(BitArray),
  username: Option(BitArray),
  bio: Option(BitArray),
  image: Option(BitArray),
  following: Bool,
) -> StringTree {
  string_tree.concat([
    string_tree.from_string("{\"id\":"),
    jsonw.int(proto.col_int(id)),
    string_tree.from_string(",\"createdAt\":"),
    jsonw.ts(proto.col_micros(created)),
    string_tree.from_string(",\"updatedAt\":"),
    jsonw.ts(proto.col_micros(updated)),
    string_tree.from_string(",\"body\":"),
    jsonw.str(proto.col_text(body)),
    string_tree.from_string(",\"author\":"),
    profile(proto.col_text(username), bio, image, following),
    string_tree.from_string("}"),
  ])
}

fn user_json(email: BitArray, token: String, username: BitArray, bio: Option(BitArray), image: Option(BitArray)) -> StringTree {
  string_tree.concat([
    string_tree.from_string("{\"user\":{\"email\":"),
    jsonw.str(email),
    string_tree.from_string(",\"token\":"),
    jsonw.str_s(token),
    string_tree.from_string(",\"username\":"),
    jsonw.str(username),
    string_tree.from_string(",\"bio\":"),
    jsonw.opt_str(bio),
    string_tree.from_string(",\"image\":"),
    jsonw.opt_str(image),
    string_tree.from_string("}}"),
  ])
}
