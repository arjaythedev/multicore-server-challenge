(* A minimal HTTP/1.1 server loop: one fiber per connection, keep-alive, Content-Length bodies. *)
type request = {
  meth : string;
  path : string; (* still percent-encoded *)
  query : string;
  authorization : string option;
  body : string;
}

type response = { status : int; body : string (* "" with 204 *) }

let max_request = 8 * 1024 * 1024

let reason = function
  | 200 -> "OK"
  | 201 -> "Created"
  | 204 -> "No Content"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 413 -> "Content Too Large"
  | 422 -> "Unprocessable Content"
  | _ -> "Internal Server Error"

let head status len ~close =
  let conn = if close then "Connection: close\r\n" else "" in
  if status = 204 then "HTTP/1.1 204 No Content\r\n" ^ conn ^ "\r\n"
  else
    String.concat ""
      [
        "HTTP/1.1 ";
        string_of_int status;
        " ";
        reason status;
        "\r\nContent-Type: application/json\r\nContent-Length: ";
        string_of_int len;
        "\r\n";
        conn;
        "\r\n";
      ]

let rec find_end s i =
  match String.index_from_opt s i '\r' with
  | Some j when j + 3 < String.length s ->
      if s.[j + 1] = '\n' && s.[j + 2] = '\r' && s.[j + 3] = '\n' then Some j else find_end s (j + 1)
  | _ -> None

let trim_at s i j =
  let i = ref i and j = ref j in
  while !i < !j && (s.[!i] = ' ' || s.[!i] = '\t') do incr i done;
  while !j > !i && (s.[!j - 1] = ' ' || s.[!j - 1] = '\t') do decr j done;
  String.sub s !i (!j - !i)

type parsed = {
  p_meth : string;
  p_target : string;
  p_auth : string option;
  p_len : int;
  p_close : bool;
  p_chunked : bool;
}

exception Bad_request

(* Parses the head that ends at [stop] (the final CRLFCRLF). *)
let parse_head s stop =
  let line_end = match String.index_from_opt s 0 '\r' with Some e -> e | None -> raise Bad_request in
  let sp1 = match String.index_opt s ' ' with Some i when i < line_end -> i | _ -> raise Bad_request in
  let sp2 = match String.index_from_opt s (sp1 + 1) ' ' with Some i when i < line_end -> i | _ -> raise Bad_request in
  let http10 = line_end - sp2 - 1 = 8 && s.[line_end - 1] = '0' in
  let auth = ref None and len = ref 0 and close = ref http10 and chunked = ref false in
  let pos = ref (line_end + 2) in
  while !pos < stop do
    let e = match String.index_from_opt s !pos '\r' with Some e when e <= stop -> e | _ -> stop in
    (match String.index_from_opt s !pos ':' with
    | Some c when c < e -> (
        let name_len = c - !pos in
        (* only the headers we use pay for lowercasing *)
        match name_len with
        | 13 | 14 | 10 | 17 -> (
            match String.lowercase_ascii (String.sub s !pos name_len) with
            | "authorization" -> auth := Some (trim_at s (c + 1) e)
            | "content-length" -> (
                let v = trim_at s (c + 1) e in
                if v = "" || not (String.for_all (fun ch -> ch >= '0' && ch <= '9') v) then raise Bad_request;
                match int_of_string_opt v with Some n -> len := n | None -> raise Bad_request)
            | "connection" -> (
                match String.lowercase_ascii (trim_at s (c + 1) e) with
                | "close" -> close := true
                | "keep-alive" -> close := false
                | _ -> ())
            | "transfer-encoding" -> chunked := true
            | _ -> ())
        | _ -> ())
    | _ -> ());
    pos := e + 2
  done;
  {
    p_meth = String.sub s 0 sp1;
    p_target = String.sub s (sp1 + 1) (sp2 - sp1 - 1);
    p_auth = !auth;
    p_len = !len;
    p_close = !close;
    p_chunked = !chunked;
  }

let serve flow handler =
  let rbuf = Cstruct.create 2048 in
  let read () =
    let n = Eio.Flow.single_read flow rbuf in
    Cstruct.to_string ~len:n rbuf
  in
  let reject status =
    let body = {|{"errors":{"body":["bad request"]}}|} in
    Wbuf.write flow (head status (String.length body) ~close:true) body
  in
  let rec next pending =
    match find_end pending 0 with
    | None ->
        if String.length pending > 65536 then reject 400
        else
          let more = read () in
          next (if pending = "" then more else pending ^ more)
    | Some stop -> (
        match parse_head pending stop with
        | exception Bad_request -> reject 400
        | p when p.p_chunked -> reject 400
        | p when p.p_len > max_request -> reject 413
        | p ->
            let start = stop + 4 in
            let total = start + p.p_len in
            let rec fill s = if String.length s >= total then s else fill (s ^ read ()) in
            let s = fill pending in
            let path, query =
              match String.index_opt p.p_target '?' with
              | Some q ->
                  ( String.sub p.p_target 0 q,
                    String.sub p.p_target (q + 1) (String.length p.p_target - q - 1) )
              | None -> (p.p_target, "")
            in
            let body = if p.p_len = 0 then "" else String.sub s start p.p_len in
            let r : response =
              Stats.handler
                (fun (r : response) -> r.status)
                (fun () -> handler { meth = p.p_meth; path; query; authorization = p.p_auth; body })
            in
            Wbuf.write flow (head r.status (String.length r.body) ~close:p.p_close) r.body;
            if not p.p_close then
              next (if String.length s = total then "" else String.sub s total (String.length s - total)))
  in
  Stats.connection (fun () -> try next "" with End_of_file | Eio.Io _ -> ())

let pct_value = function
  | '0' .. '9' as c -> Char.code c - 48
  | 'a' .. 'f' as c -> Char.code c - 87
  | 'A' .. 'F' as c -> Char.code c - 55
  | _ -> -1

(* Invalid escapes are kept literally. *)
let decode ~plus s =
  if not (String.contains s '%' || (plus && String.contains s '+')) then s
  else begin
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      let c = s.[!i] in
      if c = '%' && !i + 2 < n && pct_value s.[!i + 1] >= 0 && pct_value s.[!i + 2] >= 0 then begin
        Buffer.add_char b (Char.chr ((pct_value s.[!i + 1] * 16) + pct_value s.[!i + 2]));
        i := !i + 3
      end
      else begin
        Buffer.add_char b (if plus && c = '+' then ' ' else c);
        incr i
      end
    done;
    Buffer.contents b
  end

(* Decoded (key, value) pairs in order. *)
let query_params q =
  if q = "" then []
  else
    String.split_on_char '&' q
    |> List.filter (( <> ) "")
    |> List.map (fun kv ->
           match String.index_opt kv '=' with
           | Some i ->
               ( decode ~plus:true (String.sub kv 0 i),
                 decode ~plus:true (String.sub kv (i + 1) (String.length kv - i - 1)) )
           | None -> (decode ~plus:true kv, ""))
