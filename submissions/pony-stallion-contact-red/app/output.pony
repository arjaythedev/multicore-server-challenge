use pg = "postgres"
use "time"

primitive _Output
  fun error_body(message: String): String =>
    recover val
      let out = String(128)
      out.append("{\"errors\":{\"body\":[")
      _quoted(out, message)
      out.append("]}}")
      out
    end

  fun rows(result: pg.Result): pg.Rows ? =>
    (result as pg.ResultSet).rows()

  fun first(result: pg.Result): (pg.Row | None) ? =>
    let rs = rows(result)?
    if rs.size() == 0 then None else rs(0)? end

  fun _field(out: String ref, row: pg.Row, i: USize) ? =>
    match row.fields(i)?
    | let s: String => _quoted(out, s)
    | let n: I64 => out.append(n.string())
    | let n: I32 => out.append(n.string())
    | let b: Bool => out.append(if b then "true" else "false" end)
    | None => out.append("null")
    | let a: pg.PgArray =>
      out.push('[')
      var first_element = true
      for v in a.elements.values() do
        if first_element then first_element = false else out.push(',') end
        _quoted(out, v as String)
      end
      out.push(']')
    | let t: pg.PgTimestamp =>
      let us = t.microseconds + 946_684_800_000_000
      let seconds = us.fld(1_000_000)
      let millis = us.mod(1_000_000) / 1000
      let fraction: String val = millis.string()
      let padding: String val = if millis < 10 then "00"
        elseif millis < 100 then "0" else "" end
      _quoted(out, PosixDate(seconds).format("%Y-%m-%dT%H:%M:%S")?
        + "." + padding + fraction + "Z")
    else error
    end

  fun id(row: pg.Row, i: USize = 0): I64 ? =>
    row.fields(i)? as I64

  fun profile_body(row: pg.Row, i: USize,
    following: (Bool | None) = None): String ?
  =>
    recover val
      let out = String(256)
      out.append("{\"profile\":")
      _profile(out, row, i, following)?
      out.push('}')
      out
    end

  fun user_body(row: pg.Row, token: String): String ? =>
    recover val
      let out = String(256)
      out.append("{\"user\":{\"username\":")
      _field(out, row, 1)?
      out.append(",\"email\":")
      _field(out, row, 2)?
      out.append(",\"bio\":")
      _field(out, row, 3)?
      out.append(",\"image\":")
      _field(out, row, 4)?
      out.append(",\"token\":")
      _quoted(out, token)
      out.append("}}")
      out
    end

  fun article_body(row: pg.Row): String ? =>
    recover val
      let out = String(512)
      out.append("{\"article\":{\"slug\":")
      _field(out, row, 1)?
      out.append(",\"title\":")
      _field(out, row, 2)?
      out.append(",\"description\":")
      _field(out, row, 3)?
      out.append(",\"body\":")
      _field(out, row, 4)?
      out.append(",\"createdAt\":")
      _field(out, row, 5)?
      out.append(",\"updatedAt\":")
      _field(out, row, 6)?
      out.append(",\"tagList\":")
      _field(out, row, 7)?
      out.append(",\"favoritesCount\":")
      _field(out, row, 8)?
      out.append(",\"favorited\":")
      _field(out, row, 9)?
      out.append(",\"author\":")
      _profile(out, row, 10, None)?
      out.append("}}")
      out
    end

  fun comment_body(row: pg.Row, following: (Bool | None) = None): String ? =>
    recover val
      let out = String(256)
      out.append("{\"comment\":")
      _comment(out, row, following)?
      out.push('}')
      out
    end

  fun comments_body(rows': pg.Rows): String ? =>
    recover val
      let out = String(512)
      out.append("{\"comments\":[")
      var first_element = true
      for row in rows'.values() do
        if first_element then first_element = false else out.push(',') end
        _comment(out, row, None)?
      end
      out.append("]}")
      out
    end

  fun _profile(out: String ref, row: pg.Row, i: USize,
    following: (Bool | None)) ?
  =>
    out.append("{\"username\":")
    _field(out, row, i)?
    out.append(",\"bio\":")
    _field(out, row, i + 1)?
    out.append(",\"image\":")
    _field(out, row, i + 2)?
    out.append(",\"following\":")
    match following
    | let b: Bool => out.append(if b then "true" else "false" end)
    else _field(out, row, i + 3)?
    end
    out.push('}')

  fun _comment(out: String ref, row: pg.Row, following: (Bool | None)) ?
  =>
    out.append("{\"id\":")
    _field(out, row, 0)?
    out.append(",\"body\":")
    _field(out, row, 1)?
    out.append(",\"createdAt\":")
    _field(out, row, 2)?
    out.append(",\"updatedAt\":")
    _field(out, row, 3)?
    out.append(",\"author\":")
    _profile(out, row, 4, following)?
    out.push('}')

  fun _quoted(out: String ref, value: String box) =>
    out.push('"')
    var start: USize = 0
    var index: USize = 0
    for byte in value.values() do
      if (byte < 0x20) or (byte == '"') or (byte == '\\') then
        out.append(value, start, index - start)
        match byte
        | '"' => out.append("\\\"")
        | '\\' => out.append("\\\\")
        | 0x08 => out.append("\\b")
        | 0x0c => out.append("\\f")
        | '\n' => out.append("\\n")
        | '\r' => out.append("\\r")
        | '\t' => out.append("\\t")
        else
          out.append("\\u00")
          out.push(_hex(byte >> 4))
          out.push(_hex(byte and 0x0f))
        end
        start = index + 1
      end
      index = index + 1
    end
    out.append(value, start, index - start)
    out.push('"')

  fun _hex(value: U8): U8 =>
    if value < 10 then '0' + value else 'a' + (value - 10) end
