(* PostgreSQL through libpq (postgresql-ocaml) in non-blocking mode. A query waits on the connection's socket with
   Eio, so it suspends only its own fiber. Statements are prepared once per connection; results are binary. *)
module P = Postgresql

exception Error of { code : string; message : string }

type stmt = { id : int; name : string; sql : string }

let stmt_count = ref 0

let stmt sql =
  incr stmt_count;
  { id = !stmt_count; name = "s" ^ string_of_int !stmt_count; sql }

type conn = {
  c : P.connection;
  fd : Unix.file_descr;
  prepared : Bytes.t; (* one flag per stmt id *)
  mutable busy : bool; (* a query is in flight: an exception here leaves the connection unusable *)
  mutable alive : bool;
}

(* libpq understands the postgres:// URL itself. This blocks the calling domain, which is fine at startup and
   acceptable for the rare reconnect. *)
let connect url =
  let c = new P.connection ~conninfo:url () in
  (* Plan each statement once, for the connection's lifetime. Every statement is a short index walk, so neither
     JIT compilation nor parallel workers can pay for themselves. *)
  ignore
    (c#exec ~expect:[ P.Command_ok ]
       "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0");
  c#set_nonblocking true;
  { c; fd = c#socket_descr; prepared = Bytes.make (!stmt_count + 1) '\000'; busy = false; alive = true }

let rec flush conn =
  match conn.c#flush with
  | P.Successful -> ()
  | P.Data_left_to_send ->
      Eio_unix.await_writable conn.fd;
      flush conn

type row = string option array

let rows_of (res : P.result) : row list =
  let fields = res#nfields in
  let rec go t acc =
    if t < 0 then acc
    else
      go (t - 1)
        (Array.init fields (fun f -> if res#getisnull t f then None else Some (res#getvalue t f)) :: acc)
  in
  go (res#ntuples - 1) []

(* Reads results until the query is finished. Errors are raised only then, leaving the connection ready. *)
let collect conn =
  let rows = ref [] and err = ref None in
  let rec loop () =
    if conn.c#is_busy then begin
      Eio_unix.await_readable conn.fd;
      conn.c#consume_input;
      loop ()
    end
    else
      match conn.c#get_result with
      | None -> ()
      | Some res ->
          (match res#status with
          | P.Tuples_ok -> rows := rows_of res
          | P.Fatal_error | P.Bad_response | P.Nonfatal_error ->
              if !err = None then
                err := Some (Error { code = res#error_field P.Error_field.SQLSTATE; message = res#error })
          | _ -> ());
          loop ()
  in
  loop ();
  (!rows, !err)

let finish conn =
  match collect conn with
  | rows, None ->
      conn.busy <- false;
      rows
  | _, Some e ->
      conn.busy <- false;
      raise e

let exec conn st (params : string option array) : row list =
  Stats.pg @@ fun () ->
  conn.busy <- true;
  if Bytes.get conn.prepared st.id = '\000' then begin
    conn.c#send_prepare st.name st.sql;
    flush conn;
    ignore (finish conn);
    conn.busy <- true;
    Bytes.set conn.prepared st.id '\001'
  end;
  let params = Array.map (function Some v -> v | None -> P.null) params in
  conn.c#send_query_prepared ~params ~binary_result:true st.name;
  flush conn;
  finish conn

let exec_one conn st params = match exec conn st params with r :: _ -> Some r | [] -> None

(* ---------- pool ---------- *)

(* Each domain has its own pool, so a connection's socket is always awaited by the ring of the domain using it. *)
type pool = { q : conn Eio.Stream.t; url : string }

let create_pool ~size url =
  let q = Eio.Stream.create size in
  for _ = 1 to size do
    Eio.Stream.add q (connect url)
  done;
  { q; url }

let discard conn =
  conn.alive <- false;
  try conn.c#finish with _ -> ()

let with_conn p f =
  let conn = Stats.pool_take (fun () -> Eio.Stream.take p.q) in
  let conn =
    if conn.alive then conn
    else
      match connect p.url with
      | fresh -> fresh
      | exception e ->
          Eio.Stream.add p.q conn;
          raise e
  in
  match f conn with
  | v ->
      Eio.Stream.add p.q conn;
      v
  | exception e ->
      if conn.busy then discard conn;
      Eio.Stream.add p.q conn;
      raise e

let begin_ = stmt "BEGIN"
let commit = stmt "COMMIT"
let rollback = stmt "ROLLBACK"

let with_tx conn f =
  ignore (exec conn begin_ [||]);
  match f () with
  | v ->
      ignore (exec conn commit [||]);
      v
  | exception e ->
      if not conn.busy then ignore (exec conn rollback [||]);
      raise e

(* ---------- binary result decoding ---------- *)

let get (r : row) i = match r.(i) with Some s -> s | None -> failwith "postgres: unexpected NULL"
let int r i = Int64.to_int (String.get_int64_be (get r i) 0)
let bool r i = (get r i).[0] <> '\000'
let timestamp r i = String.get_int64_be (get r i) 0
let int4 r i = Int32.to_int (String.get_int32_be (get r i) 0)

(* A one-dimensional bigint[]; an empty array has zero dimensions. *)
let int_array r i =
  let s = get r i in
  if String.get_int32_be s 0 = 0l then [||]
  else Array.init (Int32.to_int (String.get_int32_be s 12)) (fun k -> Int64.to_int (String.get_int64_be s (24 + (k * 12))))

(* A one-dimensional text[]; an empty array has zero dimensions. *)
let text_array r i =
  let s = get r i in
  if String.get_int32_be s 0 = 0l then []
  else begin
    let n = Int32.to_int (String.get_int32_be s 12) in
    let pos = ref 20 in
    List.init n (fun _ ->
        let len = Int32.to_int (String.get_int32_be s !pos) in
        let v = String.sub s (!pos + 4) len in
        pos := !pos + 4 + len;
        v)
  end

(* The text form of a text[] parameter. *)
let text_array_literal items =
  let b = Buffer.create 64 in
  Buffer.add_char b '{';
  List.iteri
    (fun i s ->
      if i > 0 then Buffer.add_char b ',';
      Buffer.add_char b '"';
      String.iter
        (fun ch ->
          if ch = '"' || ch = '\\' then Buffer.add_char b '\\';
          Buffer.add_char b ch)
        s;
      Buffer.add_char b '"')
    items;
  Buffer.add_char b '}';
  Buffer.contents b
