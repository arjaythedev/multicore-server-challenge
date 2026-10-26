defmodule Conduit.Handler do
  @moduledoc false
  # Routing, validation and the per-endpoint flows. `handle/5` returns `{status, iodata}`.

  alias Conduit.{Db, Jwt, Json, Util}
  alias Conduit.Render.Nif, as: Render
  require Logger

  def init do
    :persistent_term.put({__MODULE__, :last_log}, :atomics.new(1, []))

    # The hot reads render their JSON in C straight from the raw rows (Conduit.Render.Nif); RENDER_NIF=0 renders
    # them here instead (the reference the NIF's output is checked against byte for byte).
    :persistent_term.put({__MODULE__, :render_nif}, System.get_env("RENDER_NIF", "1") != "0")
  end

  defp nif?, do: :persistent_term.get({__MODULE__, :render_nif})

  def handle("/api/" <> rest, method, query, auth, body) do
    r = %{query: query, auth: auth, body: body, now: System.os_time(:second)}

    try do
      route(method, :binary.split(rest, "/", [:global]), r)
    catch
      {:fail, status, msg} ->
        {status, Json.error(msg)}

      {:pg, code} ->
        pg_error(code)

      {:db_down, e} ->
        log_db_down(e)
        {503, Json.error("database unavailable")}
    end
  end

  def handle(_path, _method, _query, _auth, _body), do: {404, Json.error("not found")}

  # One line per second at most: under an outage every request lands here, and a flood of log writes would take CPU
  # from the requests that could still succeed.
  defp log_db_down(e) do
    now = System.monotonic_time(:second)
    ref = :persistent_term.get({__MODULE__, :last_log})

    last = :atomics.get(ref, 1)

    if now != last and :atomics.compare_exchange(ref, 1, last, now) == :ok do
      Logger.error("database unavailable: #{inspect(e)}")
    end
  end

  defp pg_error("23505"), do: {422, Json.error("has already been taken")}
  defp pg_error("23503"), do: {404, Json.error("not found")}

  defp pg_error(code) when code in ["57014", "55P03", "53300"],
    do: {503, Json.error("database busy")}

  defp pg_error("08" <> _), do: {503, Json.error("database unavailable")}

  defp pg_error(code) do
    Logger.error("postgres error #{code}")
    {500, Json.error("database error")}
  end

  defp fail(status, msg), do: throw({:fail, status, msg})

  # ------------------------------------------------------------------ routes

  defp route(:GET, ["tags"], _r) do
    if nif?() do
      [row] = Db.read_raw(:tags, [])
      {200, Render.tags(row)}
    else
      [[names]] = Db.read(:tags, [])
      {200, ["{\"tags\":[", names |> Enum.map(&Json.str/1) |> Enum.intersperse(?,), "]}"]}
    end
  end

  defp route(:POST, ["users"], r), do: register(r)
  defp route(:POST, ["users", "login"], r), do: login(r)

  defp route(:GET, ["user"], r) do
    viewer = required(r)

    case Db.read(:user_by_id, [viewer]) do
      [[_id, username, email, bio, image]] ->
        {200, user_json(email, token_of(r), username, bio, image)}

      _ ->
        fail(401, "unauthorized")
    end
  end

  defp route(:PUT, ["user"], r), do: update_user(r)

  defp route(:GET, ["profiles", u], r) do
    u = segment!(u)
    viewer = optional(r)

    case if(nif?(), do: Db.read_raw(:profile, [viewer, u]), else: Db.read(:profile, [viewer, u])) do
      [row] when is_binary(row) ->
        {200, Render.profile(row)}

      [[_id, username, bio, image, following]] ->
        {200, ["{\"profile\":", profile(username, bio, image, following), "}"]}

      _ ->
        fail(404, "profile not found")
    end
  end

  defp route(m, ["profiles", u, "follow"], r) when m in [:POST, :DELETE] do
    viewer = required(r)
    u = segment!(u)
    follow? = m == :POST

    case Db.write(if(follow?, do: :follow, else: :unfollow), [viewer, u]) do
      [[username, bio, image]] ->
        {200, ["{\"profile\":", profile(username, bio, image, follow?), "}"]}

      _ ->
        fail(404, "profile not found")
    end
  end

  defp route(:GET, ["articles"], r), do: list(r)
  defp route(:POST, ["articles"], r), do: create_article(r)
  defp route(:GET, ["articles", "feed"], r), do: feed(r)

  defp route(:GET, ["articles", slug], r) do
    slug = segment!(slug)
    viewer = optional(r)

    case if(nif?(),
           do: Db.read_raw(:article_by_slug, [viewer, slug]),
           else: Db.read(:article_by_slug, [viewer, slug])
         ) do
      [row] when is_binary(row) -> {200, Render.article(row)}
      [row] -> {200, ["{\"article\":", full_article(row), "}"]}
      _ -> fail(404, "article not found")
    end
  end

  defp route(:PUT, ["articles", slug], r), do: update_article(r, slug)

  defp route(:DELETE, ["articles", slug], r) do
    viewer = required(r)
    slug = segment!(slug)

    case Db.write(:article_delete, [viewer, slug]) do
      [] -> probe(:article_probe, [slug], viewer)
      _ -> {204, []}
    end
  end

  defp route(m, ["articles", slug, "favorite"], r) when m in [:POST, :DELETE] do
    viewer = required(r)
    slug = segment!(slug)

    case Db.write(if(m == :POST, do: :favorite, else: :unfavorite), [viewer, slug]) do
      [row] -> {200, ["{\"article\":", full_article(row), "}"]}
      _ -> fail(404, "article not found")
    end
  end

  defp route(:GET, ["articles", slug, "comments"], r) do
    slug = segment!(slug)
    viewer = optional(r)

    case if(nif?(),
           do: Db.read_raw(:comments, [viewer, slug]),
           else: Db.read(:comments, [viewer, slug])
         ) do
      [] ->
        fail(404, "article not found")

      [row | _] = rows when is_binary(row) ->
        {200, Render.comments(rows)}

      rows ->
        items =
          for [_aid, cid, body, created, updated, username, bio, image, following] <- rows,
              cid != nil do
            comment(cid, body, created, updated, username, bio, image, following)
          end

        {200, ["{\"comments\":[", Enum.intersperse(items, ?,), "]}"]}
    end
  end

  defp route(:POST, ["articles", slug, "comments"], r) do
    viewer = required(r)
    # Body before article: an invalid body on an unknown article is 422.
    c = wrapper!(r.body, "comment")
    text = req_str!(c, "body", "body is required")
    slug = segment_or_404!(slug, "article not found")

    case Db.write(:comment_create, [viewer, slug, text]) do
      [[id, body, created, updated, username, bio, image]] ->
        {201,
         ["{\"comment\":", comment(id, body, created, updated, username, bio, image, false), "}"]}

      _ ->
        fail(404, "article not found")
    end
  end

  defp route(:DELETE, ["articles", slug, "comments", id], r) do
    viewer = required(r)

    with id when is_integer(id) <- Util.parse_digits(id),
         slug when is_binary(slug) <- Util.decode_segment(slug) do
      case Db.write(:comment_delete, [viewer, id, slug]) do
        [] -> probe(:comment_probe, [id, slug], viewer)
        _ -> {204, []}
      end
    else
      _ -> fail(404, "comment not found")
    end
  end

  defp route(_method, _segs, _r), do: fail(404, "not found")

  # After a 0-row ownership-checked write: either it doesn't exist (404) or it isn't the viewer's (403).
  defp probe(stmt, params, viewer) do
    case Db.read(stmt, params) do
      [[author]] when author != viewer -> fail(403, "forbidden")
      _ -> fail(404, "not found")
    end
  end

  # ------------------------------------------------------------------ users

  defp register(r) do
    u = wrapper!(r.body, "user")
    msg = "username, email and password are required"
    username = req_str!(u, "username", msg)
    email = req_str!(u, "email", msg)
    password = req_str!(u, "password", msg)
    if byte_size(password) > 72, do: fail(422, "password is too long")

    hash = new_hash(password)

    [[id, username, email, bio, image]] = Db.write(:user_insert, [username, email, hash])
    {201, user_json(email, Jwt.issue(id, r.now), username, bio, image)}
  end

  defp login(r) do
    u = wrapper!(r.body, "user")
    msg = "email and password are required"
    email = req_str!(u, "email", msg)
    password = req_str!(u, "password", msg)

    case Db.read(:user_by_email, [email]) do
      [[id, username, email, bio, image, hash]] ->
        if Conduit.Bcrypt.verify(password, hash) do
          {200, user_json(email, Jwt.issue(id, r.now), username, bio, image)}
        else
          fail(401, "invalid email or password")
        end

      _ ->
        fail(401, "invalid email or password")
    end
  end

  # Cost-10 bcrypt with a fresh salt (Conduit.Bcrypt); the password is already checked to be <= 72 bytes, no NUL.
  defp new_hash(password) do
    case Conduit.Bcrypt.hash(password) do
      {:ok, hash} -> hash
      :error -> fail(503, "password hashing unavailable")
    end
  end

  defp update_user(r) do
    viewer = required(r)
    u = wrapper!(r.body, "user")
    msg = "invalid user fields"
    email = opt_str!(u, "email", true, msg)
    username = opt_str!(u, "username", true, msg)
    password = opt_str!(u, "password", true, msg)
    bio = opt_str!(u, "bio", false, msg)
    image = opt_str!(u, "image", false, msg)
    if password && byte_size(password) > 72, do: fail(422, "password is too long")

    hash = password && new_hash(password)

    case Db.write(:user_update, [viewer, email, username, hash, bio, image]) do
      [[_id, username, email, bio, image]] ->
        {200, user_json(email, token_of(r), username, bio, image)}

      _ ->
        fail(401, "unauthorized")
    end
  end

  # ------------------------------------------------------------------ articles

  defp list(r) do
    viewer = optional(r)
    q = Util.parse_query(r.query)
    {:ok, limit, offset} = page!(q)

    {stmt, extra} =
      cond do
        t = q["tag"] -> {:list_tag, [t]}
        a = q["author"] -> {:list_author, [a]}
        f = q["favorited"] -> {:list_favorited, [f]}
        true -> {:list_all, []}
      end

    case extra do
      [v] when is_binary(v) ->
        # Postgres text can't hold NUL, so no tag or user can match.
        if :binary.match(v, <<0>>) != :nomatch do
          {200, "{\"articles\":[],\"articlesCount\":0}"}
        else
          list_response(stmt, [viewer, limit, offset | extra])
        end

      _ ->
        list_response(stmt, [viewer, limit, offset | extra])
    end
  end

  defp feed(r) do
    viewer = required(r)
    {:ok, limit, offset} = page!(Util.parse_query(r.query))

    list_response(:feed, [viewer, limit, offset, min(limit + offset, 9_223_372_036_854_775_807)])
  end

  defp list_response(stmt, params) do
    if nif?(),
      do: {200, Render.list(Db.read_raw(stmt, params))},
      else: article_list(Db.read(stmt, params))
  end

  defp page!(q) do
    case Util.page(q) do
      {:ok, _, _} = ok -> ok
      :error -> fail(422, "limit/offset must be integers in range")
    end
  end

  defp article_list(rows) do
    count =
      case rows do
        [[n | _] | _] -> n
        [] -> 0
      end

    items = for [_n, id | rest] <- rows, id != nil, do: list_article([id | rest])

    {200,
     [
       "{\"articles\":[",
       Enum.intersperse(items, ?,),
       "],\"articlesCount\":",
       Json.int(count),
       "}"
     ]}
  end

  defp create_article(r) do
    viewer = required(r)
    a = wrapper!(r.body, "article")
    msg = "title, description and body are required"
    title = req_str!(a, "title", msg)
    description = req_str!(a, "description", msg)
    text = req_str!(a, "body", msg)
    tags = tag_list!(a)

    row =
      if tags == [] do
        [row] = Db.write(:article_create_plain, [viewer, title, description, text])
        row
      else
        create_tagged(viewer, title, description, text, tags, 0)
      end

    {201, ["{\"article\":", full_article(row), "}"]}
  end

  # A deadlock or serialization failure between concurrent creates is retried once.
  defp create_tagged(viewer, title, description, text, tags, attempt) do
    [_, [row]] =
      Db.write_all([
        {:tags_upsert, [tags]},
        {:article_create_tagged, [viewer, title, description, text, tags]}
      ])

    row
  catch
    {:pg, code} when code in ["40P01", "40001"] and attempt == 0 ->
      create_tagged(viewer, title, description, text, tags, 1)
  end

  defp tag_list!(a) do
    bad = "tagList must be an array of non-empty strings"

    case Map.get(a, "tagList") do
      nil ->
        []

      :null ->
        []

      list when is_list(list) ->
        Enum.each(list, fn
          t when is_binary(t) and t != "" -> if not clean?(t), do: fail(422, bad)
          _ -> fail(422, bad)
        end)

        list

      _ ->
        fail(422, bad)
    end
  end

  defp update_article(r, slug) do
    viewer = required(r)
    a = wrapper!(r.body, "article")
    msg = "title, description and body must be non-empty strings"
    title = opt_str!(a, "title", true, msg)
    description = opt_str!(a, "description", true, msg)
    text = opt_str!(a, "body", true, msg)
    slug = segment_or_404!(slug, "article not found")

    case Db.write(:article_update, [viewer, slug, title, description, text]) do
      [row] -> {200, ["{\"article\":", full_article(row), "}"]}
      [] -> probe(:article_probe, [slug], viewer)
    end
  end

  # ------------------------------------------------------------------ request helpers

  defp required(r) do
    case Jwt.check(r.auth, r.now) do
      {:user, id} -> id
      _ -> fail(401, "unauthorized")
    end
  end

  defp optional(r) do
    case Jwt.check(r.auth, r.now) do
      {:user, id} -> id
      :anonymous -> 0
      :invalid -> fail(401, "unauthorized")
    end
  end

  # The presented token (only called after `required` accepted it).
  defp token_of(%{auth: "Token " <> token}), do: token

  defp segment!(seg), do: segment_or_404!(seg, "not found")

  defp segment_or_404!(seg, msg) do
    case Util.decode_segment(seg) do
      s when is_binary(s) and s != "" -> s
      _ -> fail(404, msg)
    end
  end

  defp parse_body(body) do
    :json.decode(body)
  rescue
    _ -> nil
  end

  defp wrapper!(body, key) do
    case parse_body(body) do
      %{^key => %{} = obj} -> obj
      %{} -> fail(422, "#{key} is required")
      _ -> fail(422, "invalid JSON body")
    end
  end

  defp clean?(s), do: :binary.match(s, <<0>>) == :nomatch and String.valid?(s)

  defp req_str!(obj, key, msg) do
    case Map.get(obj, key) do
      s when is_binary(s) and s != "" -> if clean?(s), do: s, else: fail(422, msg)
      _ -> fail(422, msg)
    end
  end

  # Absent or null: unchanged. A string must be non-empty when `nonempty`. Any other type is invalid.
  defp opt_str!(obj, key, nonempty, msg) do
    case Map.get(obj, key) do
      nil ->
        nil

      :null ->
        nil

      s when is_binary(s) and (s != "" or not nonempty) ->
        if clean?(s), do: s, else: fail(422, msg)

      _ ->
        fail(422, msg)
    end
  end

  # ------------------------------------------------------------------ response writers

  defp profile(username, bio, image, following) do
    [
      "{\"username\":",
      Json.str(username),
      ",\"bio\":",
      Json.opt_str(bio),
      ",\"image\":",
      Json.opt_str(image),
      ",\"following\":",
      Json.bool(following),
      "}"
    ]
  end

  # [id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following]
  defp list_article([
         _id,
         slug,
         title,
         description,
         created,
         updated,
         tags,
         favc,
         favd,
         username,
         bio,
         image,
         following
       ]) do
    [
      "{\"slug\":",
      Json.str(slug),
      ",\"title\":",
      Json.str(title),
      ",\"description\":",
      Json.str(description),
      article_tail(tags, created, updated, favd, favc, username, bio, image, following)
    ]
  end

  # The same columns with `body` after `description`.
  defp full_article([
         _id,
         slug,
         title,
         description,
         body,
         created,
         updated,
         tags,
         favc,
         favd,
         username,
         bio,
         image,
         following
       ]) do
    [
      "{\"slug\":",
      Json.str(slug),
      ",\"title\":",
      Json.str(title),
      ",\"description\":",
      Json.str(description),
      ",\"body\":",
      Json.str(body),
      article_tail(tags, created, updated, favd, favc, username, bio, image, following)
    ]
  end

  defp article_tail(tags, created, updated, favd, favc, username, bio, image, following) do
    [
      ",\"tagList\":[",
      tags |> Enum.map(&Json.str/1) |> Enum.intersperse(?,),
      "],\"createdAt\":",
      Json.ts(created),
      ",\"updatedAt\":",
      Json.ts(updated),
      ",\"favorited\":",
      Json.bool(favd),
      ",\"favoritesCount\":",
      Json.int(favc),
      ",\"author\":",
      profile(username, bio, image, following),
      "}"
    ]
  end

  defp comment(id, body, created, updated, username, bio, image, following) do
    [
      "{\"id\":",
      Json.int(id),
      ",\"createdAt\":",
      Json.ts(created),
      ",\"updatedAt\":",
      Json.ts(updated),
      ",\"body\":",
      Json.str(body),
      ",\"author\":",
      profile(username, bio, image, following),
      "}"
    ]
  end

  defp user_json(email, token, username, bio, image) do
    [
      "{\"user\":{\"email\":",
      Json.str(email),
      ",\"token\":",
      Json.str(token),
      ",\"username\":",
      Json.str(username),
      ",\"bio\":",
      Json.opt_str(bio),
      ",\"image\":",
      Json.opt_str(image),
      "}}"
    ]
  end
end
