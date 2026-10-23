defmodule Conduit.Handler do
  @moduledoc """
  The 19 endpoints. Each returns `{status, iodata}`. Reads go through the batching dispatcher (`DB.read`), writes
  through a write connection (`DB.write`); responses are built directly from the binary rows.
  """
  alias Conduit.{Bcrypt, DB, JWT}
  alias Conduit.JSON, as: J
  alias Conduit.PG.Proto, as: P

  @max_i8 9_223_372_036_854_775_807

  def handle(method, target, auth, body) do
    {path, query} =
      case :binary.split(target, "?") do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    route(method, :binary.split(path, "/", [:global]), query, auth, body)
  rescue
    e ->
      IO.puts(:stderr, "handler crash: " <> Exception.format(:error, e, __STACKTRACE__))
      {500, error_body("internal error")}
  end

  # ---------- routing ----------

  defp route("GET", ["", "api", "tags"], _, _, _), do: tags()
  defp route("POST", ["", "api", "users", "login"], _, _, body), do: login(body)
  defp route("POST", ["", "api", "users"], _, _, body), do: register(body)
  defp route("GET", ["", "api", "user"], _, auth, _), do: required(auth, &get_user(&1, &2))
  defp route("PUT", ["", "api", "user"], _, auth, body), do: required(auth, &put_user(&1, &2, body))
  defp route("GET", ["", "api", "profiles", u], _, auth, _), do: optional(auth, &profile(&1, seg(u)))

  defp route("POST", ["", "api", "profiles", u, "follow"], _, auth, _),
    do: required(auth, fn v, _ -> follow(v, seg(u), true) end)

  defp route("DELETE", ["", "api", "profiles", u, "follow"], _, auth, _),
    do: required(auth, fn v, _ -> follow(v, seg(u), false) end)

  defp route("GET", ["", "api", "articles"], q, auth, _), do: optional(auth, &list(&1, q))
  defp route("GET", ["", "api", "articles", "feed"], q, auth, _), do: required(auth, fn v, _ -> feed(v, q) end)
  defp route("POST", ["", "api", "articles"], _, auth, body), do: required(auth, fn v, _ -> create_article(v, body) end)
  defp route("GET", ["", "api", "articles", s], _, auth, _), do: optional(auth, &get_article(&1, seg(s)))

  defp route("PUT", ["", "api", "articles", s], _, auth, body),
    do: required(auth, fn v, _ -> update_article(v, seg(s), body) end)

  defp route("DELETE", ["", "api", "articles", s], _, auth, _),
    do: required(auth, fn v, _ -> delete_article(v, seg(s)) end)

  defp route("POST", ["", "api", "articles", s, "favorite"], _, auth, _),
    do: required(auth, fn v, _ -> favorite(v, seg(s), true) end)

  defp route("DELETE", ["", "api", "articles", s, "favorite"], _, auth, _),
    do: required(auth, fn v, _ -> favorite(v, seg(s), false) end)

  defp route("GET", ["", "api", "articles", s, "comments"], _, auth, _), do: optional(auth, &comments(&1, seg(s)))

  defp route("POST", ["", "api", "articles", s, "comments"], _, auth, body),
    do: required(auth, fn v, _ -> add_comment(v, seg(s), body) end)

  defp route("DELETE", ["", "api", "articles", s, "comments", id], _, auth, _),
    do: required(auth, fn v, _ -> delete_comment(v, seg(s), id) end)

  defp route(_, _, _, _, _), do: err(404, "not found")

  # percent-decoded path segment
  defp seg(s) do
    if :binary.match(s, "%") == :nomatch do
      s
    else
      try do
        URI.decode(s)
      rescue
        _ -> s
      end
    end
  end

  # ---------- auth ----------

  # Auth required: a valid token or 401. The callback gets (viewer id, token).
  defp required(nil, _), do: err(401, "missing token")

  defp required("Token " <> token, fun) do
    case JWT.verify(token) do
      {:ok, id} -> fun.(id, token)
      :error -> err(401, "invalid token")
    end
  end

  defp required(_, _), do: err(401, "invalid authorization header")

  # Auth optional: no header = anonymous (viewer 0); a header that is present but invalid = 401.
  defp optional(nil, fun), do: fun.(0)

  defp optional(auth, fun) do
    case auth do
      "Token " <> token ->
        case JWT.verify(token) do
          {:ok, id} -> fun.(id)
          :error -> err(401, "invalid token")
        end

      _ ->
        err(401, "invalid authorization header")
    end
  end

  # ---------- users ----------

  defp register(body) do
    with {:ok, %{"user" => %{} = u}} <- json(body),
         {:ok, username} <- nonempty(u, "username"),
         {:ok, email} <- nonempty(u, "email"),
         {:ok, password} <- nonempty(u, "password"),
         true <- byte_size(password) <= 72 do
      {:ok, hash} = Bcrypt.hash(password)

      case DB.write([{:user_insert, [username, email, hash]}]) do
        {:ok, [row]} ->
          {id, r} = P.int8(row)
          {201, user_json(r, JWT.sign(id))}

        {:error, %{code: "23505"}} ->
          err(422, "username or email already taken")

        {:error, e} ->
          db_error(e)
      end
    else
      _ -> err(422, "user needs non-empty username, email and password (at most 72 bytes)")
    end
  end

  defp login(body) do
    with {:ok, %{"user" => %{} = u}} <- json(body),
         {:ok, email} <- nonempty(u, "email"),
         {:ok, password} <- nonempty(u, "password") do
      case DB.read(:login, email) do
        {:ok, [row]} ->
          {id, r} = P.int8(row)
          {un, r} = P.text(r)
          {em, r} = P.text(r)
          {bio, r} = P.text(r)
          {img, r} = P.text(r)
          {hash, _} = P.text(r)

          if Bcrypt.verify(password, hash) do
            {200, user_obj(em, JWT.sign(id), un, bio, img)}
          else
            err(401, "invalid email or password")
          end

        {:ok, []} ->
          err(401, "invalid email or password")

        {:error, e} ->
          db_error(e)
      end
    else
      _ -> err(422, "user needs non-empty email and password")
    end
  end

  defp get_user(id, token) do
    case DB.read(:user, id) do
      {:ok, [row]} ->
        {un, r} = P.text(row)
        {em, r} = P.text(r)
        {bio, r} = P.text(r)
        {img, _} = P.text(r)
        {200, user_obj(em, token, un, bio, img)}

      {:ok, []} ->
        err(401, "unknown user")

      {:error, e} ->
        db_error(e)
    end
  end

  defp put_user(id, token, body) do
    with {:ok, %{"user" => %{} = u}} <- json(body),
         {:ok, email} <- opt_nonempty(u, "email"),
         {:ok, username} <- opt_nonempty(u, "username"),
         {:ok, password} <- opt_nonempty(u, "password"),
         {:ok, bio} <- opt_string(u, "bio"),
         {:ok, image} <- opt_string(u, "image"),
         true <- password == nil or byte_size(password) <= 72 do
      hash =
        if password do
          {:ok, h} = Bcrypt.hash(password)
          h
        end

      case DB.write([{:user_update, [P.enc_int8(id), email, username, hash, bio, image]}]) do
        {:ok, [row]} ->
          {_id, r} = P.int8(row)
          {200, user_json(r, token)}

        {:ok, []} ->
          err(401, "unknown user")

        {:error, %{code: "23505"}} ->
          err(422, "username or email already taken")

        {:error, e} ->
          db_error(e)
      end
    else
      _ -> err(422, "invalid user update")
    end
  end

  # row: username, email, bio, image
  defp user_json(r, token) do
    {un, r} = P.text(r)
    {em, r} = P.text(r)
    {bio, r} = P.text(r)
    {img, _} = P.text(r)
    user_obj(em, token, un, bio, img)
  end

  defp user_obj(email, token, username, bio, image) do
    [
      "{\"user\":{\"email\":",
      J.str(email),
      ",\"token\":\"",
      token,
      "\",\"username\":",
      J.str(username),
      ",\"bio\":",
      J.str(bio),
      ",\"image\":",
      J.str(image),
      "}}"
    ]
  end

  # ---------- profiles ----------

  defp profile(viewer, username) do
    case DB.read(:profile, {viewer, username}) do
      {:ok, [row]} -> {200, profile_json(row, nil)}
      {:ok, []} -> err(404, "profile not found")
      {:error, e} -> db_error(e)
    end
  end

  defp follow(viewer, username, on) do
    stmt = if on, do: :follow, else: :unfollow

    case DB.write([{stmt, [P.enc_int8(viewer), username]}]) do
      {:ok, [row]} -> {200, profile_json(row, on)}
      {:ok, []} -> err(404, "profile not found")
      {:error, e} -> db_error(e)
    end
  end

  # row: username, bio, image[, following]
  defp profile_json(row, following) do
    {un, r} = P.text(row)
    {bio, r} = P.text(r)
    {img, r} = P.text(r)
    following = if following == nil, do: elem(P.bool(r), 0), else: following

    [
      "{\"profile\":{\"username\":",
      J.str(un),
      ",\"bio\":",
      J.str(bio),
      ",\"image\":",
      J.str(img),
      ",\"following\":",
      J.bool(following),
      "}}"
    ]
  end

  # ---------- article lists ----------

  defp list(viewer, query) do
    with {:ok, params} <- query_params(query),
         {:ok, limit, offset} <- paging(params) do
      {kind, key} =
        cond do
          nonempty_param(params, "tag") -> {:list_tag, params["tag"]}
          nonempty_param(params, "author") -> {:list_author, params["author"]}
          nonempty_param(params, "favorited") -> {:list_favorited, params["favorited"]}
          true -> {:list_all, nil}
        end

      args = if key, do: {viewer, limit, offset, key}, else: {viewer, limit, offset}
      list_response(DB.read(kind, args))
    else
      _ -> err(422, "limit must be 1-100 and offset >= 0")
    end
  end

  defp feed(viewer, query) do
    with {:ok, params} <- query_params(query),
         {:ok, limit, offset} <- paging(params) do
      list_response(DB.read(:list_feed, {viewer, limit, offset}))
    else
      _ -> err(422, "limit must be 1-100 and offset >= 0")
    end
  end

  # rows: count, then list article columns (all NULL on an empty page)
  defp list_response({:ok, [first | _] = rows}) do
    {count, _} = P.int8(first)
    # the count column is 12 bytes (length + int8); a NULL slug after it marks the empty page's row
    articles =
      for <<_::binary-size(12), len::32-signed, _::binary>> = row <- rows,
          len >= 0,
          do: article(binary_part(row, 12, byte_size(row) - 12), false)

    {200, ["{\"articles\":", J.array(articles), ",\"articlesCount\":", Integer.to_string(count), "}"]}
  end

  defp list_response({:ok, []}), do: {200, "{\"articles\":[],\"articlesCount\":0}"}
  defp list_response({:error, e}), do: db_error(e)

  defp nonempty_param(params, k), do: Map.get(params, k, "") != ""

  defp paging(params) do
    with {:ok, limit} <- int_param(params, "limit", 20),
         {:ok, offset} <- int_param(params, "offset", 0),
         true <- limit >= 1 and limit <= 100 do
      {:ok, limit, offset}
    else
      _ -> :error
    end
  end

  defp int_param(params, key, default) do
    case params do
      %{^key => v} ->
        if v != "" and byte_size(v) <= 19 and JWT.digits?(v) do
          n = String.to_integer(v)
          if n <= @max_i8, do: {:ok, n}, else: :error
        else
          :error
        end

      _ ->
        {:ok, default}
    end
  end

  # first occurrence of each key wins
  defp query_params(""), do: {:ok, %{}}

  defp query_params(q) do
    params =
      q
      |> :binary.split("&", [:global])
      |> Enum.reduce(%{}, fn pair, acc ->
        {k, v} =
          case :binary.split(pair, "=") do
            [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
            [k] -> {URI.decode_www_form(k), ""}
          end

        Map.put_new(acc, k, v)
      end)

    {:ok, params}
  rescue
    _ -> :error
  end

  # ---------- single article ----------

  defp get_article(viewer, slug) do
    case DB.read(:article, {viewer, slug}) do
      {:ok, [row]} -> {200, ["{\"article\":", article(row, true), "}"]}
      {:ok, []} -> err(404, "article not found")
      {:error, e} -> db_error(e)
    end
  end

  defp create_article(viewer, body) do
    with {:ok, %{"article" => %{} = a}} <- json(body),
         {:ok, title} <- nonempty(a, "title"),
         {:ok, description} <- nonempty(a, "description"),
         {:ok, text} <- nonempty(a, "body"),
         {:ok, tags} <- tag_list(Map.get(a, "tagList")) do
      params = [P.enc_int8(viewer), slugify(title) <> "-", title, description, text, P.array(:text, Enum.uniq(tags))]

      case DB.write([{:article_create, params}]) do
        {:ok, [row]} -> {201, ["{\"article\":", article(row, true), "}"]}
        {:error, e} -> db_error(e)
      end
    else
      _ -> err(422, "article needs non-empty title, description and body; tagList must be non-empty strings")
    end
  end

  defp tag_list(nil), do: {:ok, []}
  defp tag_list(:null), do: {:ok, []}

  defp tag_list(l) when is_list(l) do
    if Enum.all?(l, &(is_binary(&1) and &1 != "")), do: {:ok, l}, else: :error
  end

  defp tag_list(_), do: :error

  defp update_article(viewer, slug, body) do
    with {:ok, %{"article" => %{} = a}} <- json(body),
         {:ok, title} <- opt_nonempty(a, "title"),
         {:ok, description} <- opt_nonempty(a, "description"),
         {:ok, text} <- opt_nonempty(a, "body") do
      prefix = if title, do: slugify(title) <> "-"

      case DB.write([{:article_update, [P.enc_int8(viewer), slug, title, description, text, prefix]}]) do
        {:ok, [row]} ->
          {author, r} = P.int8(row)

          if author == viewer,
            do: {200, ["{\"article\":", article(r, true), "}"]},
            else: err(403, "not the author")

        {:ok, []} ->
          err(404, "article not found")

        {:error, e} ->
          db_error(e)
      end
    else
      _ -> err(422, "title, description and body must be non-empty strings when given")
    end
  end

  defp delete_article(viewer, slug) do
    case DB.write([{:article_delete, [slug, P.enc_int8(viewer)]}]) do
      {:ok, [row]} -> owner_only(row, viewer)
      {:ok, []} -> err(404, "article not found")
      {:error, e} -> db_error(e)
    end
  end

  defp owner_only(row, viewer) do
    case P.int8(row) do
      {^viewer, _} -> {204, ""}
      _ -> err(403, "not the author")
    end
  end

  defp favorite(viewer, slug, on) do
    v = P.enc_int8(viewer)
    stmt = if on, do: :fav_insert, else: :fav_delete

    case DB.write([{stmt, [v, slug]}, {:article_by_slug, [v, slug]}]) do
      {:ok, [row]} -> {200, ["{\"article\":", article(row, true), "}"]}
      {:ok, []} -> err(404, "article not found")
      {:error, e} -> db_error(e)
    end
  end

  # slug, title, description, [body], created_at, updated_at, tag_list, favorites_count, favorited,
  # username, bio, image, following
  defp article(row, with_body) do
    {slug, r} = P.text(row)
    {title, r} = P.text(r)
    {desc, r} = P.text(r)

    {body, r} =
      if with_body do
        {b, r} = P.text(r)
        {[",\"body\":", J.str(b)], r}
      else
        {[], r}
      end

    {ca, r} = P.ts(r)
    {ua, r} = P.ts(r)
    {tags, r} = P.text_array(r)
    {count, r} = P.int8(r)
    {fav, r} = P.bool(r)
    {un, r} = P.text(r)
    {bio, r} = P.text(r)
    {img, r} = P.text(r)
    {fol, _} = P.bool(r)

    # slugs are SLUGIFY output + "-" + id (or seeded the same way): [a-z0-9-] only, nothing to escape
    [
      "{\"slug\":\"",
      slug,
      "\",\"title\":",
      J.str(title),
      ",\"description\":",
      J.str(desc),
      body,
      ",\"tagList\":",
      J.str_list(sort_tags(tags)),
      ",\"createdAt\":",
      J.ts(ca),
      ",\"updatedAt\":",
      J.ts(ua),
      ",\"favorited\":",
      J.bool(fav),
      ",\"favoritesCount\":",
      Integer.to_string(count),
      ",\"author\":{\"username\":",
      J.str(un),
      ",\"bio\":",
      J.str(bio),
      ",\"image\":",
      J.str(img),
      ",\"following\":",
      J.bool(fol),
      "}}"
    ]
  end

  defp sort_tags(tags) do
    if :persistent_term.get(:conduit_app_sorts_tags), do: :lists.sort(tags), else: tags
  end

  # ---------- comments ----------

  # rows: comment id, body, created_at, updated_at, username, bio, image, following (all NULL: no comments)
  defp comments(viewer, slug) do
    case DB.read(:comments, {viewer, slug}) do
      {:ok, []} ->
        err(404, "article not found")

      {:ok, rows} ->
        list = for <<len::32-signed, _::binary>> = row <- rows, len >= 0, do: comment(row, nil)
        {200, ["{\"comments\":", J.array(list), "}"]}

      {:error, e} ->
        db_error(e)
    end
  end

  defp add_comment(viewer, slug, body) do
    with {:ok, %{"comment" => %{} = c}} <- json(body),
         {:ok, text} <- nonempty(c, "body") do
      case DB.write([{:comment_create, [slug, P.enc_int8(viewer), text]}]) do
        {:ok, [row]} -> {201, ["{\"comment\":", comment(row, false), "}"]}
        {:ok, []} -> err(404, "article not found")
        {:error, e} -> db_error(e)
      end
    else
      _ -> err(422, "comment needs a non-empty body")
    end
  end

  defp delete_comment(viewer, slug, id) do
    with true <- id != "" and byte_size(id) <= 19 and JWT.digits?(id),
         n when n <= @max_i8 <- String.to_integer(id) do
      case DB.write([{:comment_delete, [P.enc_int8(n), slug, P.enc_int8(viewer)]}]) do
        {:ok, [row]} -> owner_only(row, viewer)
        {:ok, []} -> err(404, "comment not found")
        {:error, e} -> db_error(e)
      end
    else
      _ -> err(404, "comment not found")
    end
  end

  defp comment(row, following) do
    {id, r} = P.int8(row)
    {body, r} = P.text(r)
    {ca, r} = P.ts(r)
    {ua, r} = P.ts(r)
    {un, r} = P.text(r)
    {bio, r} = P.text(r)
    {img, r} = P.text(r)
    following = if following == nil, do: elem(P.bool(r), 0), else: following

    [
      "{\"id\":",
      Integer.to_string(id),
      ",\"createdAt\":",
      J.ts(ca),
      ",\"updatedAt\":",
      J.ts(ua),
      ",\"body\":",
      J.str(body),
      ",\"author\":{\"username\":",
      J.str(un),
      ",\"bio\":",
      J.str(bio),
      ",\"image\":",
      J.str(img),
      ",\"following\":",
      J.bool(following),
      "}}"
    ]
  end

  # ---------- tags ----------

  defp tags do
    case DB.read(:tags, nil) do
      {:ok, [row]} ->
        {literal, _} = P.text(row)
        {200, ["{\"tags\":", J.pg_array_to_json(literal), "}"]}

      {:error, e} ->
        db_error(e)
    end
  end

  # ---------- helpers ----------

  @doc "SLUGIFY(x) = trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g'))), byte for byte."
  def slugify(title), do: slug_bytes(title, [], false) |> :lists.reverse() |> IO.iodata_to_binary()

  defp slug_bytes(<<>>, acc, _sep), do: acc

  defp slug_bytes(<<c, rest::binary>>, acc, sep) when c in ?a..?z or c in ?0..?9,
    do: slug_bytes(rest, [c | sep_dash(acc, sep)], false)

  defp slug_bytes(<<c, rest::binary>>, acc, sep) when c in ?A..?Z,
    do: slug_bytes(rest, [c + 32 | sep_dash(acc, sep)], false)

  defp slug_bytes(<<_, rest::binary>>, acc, _sep), do: slug_bytes(rest, acc, true)

  # a run of other characters becomes one '-', except at the start (trimmed) and the end (never emitted)
  defp sep_dash([], _), do: []
  defp sep_dash(acc, true), do: [?- | acc]
  defp sep_dash(acc, false), do: acc

  defp json(""), do: :error

  defp json(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> :error
  end

  defp nonempty(map, key) do
    case map do
      %{^key => v} when is_binary(v) and v != "" -> {:ok, v}
      _ -> :error
    end
  end

  # absent or null = unchanged (nil); otherwise a non-empty string
  defp opt_nonempty(map, key) do
    case map do
      %{^key => :null} -> {:ok, nil}
      %{^key => v} when is_binary(v) and v != "" -> {:ok, v}
      %{^key => _} -> :error
      _ -> {:ok, nil}
    end
  end

  defp opt_string(map, key) do
    case map do
      %{^key => :null} -> {:ok, nil}
      %{^key => v} when is_binary(v) -> {:ok, v}
      %{^key => _} -> :error
      _ -> {:ok, nil}
    end
  end

  def error_body(msg), do: ["{\"errors\":{\"body\":[", J.str(msg), "]}}"]
  defp err(status, msg), do: {status, error_body(msg)}

  defp db_error(%{code: "timeout"}), do: err(503, "database timeout")

  defp db_error(e) do
    IO.puts(:stderr, "database error: #{inspect(e)}")
    err(500, "database error")
  end
end
