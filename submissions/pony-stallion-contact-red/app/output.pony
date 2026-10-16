use pg = "postgres"
use json = "json"
use "time"

primitive _Output
  fun error_value(message: String): json.JSONObject =>
    json.JSONObject.update("errors",
      json.JSONObject.update("body", json.JSONArray.push(message)))

  fun error_body(message: String): String => error_value(message).print()

  fun rows(result: pg.Result): pg.Rows ? =>
    (result as pg.ResultSet).rows()

  fun first(result: pg.Result): (pg.Row | None) ? =>
    let rs = rows(result)?
    if rs.size() == 0 then None else rs(0)? end

  fun value(row: pg.Row, i: USize): json.JSONValue ? =>
    match row.fields(i)?.value
    | let s: String => s
    | let n: I64 => n
    | let n: I32 => n.i64()
    | let b: Bool => b
    | None => None
    | let a: pg.PgArray =>
      var out = json.JSONArray
      for v in a.elements.values() do out = out.push(v as String) end
      out
    | let t: pg.PgTimestamp =>
      let us = t.microseconds + 946_684_800_000_000
      let seconds = us.fld(1_000_000)
      let millis = us.mod(1_000_000) / 1000
      let fraction: String val = millis.string()
      let padding: String val = if millis < 10 then "00"
        elseif millis < 100 then "0" else "" end
      PosixDate(seconds).format("%Y-%m-%dT%H:%M:%S")?
        + "." + padding + fraction + "Z"
    else error
    end

  fun id(row: pg.Row, i: USize = 0): I64 ? =>
    row.fields(i)?.value as I64

  fun profile(row: pg.Row, i: USize,
    following: (Bool | None) = None): json.JSONObject ?
  =>
    json.JSONObject.update("username", value(row, i)?)
      .update("bio", value(row, i + 1)?)
      .update("image", value(row, i + 2)?)
      .update("following", match following
        | let b: Bool => b
        else value(row, i + 3)?
        end)

  fun user(row: pg.Row, token: String): json.JSONObject ? =>
    json.JSONObject.update("username", value(row, 1)?)
      .update("email", value(row, 2)?)
      .update("bio", value(row, 3)?)
      .update("image", value(row, 4)?)
      .update("token", token)

  fun article(row: pg.Row, full: Bool): json.JSONObject ? =>
    let delta: USize = if full then 1 else 0 end
    var obj = json.JSONObject.update("slug", value(row, 1)?)
      .update("title", value(row, 2)?)
      .update("description", value(row, 3)?)
      .update("createdAt", value(row, 4 + delta)?)
      .update("updatedAt", value(row, 5 + delta)?)
      .update("tagList", value(row, 6 + delta)?)
      .update("favoritesCount", value(row, 7 + delta)?)
      .update("favorited", value(row, 8 + delta)?)
      .update("author", profile(row, 9 + delta)?)
    if full then obj = obj.update("body", value(row, 4)?) end
    obj

  fun comment(row: pg.Row, following: (Bool | None) = None)
    : json.JSONObject ?
  =>
    json.JSONObject.update("id", value(row, 0)?)
      .update("body", value(row, 1)?)
      .update("createdAt", value(row, 2)?)
      .update("updatedAt", value(row, 3)?)
      .update("author", profile(row, 4, following)?)
