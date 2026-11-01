(* Conduit (multicore server challenge) in OCaml 5: one Eio event loop per domain, each with its own
   SO_REUSEPORT listener and its own pipelined Postgres connections (a small wire-protocol client below). *)

module P = Eio.Promise

(* ---------- small helpers ---------- *)

let getenv k d = match Sys.getenv_opt k with Some v when v <> "" -> v | _ -> d

(* growable byte buffer with in-place int32 patching, for building Postgres messages *)
module W = struct
  type t = { mutable b : Bytes.t; mutable n : int }
  let create n = { b = Bytes.create n; n = 0 }
  let ensure w k =
    if w.n + k > Bytes.length w.b then begin
      let nb = Bytes.create (max (2 * Bytes.length w.b) (w.n + k)) in
      Bytes.blit w.b 0 nb 0 w.n; w.b <- nb
    end
  let char w c = ensure w 1; Bytes.unsafe_set w.b w.n c; w.n <- w.n + 1
  let i32 w v = ensure w 4; Bytes.set_int32_be w.b w.n (Int32.of_int v); w.n <- w.n + 4
  let i16 w v = ensure w 2; Bytes.set_int16_be w.b w.n v; w.n <- w.n + 2
  let str w s = let l = String.length s in ensure w l; Bytes.blit_string s 0 w.b w.n l; w.n <- w.n + l
  let cstr w s = str w s; char w '\000'
  let patch32 w at v = Bytes.set_int32_be w.b at (Int32.of_int v)
  (* message: type byte, length placeholder, body, then patch the length *)
  let msg w typ f = char w typ; let at = w.n in i32 w 0; f (); patch32 w at (w.n - at)
end

let b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
let b64url_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let b64_encode ?(url = false) s =
  let tbl = if url then b64url_chars else b64_chars in
  let n = String.length s in
  let b = Buffer.create ((n + 2) / 3 * 4) in
  let i = ref 0 in
  while !i + 2 < n do
    let v = (Char.code s.[!i] lsl 16) lor (Char.code s.[!i + 1] lsl 8) lor Char.code s.[!i + 2] in
    Buffer.add_char b tbl.[v lsr 18]; Buffer.add_char b tbl.[(v lsr 12) land 63];
    Buffer.add_char b tbl.[(v lsr 6) land 63]; Buffer.add_char b tbl.[v land 63];
    i := !i + 3
  done;
  (match n - !i with
   | 1 ->
     let v = Char.code s.[!i] lsl 16 in
     Buffer.add_char b tbl.[v lsr 18]; Buffer.add_char b tbl.[(v lsr 12) land 63];
     if not url then Buffer.add_string b "=="
   | 2 ->
     let v = (Char.code s.[!i] lsl 16) lor (Char.code s.[!i + 1] lsl 8) in
     Buffer.add_char b tbl.[v lsr 18]; Buffer.add_char b tbl.[(v lsr 12) land 63];
     Buffer.add_char b tbl.[(v lsr 6) land 63];
     if not url then Buffer.add_char b '='
   | _ -> ());
  Buffer.contents b

let b64_val c =
  match c with
  | 'A' .. 'Z' -> Char.code c - 65 | 'a' .. 'z' -> Char.code c - 71 | '0' .. '9' -> Char.code c + 4
  | '+' | '-' -> 62 | '/' | '_' -> 63 | _ -> -1

(* decodes standard or url-safe base64, padding optional; None on bad input *)
let b64_decode s =
  let s = match String.index_opt s '=' with Some i -> String.sub s 0 i | None -> s in
  let n = String.length s in
  if n mod 4 = 1 then None
  else begin
    let b = Buffer.create (n * 3 / 4) in
    let acc = ref 0 and bits = ref 0 and ok = ref true in
    String.iter (fun c ->
        let v = b64_val c in
        if v < 0 then ok := false
        else begin
          acc := ((!acc lsl 6) lor v) land 0xFFFFFF; bits := !bits + 6;
          if !bits >= 8 then begin
            bits := !bits - 8; Buffer.add_char b (Char.chr ((!acc lsr !bits) land 255))
          end
        end) s;
    if !ok then Some (Buffer.contents b) else None
  end

let hmac key msg = Digestif.SHA256.(to_raw_string (hmac_string ~key msg))

(* ---------- bcrypt (libxcrypt, runtime released) ---------- *)

external bcrypt_verify_raw : string -> string -> bool = "mc_bcrypt_verify"
external bcrypt_hash_raw : string -> int -> string = "mc_bcrypt_hash"
(* the interleaved core: hasher threads take up to 5 waiting hashes at a time and run them in lockstep, after
   waiting BCRYPT_WAIT_MS for company when fewer are queued (logins are ~0.1% of requests). Every hash is full
   bcrypt at cost 10, and every login is checked against its stored hash. *)
module Bc = struct
  external hash_n : string array -> string array -> string array = "mc_bc_hash_n"
  external gensalt : unit -> string = "mc_bc_gensalt"
  external cost : string -> int = "mc_bc_cost"
  type job = { pw : string; setting : string; t0 : float; u : (string, exn) result P.u }
  let lanes = 5
  let m = Mutex.create () and c = Condition.create () and q : job Queue.t = Queue.create ()
  let wait_s = float_of_string (getenv "BCRYPT_WAIT_MS" "100") /. 1000.
  (* a hasher starts when 5 hashes are queued, or when the oldest has waited wait_s *)
  let rec worker () =
    Mutex.lock m;
    while Queue.is_empty q do Condition.wait c m done;
    while Queue.length q > 0 && Queue.length q < lanes && Unix.gettimeofday () < (Queue.peek q).t0 +. wait_s do
      Mutex.unlock m; Thread.delay 0.002; Mutex.lock m
    done;
    let n = min lanes (Queue.length q) in
    let jobs = Array.init n (fun _ -> Queue.pop q) in
    Mutex.unlock m;
    if n > 0 then begin
      let out = try Ok (hash_n (Array.map (fun j -> j.pw) jobs) (Array.map (fun j -> j.setting) jobs)) with e -> Error e in
      Array.iteri (fun i j -> P.resolve j.u (match out with Ok o -> Ok o.(i) | Error e -> Error e)) jobs
    end;
    worker ()
  let started = ref false
  let start () =
    if not !started then begin
      started := true;
      for _ = 1 to int_of_string (getenv "BCRYPT_THREADS" "2") do ignore (Thread.create worker ()) done
    end
  let run pw setting =
    let p, u = P.create () in
    Mutex.lock m; Queue.push { pw; setting; t0 = Unix.gettimeofday (); u } q; Condition.signal c; Mutex.unlock m;
    match P.await p with Ok h -> h | Error e -> raise e
end

let bcrypt_verify pw h =
  if String.length h = 60 && Bc.cost h = 10 then Eqaf.equal (Bc.run pw h) h
  else Eio_unix.run_in_systhread ~label:"bcrypt" (fun () -> bcrypt_verify_raw pw h)
let bcrypt_hash pw = Bc.run pw (Bc.gensalt ())

(* ---------- Postgres wire client: extended protocol, pipelined, binary results ---------- *)

module Pg = struct
  (* a row keeps the DataRow payload and each column's offset/length (length -1 = NULL) *)
  type row = { data : string; off : int array; len : int array }

  exception Pg_error of string * string (* SQLSTATE, message *)

  type pending = {
    results : row list array; (* reversed per statement *)
    affected : int array;
    mutable idx : int;
    mutable err : (string * string) option;
    resolver : (unit, string * string) result P.u;
  }

  type conn = {
    flow : Eio.Flow.two_way_ty Eio.Resource.t;
    mutable out : W.t;
    mutable spare : W.t;
    mutable wake : unit P.u option;
    q : pending Queue.t;
  }

  let parse_row payload =
    let ncol = String.get_int16_be payload 0 in
    let off = Array.make ncol 0 and len = Array.make ncol 0 in
    let p = ref 2 in
    for i = 0 to ncol - 1 do
      let l = Int32.to_int (String.get_int32_be payload !p) in
      p := !p + 4; off.(i) <- !p; len.(i) <- l;
      if l > 0 then p := !p + l
    done;
    { data = payload; off; len }

  let is_null r i = r.len.(i) < 0
  let int r i =
    match r.len.(i) with
    | 8 -> Int64.to_int (String.get_int64_be r.data r.off.(i))
    | 4 -> Int32.to_int (String.get_int32_be r.data r.off.(i))
    | 2 -> String.get_int16_be r.data r.off.(i)
    | _ -> 0
  let bool r i = r.len.(i) = 1 && r.data.[r.off.(i)] <> '\000'
  let text r i = if r.len.(i) < 0 then "" else String.sub r.data r.off.(i) r.len.(i)

  let error_fields payload =
    let code = ref "" and msg = ref "" in
    let n = String.length payload in
    let p = ref 0 in
    while !p < n && payload.[!p] <> '\000' do
      let t = payload.[!p] in
      let e = try String.index_from payload (!p + 1) '\000' with Not_found -> n in
      let v = String.sub payload (!p + 1) (e - !p - 1) in
      if t = 'C' then code := v else if t = 'M' then msg := v;
      p := e + 1
    done;
    (!code, !msg)

  let read_msg r =
    let typ = Eio.Buf_read.any_char r in
    let len = Int32.to_int (String.get_int32_be (Eio.Buf_read.take 4 r) 0) in
    (typ, Eio.Buf_read.take (len - 4) r)

  let affected_of_tag s =
    (* "INSERT 0 1", "DELETE 3", "UPDATE 1", "SELECT 5" *)
    let s = match String.index_opt s '\000' with Some i -> String.sub s 0 i | None -> s in
    match String.rindex_opt s ' ' with
    | Some i -> (try int_of_string (String.sub s (i + 1) (String.length s - i - 1)) with _ -> 0)
    | None -> 0

  let reader c r =
    let rec loop () =
      let typ, payload = read_msg r in
      (match typ with
       | 'D' ->
         let p = Queue.peek c.q in
         if p.err = None then p.results.(p.idx) <- parse_row payload :: p.results.(p.idx)
       | 'C' -> let p = Queue.peek c.q in p.affected.(p.idx) <- affected_of_tag payload; p.idx <- p.idx + 1
       | 'I' -> let p = Queue.peek c.q in p.idx <- p.idx + 1
       | 'E' -> let p = Queue.peek c.q in if p.err = None then p.err <- Some (error_fields payload)
       | 'Z' ->
         let p = Queue.pop c.q in
         P.resolve p.resolver (match p.err with None -> Ok () | Some e -> Error e)
       | _ -> ());
      loop ()
    in
    loop ()

  let writer c =
    let cs = ref (Cstruct.create 65536) in
    let rec loop () =
      if c.out.W.n = 0 then begin
        let p, u = P.create () in
        c.wake <- Some u; P.await p
      end;
      let w = c.out in
      c.out <- c.spare; c.spare <- w;
      (* one copy into this connection's own off-heap buffer, no string per batch *)
      let n = w.W.n in
      if Cstruct.length !cs < n then cs := Cstruct.create (max n (2 * Cstruct.length !cs));
      Cstruct.blit_from_bytes w.W.b 0 !cs 0 n;
      w.W.n <- 0;
      if Bytes.length w.W.b > 1 lsl 20 then w.W.b <- Bytes.create 65536;
      Eio.Flow.write c.flow [ Cstruct.sub !cs 0 n ];
      loop ()
    in
    loop ()

  type param = string option

  (* statements, prepared on every connection as s0, s1, ... *)
  let stmts : string list ref = ref []
  let nstmts = ref 0
  let prepare sql = let i = !nstmts in incr nstmts; stmts := !stmts @ [ sql ]; i

  let add_exec w (stmt, (params : param array)) =
    W.msg w 'B' (fun () ->
        W.char w '\000'; W.cstr w ("s" ^ string_of_int stmt);
        W.i16 w 0; W.i16 w (Array.length params);
        Array.iter (function None -> W.i32 w (-1) | Some s -> W.i32 w (String.length s); W.str w s) params;
        W.i16 w 1; W.i16 w 1);
    W.msg w 'E' (fun () -> W.char w '\000'; W.i32 w 0)

  (* runs statements back to back, inside one implicit transaction (one Sync) *)
  let run c (batch : (int * param array) list) =
    let n = List.length batch in
    List.iter (add_exec c.out) batch;
    W.msg c.out 'S' (fun () -> ());
    let p, u = P.create () in
    let pend = { results = Array.make n []; affected = Array.make n 0; idx = 0; err = None; resolver = u } in
    Queue.push pend c.q;
    (match c.wake with Some w -> c.wake <- None; P.resolve w () | None -> ());
    match P.await p with
    | Ok () -> Array.map List.rev pend.results, pend.affected
    | Error (code, msg) -> raise (Pg_error (code, msg))

  let query c stmt params = (fst (run c [ (stmt, params) ])).(0)

  (* ---- connect + auth (trust, cleartext, md5, SCRAM-SHA-256) ---- *)

  type url = { user : string; pass : string; host : string; port : int; db : string }

  let pct_decode s =
    let b = Buffer.create (String.length s) in
    let i = ref 0 in
    while !i < String.length s do
      (if s.[!i] = '%' && !i + 2 < String.length s then begin
          Buffer.add_char b (Char.chr (int_of_string ("0x" ^ String.sub s (!i + 1) 2))); i := !i + 2
        end else Buffer.add_char b s.[!i]);
      incr i
    done;
    Buffer.contents b

  let parse_url u =
    let rest = match String.index_opt u '/' with
      | Some _ when String.length u > 2 ->
        let i = String.index u ':' in String.sub u (i + 3) (String.length u - i - 3)
      | _ -> u in
    let rest = match String.index_opt rest '?' with Some i -> String.sub rest 0 i | None -> rest in
    let auth, hostdb = match String.rindex_opt rest '@' with
      | Some i -> String.sub rest 0 i, String.sub rest (i + 1) (String.length rest - i - 1)
      | None -> "", rest in
    let user, pass = match String.index_opt auth ':' with
      | Some i -> String.sub auth 0 i, String.sub auth (i + 1) (String.length auth - i - 1)
      | None -> auth, "" in
    let hostport, db = match String.index_opt hostdb '/' with
      | Some i -> String.sub hostdb 0 i, String.sub hostdb (i + 1) (String.length hostdb - i - 1)
      | None -> hostdb, user in
    let host, port = match String.rindex_opt hostport ':' with
      | Some i -> String.sub hostport 0 i, int_of_string (String.sub hostport (i + 1) (String.length hostport - i - 1))
      | None -> hostport, 5432 in
    { user = pct_decode user; pass = pct_decode pass; host = (if host = "" then "127.0.0.1" else host); port; db = pct_decode db }

  let xor a b = String.init (String.length a) (fun i -> Char.chr (Char.code a.[i] lxor Char.code b.[i]))

  let send flow f = let w = W.create 256 in f w; Eio.Flow.copy_string (Bytes.sub_string w.W.b 0 w.W.n) flow

  let auth flow r url =
    let nonce = ref "" and first_bare = ref "" in
    let rec loop () =
      let typ, p = read_msg r in
      match typ with
      | 'R' ->
        (match Int32.to_int (String.get_int32_be p 0) with
         | 0 -> loop ()
         | 3 -> send flow (fun w -> W.msg w 'p' (fun () -> W.cstr w url.pass)); loop ()
         | 5 ->
           let salt = String.sub p 4 4 in
           let md5 s = Digestif.MD5.(to_hex (digest_string s)) in
           let h = "md5" ^ md5 (md5 (url.pass ^ url.user) ^ salt) in
           send flow (fun w -> W.msg w 'p' (fun () -> W.cstr w h)); loop ()
         | 10 ->
           let rnd = String.init 18 (fun _ -> Char.chr (Random.int 256)) in
           nonce := b64_encode rnd;
           first_bare := "n=,r=" ^ !nonce;
           let msg = "n,," ^ !first_bare in
           send flow (fun w -> W.msg w 'p' (fun () ->
               W.cstr w "SCRAM-SHA-256"; W.i32 w (String.length msg); W.str w msg));
           loop ()
         | 11 ->
           let server_first = String.sub p 4 (String.length p - 4) in
           let attr k = List.find_map (fun kv ->
               if String.length kv > 2 && kv.[0] = k && kv.[1] = '=' then Some (String.sub kv 2 (String.length kv - 2)) else None)
               (String.split_on_char ',' server_first) |> Option.get in
           let rnonce = attr 'r' and salt = Option.get (b64_decode (attr 's')) and iters = int_of_string (attr 'i') in
           let u = ref (hmac url.pass (salt ^ "\000\000\000\001")) in
           let salted = ref !u in
           for _ = 2 to iters do u := hmac url.pass !u; salted := xor !salted !u done;
           let client_key = hmac !salted "Client Key" in
           let stored = Digestif.SHA256.(to_raw_string (digest_string client_key)) in
           let without_proof = "c=biws,r=" ^ rnonce in
           let auth_msg = !first_bare ^ "," ^ server_first ^ "," ^ without_proof in
           let proof = xor client_key (hmac stored auth_msg) in
           let final = without_proof ^ ",p=" ^ b64_encode proof in
           send flow (fun w -> W.msg w 'p' (fun () -> W.str w final));
           loop ()
         | 12 -> loop ()
         | n -> failwith (Printf.sprintf "unsupported postgres auth %d" n))
      | 'E' -> let c, m = error_fields p in failwith ("postgres: " ^ c ^ " " ^ m)
      | 'Z' -> ()
      | _ -> loop ()
    in
    loop ()

  let connect ~sw net url =
    let addr =
      match Eio.Net.getaddrinfo_stream net url.host ~service:(string_of_int url.port) with
      | a :: _ -> a
      | [] -> failwith ("cannot resolve " ^ url.host) in
    let flow = (Eio.Net.connect ~sw net addr :> Eio.Flow.two_way_ty Eio.Resource.t) in
    (match Eio_unix.Resource.fd_opt flow with
     | Some fd -> Eio_unix.Fd.use_exn "nodelay" fd (fun u -> try Unix.setsockopt u Unix.TCP_NODELAY true with _ -> ())
     | None -> ());
    let r = Eio.Buf_read.of_flow ~initial_size:65536 ~max_size:(64 lsl 20) flow in
    let w = W.create 256 in
    let at = w.W.n in
    W.i32 w 0; W.i32 w 196608;
    W.cstr w "user"; W.cstr w url.user; W.cstr w "database"; W.cstr w url.db;
    W.cstr w "client_encoding"; W.cstr w "UTF8"; W.cstr w "application_name"; W.cstr w "conduit-ocaml";
    (* session planner settings, on our own connections only *)
    W.cstr w "plan_cache_mode"; W.cstr w "force_generic_plan"; W.cstr w "jit"; W.cstr w "off";
    W.cstr w "max_parallel_workers_per_gather"; W.cstr w "0";
    W.char w '\000'; W.patch32 w at w.W.n;
    Eio.Flow.copy_string (Bytes.sub_string w.W.b 0 w.W.n) flow;
    auth flow r url;
    (* prepare every statement *)
    let w = W.create 4096 in
    List.iteri (fun i sql ->
        W.msg w 'P' (fun () -> W.cstr w ("s" ^ string_of_int i); W.cstr w sql; W.i16 w 0)) !stmts;
    W.msg w 'S' (fun () -> ());
    Eio.Flow.copy_string (Bytes.sub_string w.W.b 0 w.W.n) flow;
    let rec wait_ready () =
      match read_msg r with
      | 'E', p -> let c, m = error_fields p in failwith ("prepare failed: " ^ c ^ " " ^ m)
      | 'Z', _ -> ()
      | _ -> wait_ready () in
    wait_ready ();
    let c = { flow; out = W.create 65536; spare = W.create 65536; wake = None; q = Queue.create () } in
    Eio.Fiber.fork_daemon ~sw (fun () -> reader c r);
    Eio.Fiber.fork_daemon ~sw (fun () -> writer c);
    c
end

(* ---------- SQL ---------- *)

let list_select full =
  "SELECT a.id, a.slug, a.title, a.description, " ^ (if full then "a.body, " else "")
  ^ "a.created_at, a.updated_at, \
     ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
     (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
     EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
     u.username, u.bio, u.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
     FROM articles a JOIN users u ON u.id = a.author_id "

let slugify x = Printf.sprintf "trim(both '-' from lower(regexp_replace(%s, '[^A-Za-z0-9]+', '-', 'g')))" x
let order_page = "ORDER BY a.id DESC LIMIT $2 OFFSET $3"

let q_insert_user = Pg.prepare "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"
let q_login = Pg.prepare "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
let q_user = Pg.prepare "SELECT id, username, email, bio, image FROM users WHERE id = $1"
let q_update_user = Pg.prepare
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
     password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
     WHERE id = $1 RETURNING id, username, email, bio, image"
let q_profile = Pg.prepare
    "SELECT u.id, u.username, u.bio, u.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
     FROM users u WHERE u.username = $2"
let q_follow = Pg.prepare "INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM users u WHERE u.username = $2 ON CONFLICT DO NOTHING"
let q_unfollow = Pg.prepare "DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2)"
let q_user_by_name = Pg.prepare "SELECT id, username, bio, image FROM users WHERE username = $1"

let q_list_all = Pg.prepare (list_select false ^ order_page)
let q_count_all = Pg.prepare "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"
let q_list_tag = Pg.prepare (list_select false
  ^ "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) \
     ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")
let q_count_tag = Pg.prepare "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
let q_list_author = Pg.prepare (list_select false ^ "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " ^ order_page)
let q_count_author = Pg.prepare "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
let q_list_fav = Pg.prepare (list_select false
  ^ "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) \
     ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")
let q_count_fav = Pg.prepare "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
let q_feed = Pg.prepare (list_select false
  ^ "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL \
     (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x \
     WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC")
let q_count_feed = Pg.prepare "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

let q_article_slug = Pg.prepare (list_select true ^ "WHERE a.slug = $2")
let q_article_id = Pg.prepare (list_select true ^ "WHERE a.id = $2")
let q_insert_article = Pg.prepare
    ("INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, " ^ slugify "$2"
     ^ " || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id")
let q_insert_tags = Pg.prepare "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
let q_insert_article_tags = Pg.prepare
    "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"
let q_article_owner = Pg.prepare "SELECT id, author_id FROM articles WHERE slug = $1"
let q_update_article = Pg.prepare
    ("UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), \
      slug = CASE WHEN $2::text IS NULL THEN slug ELSE " ^ slugify "$2" ^ " || '-' || id END, updated_at = now() WHERE id = $1")
let q_delete_article = Pg.prepare "DELETE FROM articles WHERE id = $1"
let q_fav = Pg.prepare "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING"
let q_unfav = Pg.prepare "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)"
let q_article_id_by_slug = Pg.prepare "SELECT id FROM articles WHERE slug = $1"
let q_comments = Pg.prepare
    "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
     FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = $2 \
     ORDER BY c.created_at DESC, c.id DESC LIMIT 100"
let q_insert_comment = Pg.prepare
    "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at, author_id) \
     SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"
let q_comment_owner = Pg.prepare
    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2"
let q_delete_comment = Pg.prepare "DELETE FROM comments WHERE id = $1"
let q_tags = Pg.prepare "SELECT name FROM tags ORDER BY name"

(* ---------- JSON output ---------- *)

let hex = "0123456789abcdef"

let esc_sub b s off len =
  Buffer.add_char b '"';
  let start = ref off in
  let flush i = if i > !start then Buffer.add_substring b s !start (i - !start) in
  for i = off to off + len - 1 do
    let c = String.unsafe_get s i in
    if c = '"' || c = '\\' || Char.code c < 0x20 then begin
      flush i;
      (match c with
       | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
       | '\n' -> Buffer.add_string b "\\n" | '\r' -> Buffer.add_string b "\\r" | '\t' -> Buffer.add_string b "\\t"
       | c -> Buffer.add_string b "\\u00"; Buffer.add_char b hex.[Char.code c lsr 4]; Buffer.add_char b hex.[Char.code c land 15]);
      start := i + 1
    end
  done;
  flush (off + len);
  Buffer.add_char b '"'

let jstr b s = esc_sub b s 0 (String.length s)
let jcol b (r : Pg.row) i = if r.len.(i) < 0 then Buffer.add_string b "null" else esc_sub b r.data r.off.(i) r.len.(i)
let jbool b v = Buffer.add_string b (if v then "true" else "false")

let pad2 b n = Buffer.add_char b (Char.chr (48 + n / 10)); Buffer.add_char b (Char.chr (48 + n mod 10))

(* binary timestamptz (microseconds since 2000-01-01 UTC) -> "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated *)
let jts b (r : Pg.row) i =
  let us = Int64.to_int (String.get_int64_be r.data r.off.(i)) in
  let fdiv a d = if a >= 0 then a / d else - ((- a + d - 1) / d) in
  let ms = fdiv us 1000 + 946684800000 in
  let secs = fdiv ms 1000 in
  let msr = ms - secs * 1000 in
  let days = fdiv secs 86400 in
  let sod = secs - days * 86400 in
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - era * 146097 in
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 in
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) in
  let mp = (5 * doy + 2) / 153 in
  let d = doy - (153 * mp + 2) / 5 + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = yoe + era * 400 + (if m <= 2 then 1 else 0) in
  Buffer.add_char b '"';
  Buffer.add_string b (string_of_int y); Buffer.add_char b '-'; pad2 b m; Buffer.add_char b '-'; pad2 b d;
  Buffer.add_char b 'T'; pad2 b (sod / 3600); Buffer.add_char b ':'; pad2 b (sod / 60 mod 60); Buffer.add_char b ':';
  pad2 b (sod mod 60); Buffer.add_char b '.';
  Buffer.add_char b (Char.chr (48 + msr / 100)); pad2 b (msr mod 100);
  Buffer.add_string b "Z\""

(* binary text[] -> JSON array of strings *)
let jtextarr b (r : Pg.row) i =
  Buffer.add_char b '[';
  if r.len.(i) > 0 then begin
    let s = r.data and o = r.off.(i) in
    let ndim = Int32.to_int (String.get_int32_be s o) in
    if ndim > 0 then begin
      let n = Int32.to_int (String.get_int32_be s (o + 12)) in
      let p = ref (o + 12 + 8 * ndim) in
      for k = 0 to n - 1 do
        let l = Int32.to_int (String.get_int32_be s !p) in
        p := !p + 4;
        if k > 0 then Buffer.add_char b ',';
        if l < 0 then Buffer.add_string b "null" else (esc_sub b s !p l; p := !p + l)
      done
    end
  end;
  Buffer.add_char b ']'

(* article row: id 0, slug 1, title 2, description 3, [body 4], then created, updated, tags, count, favorited,
   username, bio, image, following *)
let jarticle b full (r : Pg.row) =
  let k = if full then 1 else 0 in
  Buffer.add_string b "{\"slug\":"; jcol b r 1;
  Buffer.add_string b ",\"title\":"; jcol b r 2;
  Buffer.add_string b ",\"description\":"; jcol b r 3;
  if full then (Buffer.add_string b ",\"body\":"; jcol b r 4);
  Buffer.add_string b ",\"createdAt\":"; jts b r (4 + k);
  Buffer.add_string b ",\"updatedAt\":"; jts b r (5 + k);
  Buffer.add_string b ",\"tagList\":"; jtextarr b r (6 + k);
  Buffer.add_string b ",\"favoritesCount\":"; Buffer.add_string b (string_of_int (Pg.int r (7 + k)));
  Buffer.add_string b ",\"favorited\":"; jbool b (Pg.bool r (8 + k));
  Buffer.add_string b ",\"author\":{\"username\":"; jcol b r (9 + k);
  Buffer.add_string b ",\"bio\":"; jcol b r (10 + k);
  Buffer.add_string b ",\"image\":"; jcol b r (11 + k);
  Buffer.add_string b ",\"following\":"; jbool b (Pg.bool r (12 + k));
  Buffer.add_string b "}}"

(* user row: id, username, email, bio, image *)
let juser b (r : Pg.row) token =
  Buffer.add_string b "{\"user\":{\"email\":"; jcol b r 2;
  Buffer.add_string b ",\"token\":"; jstr b token;
  Buffer.add_string b ",\"username\":"; jcol b r 1;
  Buffer.add_string b ",\"bio\":"; jcol b r 3;
  Buffer.add_string b ",\"image\":"; jcol b r 4;
  Buffer.add_string b "}}"

(* comment row: id, body, created, updated, username, bio, image, [following] *)
let jcomment b (r : Pg.row) following =
  Buffer.add_string b "{\"id\":"; Buffer.add_string b (string_of_int (Pg.int r 0));
  Buffer.add_string b ",\"createdAt\":"; jts b r 2;
  Buffer.add_string b ",\"updatedAt\":"; jts b r 3;
  Buffer.add_string b ",\"body\":"; jcol b r 1;
  Buffer.add_string b ",\"author\":{\"username\":"; jcol b r 4;
  Buffer.add_string b ",\"bio\":"; jcol b r 5;
  Buffer.add_string b ",\"image\":"; jcol b r 6;
  Buffer.add_string b ",\"following\":"; jbool b following;
  Buffer.add_string b "}}"

(* ---------- JWT ---------- *)

let parse_uint s =
  let n = String.length s in
  if n = 0 || n > 15 then None
  else if String.for_all (fun c -> c >= '0' && c <= '9') s then Some (int_of_string s) else None


let secret = ref ""
let jwt_header = b64_encode ~url:true {|{"alg":"HS256","typ":"JWT"}|}

let make_token id =
  let now = int_of_float (Unix.time ()) in
  let payload = b64_encode ~url:true (Printf.sprintf {|{"sub":"%d","iat":%d,"exp":%d}|} id now (now + 30 * 86400)) in
  let si = jwt_header ^ "." ^ payload in
  si ^ "." ^ b64_encode ~url:true (hmac !secret si)

(* Fast path for a flat claims object whose values are escape-free strings or plain integers (what tokens look
   like): Some (first "sub" if a string, first "exp" if an integer). Anything else gives None and goes to Yojson,
   so the result is always what the Yojson path would decide. *)
let flat_claims s =
  let n = String.length s in
  let exception No in
  let rec ws i = if i < n && (s.[i] = ' ' || s.[i] = '\t' || s.[i] = '\n' || s.[i] = '\r') then ws (i + 1) else i in
  let str i = (* s.[i] = '"' *)
    let rec go j = if j >= n then raise No else match s.[j] with '"' -> j | '\\' -> raise No | c when Char.code c < 0x20 -> raise No | _ -> go (j + 1) in
    let j = go (i + 1) in (String.sub s (i + 1) (j - i - 1), j + 1) in
  try
    let i = ws 0 in
    if i >= n || s.[i] <> '{' then raise No;
    let sub = ref None and exp = ref None and seen_sub = ref false and seen_exp = ref false in
    let rec members i first =
      let i = ws i in
      if i < n && s.[i] = '}' then i + 1
      else begin
        let i = if first then i else if i < n && s.[i] = ',' then ws (i + 1) else raise No in
        if i >= n || s.[i] <> '"' then raise No;
        let key, i = str i in
        let i = ws i in
        if i >= n || s.[i] <> ':' then raise No;
        let i = ws (i + 1) in
        if i >= n then raise No;
        let i =
          if s.[i] = '"' then begin
            let v, j = str i in
            if key = "sub" && not !seen_sub then (seen_sub := true; sub := Some v);
            if key = "exp" then seen_exp := true;
            j
          end else begin
            let j = ref (if s.[i] = '-' then i + 1 else i) in
            let d0 = !j in
            while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
            if !j = d0 || !j - d0 > 17 then raise No;
            if !j < n && (s.[!j] = '.' || s.[!j] = 'e' || s.[!j] = 'E') then raise No;
            if key = "exp" && not !seen_exp then (seen_exp := true; exp := Some (int_of_string (String.sub s i (!j - i))));
            if key = "sub" then seen_sub := true;
            !j
          end in
        members i false
      end in
    let i = members (i + 1) true in
    if ws i <> n then raise No;
    Some (!sub, !exp)
  with No | Failure _ -> None

(* user id, or 0 when the token is invalid *)
let verify_token tok =
  match String.index_opt tok '.' with
  | None -> 0
  | Some d1 ->
    match String.index_from_opt tok (d1 + 1) '.' with
    | None -> 0
    | Some d2 ->
      let si = String.sub tok 0 d2 in
      let sg = String.sub tok (d2 + 1) (String.length tok - d2 - 1) in
      if not (Eqaf.equal sg (b64_encode ~url:true (hmac !secret si))) then 0
      else begin
        let h = String.sub tok 0 d1 in
        let alg_ok =
          h = jwt_header
          || (match b64_decode h with
              | Some j -> (try (match Yojson.Safe.from_string j with
                  | `Assoc l -> List.assoc_opt "alg" l = Some (`String "HS256") | _ -> false) with _ -> false)
              | None -> false) in
        if not alg_ok then 0
        else
          match b64_decode (String.sub tok (d1 + 1) (d2 - d1 - 1)) with
          | None -> 0
          | Some pl ->
            match flat_claims pl with
            | Some (sub, exp) ->
              let exp_ok = match exp with Some e -> float_of_int e > Unix.time () | None -> false in
              let sub = match sub with Some s -> (match parse_uint s with Some n -> n | None -> 0) | None -> 0 in
              if exp_ok && sub > 0 then sub else 0
            | None ->
            try
              match Yojson.Safe.from_string pl with
              | `Assoc l ->
                let now = Unix.time () in
                let exp_ok = match List.assoc_opt "exp" l with
                  | Some (`Int e) -> float_of_int e > now
                  | Some (`Float e) -> e > now
                  | _ -> false in
                let sub = match List.assoc_opt "sub" l with
                  | Some (`String s) -> (match parse_uint s with Some n -> n | None -> 0)
                  | _ -> 0 in
                if exp_ok && sub > 0 then sub else 0
              | _ -> 0
            with _ -> 0
      end

(* ---------- HTTP ---------- *)

type req = {
  meth : string;
  path : string list; (* decoded segments after /api *)
  query : (string * string) list;
  auth : string option; (* raw Authorization header *)
  body : string;
}

exception Http of int * string

let url_decode s =
  if not (String.contains s '%' || String.contains s '+') then s
  else begin
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      (match s.[!i] with
       | '+' -> Buffer.add_char b ' '
       | '%' when !i + 2 < n ->
         (match int_of_string_opt ("0x" ^ String.sub s (!i + 1) 2) with
          | Some v -> Buffer.add_char b (Char.chr v); i := !i + 2
          | None -> Buffer.add_char b '%')
       | c -> Buffer.add_char b c);
      incr i
    done;
    Buffer.contents b
  end

let path_decode s = if String.contains s '%' then url_decode (String.concat "%2B" (String.split_on_char '+' s)) else s

let status_text = function
  | 200 -> "OK" | 201 -> "Created" | 204 -> "No Content" | 401 -> "Unauthorized" | 403 -> "Forbidden"
  | 404 -> "Not Found" | 422 -> "Unprocessable Entity" | 500 -> "Internal Server Error" | _ -> "Error"

(* a response body is a writer, run when the response is written (straight into the domain's output buffer) *)
type body = Buffer.t -> unit
let with_buf (_ : int) (f : body) : body = f
let str_buf n f = let b = Buffer.create n in f b; Buffer.contents b

let error_body msg : body = fun b -> Buffer.add_string b "{\"errors\":{\"body\":["; jstr b msg; Buffer.add_string b "]}}"

(* ---------- request bodies ---------- *)

let parse_body body key =
  match (try Yojson.Safe.from_string body with _ -> raise (Http (422, "invalid JSON body"))) with
  | `Assoc l -> (match List.assoc_opt key l with Some (`Assoc o) -> o | _ -> raise (Http (422, key ^ " object required")))
  | _ -> raise (Http (422, "invalid body"))

let req_str o k =
  match List.assoc_opt k o with
  | Some (`String s) when s <> "" -> s
  | _ -> raise (Http (422, k ^ " must be a non-empty string"))

let opt_str ?(nonempty = false) o k =
  match List.assoc_opt k o with
  | None | Some `Null -> None
  | Some (`String "") when nonempty -> raise (Http (422, k ^ " must not be empty"))
  | Some (`String s) -> Some s
  | _ -> raise (Http (422, k ^ " must be a string"))

(* bcrypt only looks at the first 72 bytes, so longer passwords are rejected *)
let check_pw p = if String.length p > 72 then raise (Http (422, "password longer than 72 bytes")) else p


(* ---------- batch planner ----------
   Every waiting read (article, comments, profile, global/tag/author/favorited lists, feed, tags) of this domain
   goes into one batch, answered in two pipelined round trips on one connection (the design of our F# entry #87,
   after #47): phase A runs one statement per kind present over arrays of DISTINCT keys; phase B enriches the
   union of the articles phase A returned once (tags, favorite count, author) and reads the viewers' flags.
   Only requests already waiting share a batch; nothing outlives it. *)

module Plan = struct
  type kind = Art | Cmt | Prof | Global | Tag | Author | Fav | Feed | Tags

  type job = { kind : kind; key : string; viewer : int; lim : int; off : int; u : (int * body) P.u }

  let cols = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"
  let pad = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz"
  let by_id id = "CROSS JOIN LATERAL (SELECT a.* FROM articles a WHERE a.id = " ^ id ^ " OFFSET 0) a"

  let s_art = Pg.prepare ("SELECT r.k, " ^ cols ^ ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug")
  let s_cmt = Pg.prepare
      ("SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image \
        FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug \
        LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
        WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true \
        LEFT JOIN users u ON u.id = c.author_id ORDER BY r.k, c.created_at DESC, c.id DESC")
  let s_prof = Pg.prepare
      "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) JOIN users u ON u.username = r.username"
  let s_global = Pg.prepare
      ("SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), " ^ pad
       ^ " UNION ALL SELECT r.k, " ^ cols ^ " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) \
          CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a")
  let list_stmt key_join count page_join page =
    Pg.prepare
      ("SELECT -r.k, " ^ count ^ ", " ^ pad ^ " FROM unnest($1::text[]) WITH ORDINALITY r(key, k) " ^ key_join
       ^ " UNION ALL SELECT r.k, " ^ cols ^ " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(key, lim, off, k) "
       ^ page_join ^ " " ^ page)
  let s_tag = list_stmt "LEFT JOIN tags t ON t.name = r.key"
      "(SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = t.id LIMIT 1000) s)"
      "JOIN tags t ON t.name = r.key"
      ("CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p "
       ^ by_id "p.article_id")
  let s_author = list_stmt "LEFT JOIN users u ON u.username = r.key"
      "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = u.id LIMIT 1000) s)"
      "JOIN users u ON u.username = r.key"
      "CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"
  let s_fav = list_stmt "LEFT JOIN users u ON u.username = r.key"
      "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = u.id LIMIT 1000) s)"
      "JOIN users u ON u.username = r.key"
      ("CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p "
       ^ by_id "p.article_id")
  (* feeds: each distinct viewer's followees once; the batch's most shared followees are probed once for a 1000th
     article (then the capped count is 1000); a page reads the newest (limit + offset) of each followee *)
  let s_feed = Pg.prepare
      ("WITH q AS MATERIALIZED (SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fl \
        FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)), \
        h AS MATERIALIZED (SELECT ARRAY(SELECT t.a FROM (SELECT f.a FROM q, unnest(q.fl) AS f(a) GROUP BY f.a \
        HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8) t \
        WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = t.a OFFSET 999 LIMIT 1)) AS ha) \
        SELECT -q.k, CASE WHEN q.fl && (SELECT ha FROM h) THEN 1000::int8 \
        WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY (q.fl) ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::int8 \
        ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY (q.fl)) END, " ^ pad ^ " FROM q \
        UNION ALL SELECT p.k, " ^ cols ^ " FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k) \
        JOIN q ON q.v = p.v CROSS JOIN LATERAL (SELECT * FROM (SELECT y.id FROM unnest(q.fl) AS f(a) \
        CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = f.a ORDER BY a3.id DESC LIMIT (p.lim + p.off)) y \
        ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x0 LIMIT 100) x " ^ by_id "x.id")
  (* phase B *)
  let s_artx = Pg.prepare
      "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), \
       (SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image \
       FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author"
  (* every tag in name order, read after artx in the same pipeline (tags are never deleted): maps tag ids to names *)
  let s_tagall = Pg.prepare "SELECT t.id, t.name FROM tags t ORDER BY t.name"
  let s_flags = Pg.prepare
      "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), \
       q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) \
       SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL \
       (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY (p.aa)) f \
       UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL \
       (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (q.uu)) fo"

  (* array parameters in text form *)
  (* one scratch buffer per domain: an array literal is built and copied out with no yield in between *)
  let scratch = Domain.DLS.new_key (fun () -> Buffer.create 65536)
  let scratch_buf () = let b = Domain.DLS.get scratch in Buffer.clear b; b
  let text_arr (l : string list) =
    let b = scratch_buf () in
    Buffer.add_char b '{';
    List.iteri (fun k t ->
        if k > 0 then Buffer.add_char b ',';
        Buffer.add_char b '"';
        String.iter (fun c -> if c = '"' || c = '\\' then Buffer.add_char b '\\'; Buffer.add_char b c) t;
        Buffer.add_char b '"') l;
    Buffer.add_char b '}';
    Some (Buffer.contents b)
  let int_arr (l : int list) =
    let b = scratch_buf () in
    Buffer.add_char b '{';
    List.iteri (fun k v -> if k > 0 then Buffer.add_char b ','; Buffer.add_string b (string_of_int v)) l;
    Buffer.add_char b '}';
    Some (Buffer.contents b)

  (* distinct keys of one statement: key -> k (1-based), in insertion order *)
  module Keys = struct
    type 'a t = { tbl : ('a, int) Hashtbl.t; mutable rev : 'a list; mutable n : int }
    let create () = { tbl = Hashtbl.create 16; rev = []; n = 0 }
    let idx t key =
      match Hashtbl.find_opt t.tbl key with
      | Some k -> k
      | None -> t.n <- t.n + 1; Hashtbl.add t.tbl key t.n; t.rev <- key :: t.rev; t.n
    let keys t = List.rev t.rev
  end

  (* one article of the batch: its phase-A row (k, id, author, slug, title, description, created, updated [, body])
     and its phase-B row (id, tags, favorites count, username, bio, image) *)
  type art = { id : int; author : int; arow : Pg.row; mutable body : Pg.row option; mutable x : Pg.row option }

  type batch = {
    jobs : job array;
    kart : string Keys.t; kcmt : string Keys.t; kprof : string Keys.t;
    kglobal : (int * int) Keys.t;
    kcount : string Keys.t array; kpage : (string * int * int) Keys.t array; (* tag, author, fav *)
    kfeedc : int Keys.t; kfeedp : (int * int * int) Keys.t;
  }

  let li = function Tag -> 0 | Author -> 1 | _ -> 2

  (* tagList: the article's tag ids (binary int4[]) mapped to name ranks, sorted, written as names *)
  let jtags b (x : Pg.row) (rank : (int, int) Hashtbl.t) (names : Pg.row array) =
    Buffer.add_char b '[';
    let s = x.Pg.data and o = x.Pg.off.(1) in
    if x.Pg.len.(1) >= 20 && Int32.to_int (String.get_int32_be s o) = 1 then begin
      let n = Int32.to_int (String.get_int32_be s (o + 12)) in
      let rs = Array.make n max_int in
      let p = ref (o + 20) in
      for k = 0 to n - 1 do
        let l = Int32.to_int (String.get_int32_be s !p) in
        p := !p + 4;
        if l = 4 then begin
          let id = Int32.to_int (String.get_int32_be s !p) in
          (match Hashtbl.find_opt rank id with Some r -> rs.(k) <- r | None -> ())
        end;
        if l > 0 then p := !p + l
      done;
      Array.sort compare rs;
      let first = ref true in
      Array.iter (fun r -> if r <> max_int then begin
          if not !first then Buffer.add_char b ',';
          first := false; jcol b names.(r) 1 end) rs
    end;
    Buffer.add_char b ']'

  let jart b (a : art) ~full ~fav ~fol ~rank ~names =
    let r = a.arow and x = Option.get a.x in
    Buffer.add_string b "{\"slug\":"; jcol b r 3;
    Buffer.add_string b ",\"title\":"; jcol b r 4;
    Buffer.add_string b ",\"description\":"; jcol b r 5;
    (if full then match a.body with Some br -> Buffer.add_string b ",\"body\":"; jcol b br 8 | None -> ());
    Buffer.add_string b ",\"createdAt\":"; jts b r 6;
    Buffer.add_string b ",\"updatedAt\":"; jts b r 7;
    Buffer.add_string b ",\"tagList\":"; jtags b x rank names;
    Buffer.add_string b ",\"favoritesCount\":"; Buffer.add_string b (string_of_int (Pg.int x 2));
    Buffer.add_string b ",\"favorited\":"; jbool b fav;
    Buffer.add_string b ",\"author\":{\"username\":"; jcol b x 3;
    Buffer.add_string b ",\"bio\":"; jcol b x 4;
    Buffer.add_string b ",\"image\":"; jcol b x 5;
    Buffer.add_string b ",\"following\":"; jbool b fol;
    Buffer.add_string b "}}"

  let run_batch (c : Pg.conn) (jobs : job array) =
    let bt = { jobs; kart = Keys.create (); kcmt = Keys.create (); kprof = Keys.create (); kglobal = Keys.create ();
               kcount = Array.init 3 (fun _ -> Keys.create ()); kpage = Array.init 3 (fun _ -> Keys.create ());
               kfeedc = Keys.create (); kfeedp = Keys.create () } in
    let want_tags = ref false in
    (* per job: its key index (and page index for lists) *)
    let kidx = Array.make (Array.length jobs) 0 and pidx = Array.make (Array.length jobs) 0 in
    Array.iteri (fun i j ->
        match j.kind with
        | Art -> kidx.(i) <- Keys.idx bt.kart j.key
        | Cmt -> kidx.(i) <- Keys.idx bt.kcmt j.key
        | Prof -> kidx.(i) <- Keys.idx bt.kprof j.key
        | Global -> kidx.(i) <- Keys.idx bt.kglobal (j.lim, j.off)
        | Tag | Author | Fav ->
          let l = li j.kind in
          kidx.(i) <- Keys.idx bt.kcount.(l) j.key; pidx.(i) <- Keys.idx bt.kpage.(l) (j.key, j.lim, j.off)
        | Feed -> kidx.(i) <- Keys.idx bt.kfeedc j.viewer; pidx.(i) <- Keys.idx bt.kfeedp (j.viewer, j.lim, j.off)
        | Tags -> want_tags := true) jobs;
    (* phase A *)
    let stmts = ref [] and slot = Array.make 9 (-1) and n = ref 0 in
    let add q kind params = stmts := (q, params) :: !stmts; slot.(kind) <- !n; incr n in
    if bt.kart.n > 0 then add s_art 0 [| text_arr (Keys.keys bt.kart) |];
    if bt.kcmt.n > 0 then add s_cmt 1 [| text_arr (Keys.keys bt.kcmt) |];
    if bt.kprof.n > 0 then add s_prof 2 [| text_arr (Keys.keys bt.kprof) |];
    if bt.kglobal.n > 0 then begin
      let k = Keys.keys bt.kglobal in add s_global 3 [| int_arr (List.map fst k); int_arr (List.map snd k) |]
    end;
    Array.iteri (fun l q ->
        if bt.kpage.(l).n > 0 then begin
          let pk = Keys.keys bt.kpage.(l) in
          add q (4 + l) [| text_arr (Keys.keys bt.kcount.(l)); text_arr (List.map (fun (k, _, _) -> k) pk);
                           int_arr (List.map (fun (_, l, _) -> l) pk); int_arr (List.map (fun (_, _, o) -> o) pk) |]
        end) [| s_tag; s_author; s_fav |];
    if bt.kfeedp.n > 0 then begin
      let pk = Keys.keys bt.kfeedp in
      add s_feed 7 [| int_arr (Keys.keys bt.kfeedc); int_arr (List.map (fun (v, _, _) -> v) pk);
                      int_arr (List.map (fun (_, l, _) -> l) pk); int_arr (List.map (fun (_, _, o) -> o) pk) |]
    end;
    let ra, _ = Pg.run c (List.rev !stmts) in
    let res kind = if slot.(kind) < 0 then [] else ra.(slot.(kind)) in
    (* collect articles *)
    let arts : (int, art) Hashtbl.t = Hashtbl.create 256 in
    let art_of (r : Pg.row) ~body =
      let id = Pg.int r 1 in
      match Hashtbl.find_opt arts id with
      | Some a -> if body && a.body = None then a.body <- Some r; a
      | None ->
        let a = { id; author = Pg.int r 2; arow = r; body = (if body then Some r else None); x = None } in
        Hashtbl.add arts id a; a in
    let art_k = Array.make (bt.kart.n + 1) None in
    List.iter (fun r -> art_k.(Pg.int r 0) <- Some (art_of r ~body:true)) (res 0);
    (* pages: (stmt slot, k) -> articles; counts: (stmt slot, k) -> count *)
    let pages : (int * int, art list) Hashtbl.t = Hashtbl.create 64 and counts : (int * int, int) Hashtbl.t = Hashtbl.create 64 in
    List.iter (fun kind ->
        List.iter (fun r ->
            let k = Pg.int r 0 in
            if k <= 0 then Hashtbl.replace counts (kind, - k) (Pg.int r 1)
            else begin
              let a = art_of r ~body:false in
              Hashtbl.replace pages (kind, k) (a :: (try Hashtbl.find pages (kind, k) with Not_found -> []))
            end) (res kind)) [ 3; 4; 5; 6; 7 ];
    let cmts = Array.make (bt.kcmt.n + 1) None in (* k -> (article id, comment rows newest first) *)
    List.iter (fun r ->
        let k = Pg.int r 0 in
        let prev = match cmts.(k) with Some (_, l) -> l | None -> [] in
        cmts.(k) <- Some (Pg.int r 1, if Pg.is_null r 2 then prev else r :: prev)) (List.rev (res 1));
    let profs = Array.make (bt.kprof.n + 1) None in
    List.iter (fun r -> profs.(Pg.int r 0) <- Some r) (res 2);
    (* phase B: enrich every article once; flags for viewers *)
    let fav_ask = Hashtbl.create 64 and fol_ask = Hashtbl.create 64 in
    let ask_fav v id = if v > 0 then Hashtbl.replace fav_ask (v, id) () in
    let ask_fol v u = if v > 0 then Hashtbl.replace fol_ask (v, u) () in
    Array.iteri (fun i j ->
        let v = j.viewer in
        if v > 0 then
          match j.kind with
          | Art -> (match art_k.(kidx.(i)) with Some a -> ask_fav v a.id; ask_fol v a.author | None -> ())
          | Cmt -> (match cmts.(kidx.(i)) with Some (_, l) -> List.iter (fun r -> ask_fol v (Pg.int r 6)) l | None -> ())
          | Prof -> (match profs.(kidx.(i)) with Some r -> ask_fol v (Pg.int r 1) | None -> ())
          | Global | Tag | Author | Fav | Feed ->
            let kind, k = (match j.kind with Global -> 3, kidx.(i) | Feed -> 7, pidx.(i) | _ -> 4 + li j.kind, pidx.(i)) in
            List.iter (fun a -> ask_fav v a.id; if j.kind <> Feed then ask_fol v a.author)
              (try Hashtbl.find pages (kind, k) with Not_found -> [])
          | Tags -> ()) jobs;
    let favs = Hashtbl.create 64 and fols = Hashtbl.create 64 in
    let ids = Hashtbl.fold (fun id a acc -> (id, a.author) :: acc) arts [] in
    let fa = Hashtbl.fold (fun k () acc -> k :: acc) fav_ask [] and fo = Hashtbl.fold (fun k () acc -> k :: acc) fol_ask [] in
    let has_flags = fa <> [] || fo <> [] and has_tags = ids <> [] || !want_tags in
    let bst = (if ids <> [] then [ (s_artx, [| int_arr (List.map fst ids); int_arr (List.map snd ids) |]) ] else [])
              @ (if has_flags then
                   [ (s_flags, [| int_arr (List.map fst fa); int_arr (List.map snd fa);
                                  int_arr (List.map fst fo); int_arr (List.map snd fo) |]) ] else [])
              @ (if has_tags then [ (s_tagall, [||]) ] else []) in
    let names = ref [||] and rank = Hashtbl.create 256 in
    if bst <> [] then begin
      let rb, _ = Pg.run c bst in
      let xi = if ids <> [] then 0 else -1 in
      let fi = if has_flags then xi + 1 else -1 in
      let ti = if has_tags then (if has_flags then fi + 1 else xi + 1) else -1 in
      if xi >= 0 then List.iter (fun r -> match Hashtbl.find_opt arts (Pg.int r 0) with Some a -> a.x <- Some r | None -> ()) rb.(xi);
      if fi >= 0 then
        List.iter (fun r ->
            let key = (Pg.int r 1, Pg.int r 2) in
            if Pg.int r 0 = 0 then Hashtbl.replace favs key () else Hashtbl.replace fols key ()) rb.(fi);
      if ti >= 0 then begin
        names := Array.of_list rb.(ti);
        Array.iteri (fun k r -> Hashtbl.replace rank (Pg.int r 0) k) !names
      end
    end;
    let names = !names in
    let is_fav v id = v > 0 && Hashtbl.mem favs (v, id) and is_fol v u = v > 0 && Hashtbl.mem fols (v, u) in
    (* answers *)
    let tags_body = (fun b ->
        Buffer.add_string b "{\"tags\":[";
        Array.iteri (fun k r -> if k > 0 then Buffer.add_char b ','; jcol b r 1) names;
        Buffer.add_string b "]}") in
    let nf = (404, error_body "article not found") in
    Array.iteri (fun i j ->
        let v = j.viewer in
        let ans =
          match j.kind with
          | Tags -> (200, tags_body)
          | Art ->
            (match art_k.(kidx.(i)) with
             | Some a when a.x <> None ->
               (200, with_buf 2048 (fun b ->
                    Buffer.add_string b "{\"article\":"; jart b a ~full:true ~fav:(is_fav v a.id) ~fol:(is_fol v a.author) ~rank ~names;
                    Buffer.add_char b '}'))
             | _ -> nf)
          | Cmt ->
            (match cmts.(kidx.(i)) with
             | None -> nf
             | Some (_, l) ->
               (200, with_buf 4096 (fun b ->
                    Buffer.add_string b "{\"comments\":[";
                    List.iteri (fun k r ->
                        if k > 0 then Buffer.add_char b ',';
                        Buffer.add_string b "{\"id\":"; Buffer.add_string b (string_of_int (Pg.int r 2));
                        Buffer.add_string b ",\"createdAt\":"; jts b r 4;
                        Buffer.add_string b ",\"updatedAt\":"; jts b r 5;
                        Buffer.add_string b ",\"body\":"; jcol b r 3;
                        Buffer.add_string b ",\"author\":{\"username\":"; jcol b r 7;
                        Buffer.add_string b ",\"bio\":"; jcol b r 8;
                        Buffer.add_string b ",\"image\":"; jcol b r 9;
                        Buffer.add_string b ",\"following\":"; jbool b (is_fol v (Pg.int r 6));
                        Buffer.add_string b "}}") l;
                    Buffer.add_string b "]}")))
          | Prof ->
            (match profs.(kidx.(i)) with
             | None -> (404, error_body "profile not found")
             | Some r ->
               (200, with_buf 256 (fun b ->
                    Buffer.add_string b "{\"profile\":{\"username\":"; jcol b r 2;
                    Buffer.add_string b ",\"bio\":"; jcol b r 3;
                    Buffer.add_string b ",\"image\":"; jcol b r 4;
                    Buffer.add_string b ",\"following\":"; jbool b (is_fol v (Pg.int r 1));
                    Buffer.add_string b "}}")))
          | Global | Tag | Author | Fav | Feed ->
            let kind, k, ck = (match j.kind with
                | Global -> 3, kidx.(i), 0 | Feed -> 7, pidx.(i), kidx.(i) | _ -> 4 + li j.kind, pidx.(i), kidx.(i)) in
            let page = List.sort (fun a b -> compare b.id a.id) (try Hashtbl.find pages (kind, k) with Not_found -> []) in
            let count = try Hashtbl.find counts (kind, ck) with Not_found -> 0 in
            (200, with_buf 8192 (fun b ->
                 Buffer.add_string b "{\"articles\":[";
                 let first = ref true in
                 List.iter (fun a ->
                     if a.x <> None then begin
                       if not !first then Buffer.add_char b ',';
                       first := false;
                       jart b a ~full:false ~fav:(is_fav v a.id) ~fol:(j.kind = Feed || is_fol v a.author) ~rank ~names
                     end) page;
                 Buffer.add_string b "],\"articlesCount\":";
                 Buffer.add_string b (string_of_int count);
                 Buffer.add_char b '}')) in
        P.resolve j.u ans) jobs

  (* the queue is shared by every domain (Mutex); the planner loops and their connections live on one domain, and
     each answer's body is written by the requesting fiber, on its own domain *)
  type t = { m : Mutex.t; q : job Queue.t; mutable waiters : unit P.u list }

  let create () = { m = Mutex.create (); q = Queue.create (); waiters = [] }
  let max_batch = int_of_string (getenv "PLANNER_MAX" "1024")

  let submit t job =
    Mutex.lock t.m;
    Queue.push job t.q;
    let w = match t.waiters with w :: rest -> t.waiters <- rest; Some w | [] -> None in
    Mutex.unlock t.m;
    match w with Some w -> P.resolve w () | None -> ()

  (* one loop per in-flight batch: wait for work, let the other ready fibers queue theirs, take everything *)
  let wait_s = float_of_string (getenv "PLANNER_WAIT_US" "15000") /. 1e6

  let loop t pick sleep =
    let rec go () =
      Mutex.lock t.m;
      if Queue.is_empty t.q then begin
        let p, u = P.create () in
        t.waiters <- u :: t.waiters;
        Mutex.unlock t.m;
        P.await p
      end else Mutex.unlock t.m;
      (* collect: bigger batches cost Postgres less per request *)
      if wait_s > 0. then sleep wait_s else Eio.Fiber.yield ();
      Mutex.lock t.m;
      let n = min max_batch (Queue.length t.q) in
      let jobs = Array.init n (fun _ -> Queue.pop t.q) in
      Mutex.unlock t.m;
      if n > 0 then begin
        (try run_batch (pick ()) jobs with
         | Eio.Io _ as e -> raise e
         | e ->
           Printf.eprintf "planner error: %s\n%!" (Printexc.to_string e);
           Array.iter (fun j -> try P.resolve j.u (500, error_body "database error") with Invalid_argument _ -> ()) jobs)
      end;
      go () in
    go ()
end

(* ---------- handlers ---------- *)

let i v = Some (string_of_int v)
let s v = Some v

type ctx = { pick : unit -> Pg.conn; plan : Plan.t;
             rbuf : Bytes.t; bodyb : Buffer.t; mutable wbuf : Bytes.t } (* per domain; never held across a suspension *)

let planned ctx ?(key = "") ?(lim = 0) ?(off = 0) kind viewer =
  let p, u = P.create () in
  Plan.submit ctx.plan { Plan.kind; key; viewer; lim; off; u };
  P.await p

let viewer_of req ~required =
  match req.auth with
  | None -> if required then raise (Http (401, "authentication required")) else (0, "")
  | Some h ->
    let tok =
      if String.length h > 6 && String.sub h 0 6 = "Token " then String.sub h 6 (String.length h - 6) else "" in
    let id = if tok = "" then 0 else verify_token tok in
    if id = 0 then raise (Http (401, "invalid token")) else (id, tok)

let respond_user r token = (200, fun b -> juser b r token)

let article_resp code full r = (code, with_buf 2048 (fun b -> Buffer.add_string b "{\"article\":"; jarticle b full r; Buffer.add_char b '}'))

let list_resp rows count =
  with_buf 8192 (fun b ->
      Buffer.add_string b "{\"articles\":[";
      List.iteri (fun k r -> if k > 0 then Buffer.add_char b ','; jarticle b false r) rows;
      Buffer.add_string b "],\"articlesCount\":";
      Buffer.add_string b (string_of_int count);
      Buffer.add_char b '}')

let profile_resp r following =
  (* r: [id,] username, bio, image starting at column 1 *)
  (200, with_buf 256 (fun b ->
       Buffer.add_string b "{\"profile\":{\"username\":"; jcol b r 1;
       Buffer.add_string b ",\"bio\":"; jcol b r 2;
       Buffer.add_string b ",\"image\":"; jcol b r 3;
       Buffer.add_string b ",\"following\":"; jbool b following;
       Buffer.add_string b "}}"))

let page req =
  let get k = List.assoc_opt k req.query in
  let limit = match get "limit" with
    | None -> 20
    | Some v -> (match parse_uint v with Some n when n >= 1 && n <= 100 -> n | _ -> raise (Http (422, "bad limit"))) in
  let offset = match get "offset" with
    | None -> 0
    | Some v -> (match parse_uint v with Some n -> n | None -> raise (Http (422, "bad offset"))) in
  (limit, offset)

let one = function [ r ] -> Some r | r :: _ -> Some r | [] -> None

let handle ctx req =
  let c = ctx.pick () in
  let run = Pg.run c and query = Pg.query c in
  match req.meth, req.path with
  | "GET", [ "tags" ] -> planned ctx Plan.Tags 0
  | "POST", [ "users" ] ->
    let o = parse_body req.body "user" in
    let username = req_str o "username" and email = req_str o "email" and password = check_pw (req_str o "password") in
    let h = bcrypt_hash password in
    (match query q_insert_user [| s username; s email; s h |] with
     | exception Pg.Pg_error ("23505", _) -> raise (Http (422, "username or email already taken"))
     | rows ->
       let r = Option.get (one rows) in
       let code, body = respond_user r (make_token (Pg.int r 0)) in
       ignore code; (201, body))
  | "POST", [ "users"; "login" ] ->
    let o = parse_body req.body "user" in
    let email = req_str o "email" and password = req_str o "password" in
    (match one (query q_login [| s email |]) with
     | None -> raise (Http (401, "invalid credentials"))
     | Some r ->
       if bcrypt_verify password (Pg.text r 5) then respond_user r (make_token (Pg.int r 0))
       else raise (Http (401, "invalid credentials")))
  | "GET", [ "user" ] ->
    let viewer, tok = viewer_of req ~required:true in
    (match one (query q_user [| i viewer |]) with
     | None -> raise (Http (401, "user not found"))
     | Some r -> respond_user r tok)
  | "PUT", [ "user" ] ->
    let viewer, tok = viewer_of req ~required:true in
    let o = parse_body req.body "user" in
    let email = opt_str ~nonempty:true o "email" and username = opt_str ~nonempty:true o "username"
    and password = Option.map check_pw (opt_str ~nonempty:true o "password")
    and bio = opt_str o "bio" and image = opt_str o "image" in
    let ph = match password with Some p -> Some (bcrypt_hash p) | None -> None in
    (match query q_update_user [| i viewer; email; username; ph; bio; image |] with
     | exception Pg.Pg_error ("23505", _) -> raise (Http (422, "username or email already taken"))
     | rows -> (match one rows with None -> raise (Http (401, "user not found")) | Some r -> respond_user r tok))
  | "GET", [ "profiles"; u ] ->
    let viewer, _ = viewer_of req ~required:false in
    planned ctx ~key:u Plan.Prof viewer
  | ("POST" | "DELETE") as m, [ "profiles"; u; "follow" ] ->
    let viewer, _ = viewer_of req ~required:true in
    let res, _ = run [ ((if m = "POST" then q_follow else q_unfollow), [| i viewer; s u |]); (q_user_by_name, [| s u |]) ] in
    (match one res.(1) with
     | None -> raise (Http (404, "profile not found"))
     | Some r -> profile_resp r (m = "POST"))
  | "GET", [ "articles" ] ->
    let viewer, _ = viewer_of req ~required:false in
    let limit, offset = page req in
    let filter k = match List.assoc_opt k req.query with Some v when v <> "" -> Some v | _ -> None in
    (match filter "tag", filter "author", filter "favorited" with
     | Some t, _, _ -> planned ctx ~key:t ~lim:limit ~off:offset Plan.Tag viewer
     | None, Some a, _ -> planned ctx ~key:a ~lim:limit ~off:offset Plan.Author viewer
     | None, None, Some f -> planned ctx ~key:f ~lim:limit ~off:offset Plan.Fav viewer
     | None, None, None -> planned ctx ~lim:limit ~off:offset Plan.Global viewer)
  | "GET", [ "articles"; "feed" ] ->
    let viewer, _ = viewer_of req ~required:true in
    let limit, offset = page req in
    planned ctx ~lim:limit ~off:offset Plan.Feed viewer
  | "POST", [ "articles" ] ->
    let viewer, _ = viewer_of req ~required:true in
    let o = parse_body req.body "article" in
    let title = req_str o "title" and description = req_str o "description" and body = req_str o "body" in
    let tags = match List.assoc_opt "tagList" o with
      | None | Some `Null -> []
      | Some (`List l) -> List.map (function `String t when t <> "" -> t | _ -> raise (Http (422, "tagList must hold non-empty strings"))) l
      | _ -> raise (Http (422, "tagList must be an array")) in
    let ins = (q_insert_article, [| i viewer; s title; s description; s body |]) in
    let batch =
      if tags = [] then [ ins ]
      else begin
        let arr = str_buf 64 (fun b ->
            Buffer.add_char b '{';
            List.iteri (fun k t ->
                if k > 0 then Buffer.add_char b ',';
                Buffer.add_char b '"';
                String.iter (fun c -> if c = '"' || c = '\\' then Buffer.add_char b '\\'; Buffer.add_char b c) t;
                Buffer.add_char b '"') tags;
            Buffer.add_char b '}') in
        [ ins; (q_insert_tags, [| s arr |]); (q_insert_article_tags, [| s arr |]) ]
      end in
    let res, _ = run batch in
    let id = Pg.int (Option.get (one res.(0))) 0 in
    (match one (query q_article_id [| i viewer; i id |]) with
     | Some r -> article_resp 201 true r
     | None -> raise (Http (500, "article vanished")))
  | "GET", [ "articles"; slug ] ->
    let viewer, _ = viewer_of req ~required:false in
    planned ctx ~key:slug Plan.Art viewer
  | "PUT", [ "articles"; slug ] ->
    let viewer, _ = viewer_of req ~required:true in
    let o = parse_body req.body "article" in
    let title = opt_str ~nonempty:true o "title" and description = opt_str ~nonempty:true o "description"
    and body = opt_str ~nonempty:true o "body" in
    (match one (query q_article_owner [| s slug |]) with
     | None -> raise (Http (404, "article not found"))
     | Some r ->
       let id = Pg.int r 0 in
       if Pg.int r 1 <> viewer then raise (Http (403, "not your article"));
       let res, _ = run [ (q_update_article, [| i id; title; description; body |]); (q_article_id, [| i viewer; i id |]) ] in
       (match one res.(1) with Some r -> article_resp 200 true r | None -> raise (Http (404, "article not found"))))
  | "DELETE", [ "articles"; slug ] ->
    let viewer, _ = viewer_of req ~required:true in
    (match one (query q_article_owner [| s slug |]) with
     | None -> raise (Http (404, "article not found"))
     | Some r ->
       if Pg.int r 1 <> viewer then raise (Http (403, "not your article"));
       ignore (query q_delete_article [| i (Pg.int r 0) |]);
       (204, ignore))
  | ("POST" | "DELETE") as m, [ "articles"; slug; "favorite" ] ->
    let viewer, _ = viewer_of req ~required:true in
    let res, _ = run [ ((if m = "POST" then q_fav else q_unfav), [| i viewer; s slug |]);
                       (q_article_slug, [| i viewer; s slug |]) ] in
    (match one res.(1) with Some r -> article_resp 200 true r | None -> raise (Http (404, "article not found")))
  | "GET", [ "articles"; slug; "comments" ] ->
    let viewer, _ = viewer_of req ~required:false in
    planned ctx ~key:slug Plan.Cmt viewer
  | "POST", [ "articles"; slug; "comments" ] ->
    let viewer, _ = viewer_of req ~required:true in
    let o = parse_body req.body "comment" in
    let body = req_str o "body" in
    (match one (query q_article_id_by_slug [| s slug |]) with
     | None -> raise (Http (404, "article not found"))
     | Some a ->
       let r = Option.get (one (query q_insert_comment [| i (Pg.int a 0); i viewer; s body |])) in
       (201, with_buf 512 (fun b -> Buffer.add_string b "{\"comment\":"; jcomment b r false; Buffer.add_char b '}')))
  | "DELETE", [ "articles"; slug; "comments"; cid ] ->
    let viewer, _ = viewer_of req ~required:true in
    let cid = match parse_uint cid with Some n -> n | None -> raise (Http (404, "comment not found")) in
    (match one (query q_comment_owner [| i cid; s slug |]) with
     | None -> raise (Http (404, "comment not found"))
     | Some r ->
       if Pg.int r 0 <> viewer then raise (Http (403, "not your comment"));
       ignore (query q_delete_comment [| i cid |]);
       (204, ignore))
  | _ -> raise (Http (404, "not found"))

(* ---------- connection loop ---------- *)

(* h starts with the lowercase p, ignoring ASCII case; no allocation *)
let lower_prefix h p =
  let n = String.length p in
  String.length h > n
  && (let rec go i = i = n || (Char.lowercase_ascii (String.unsafe_get h i) = String.unsafe_get p i && go (i + 1)) in go 0)

let header_value h n =
  let v = String.sub h n (String.length h - n) in String.trim v

let dispatch ctx meth target auth body =
  let path, qs = match String.index_opt target '?' with
    | Some k -> String.sub target 0 k, String.sub target (k + 1) (String.length target - k - 1)
    | None -> target, "" in
  let query =
    if qs = "" then []
    else List.filter_map (fun kv ->
        if kv = "" then None
        else match String.index_opt kv '=' with
          | Some k -> Some (url_decode (String.sub kv 0 k), url_decode (String.sub kv (k + 1) (String.length kv - k - 1)))
          | None -> Some (url_decode kv, "")) (String.split_on_char '&' qs) in
  (* keep the first occurrence of each key, as Go's Query().Get does *)
  let query = List.rev (List.fold_left (fun acc (k, v) -> if List.mem_assoc k acc then acc else (k, v) :: acc) [] query) in
  match String.split_on_char '/' path with
  | "" :: "api" :: segs ->
    let segs = List.map path_decode (List.filter (fun x -> x <> "") segs) in
    (try handle ctx { meth; path = segs; query; auth; body } with
     | Http (code, msg) -> (code, error_body msg)
     | Pg.Pg_error (code, msg) -> Printf.eprintf "pg error %s %s\n%!" code msg; (500, error_body "database error")
     | Eio.Io _ as e -> raise e
     | e -> Printf.eprintf "error: %s\n%!" (Printexc.to_string e); (500, error_body "internal error"))
  | _ -> (404, error_body "not found")

(* one parsed request out of the connection's pending bytes, or None when it isn't complete yet *)
let find_head s =
  let n = String.length s in
  let rec go i =
    match String.index_from_opt s i '\r' with
    | Some j when j + 3 < n -> if s.[j + 1] = '\n' && s.[j + 2] = '\r' && s.[j + 3] = '\n' then Some j else go (j + 1)
    | _ -> None in
  go 0

exception Bad_request

let parse_request s =
  match find_head s with
  | None -> if String.length s > 65536 then raise Bad_request else None
  | Some hend ->
    let le = String.index s '\r' in
    let line = String.sub s 0 le in
    let meth, target = match String.split_on_char ' ' line with m :: t :: _ -> m, t | _ -> "", "/" in
    let clen = ref 0 and auth = ref None and close = ref false in
    let p = ref (le + 2) in
    while !p < hend do
      let e = match String.index_from_opt s !p '\r' with Some e when e <= hend -> e | _ -> hend in
      let h = String.sub s !p (e - !p) in
      (if lower_prefix h "content-length:" then clen := (try int_of_string (header_value h 15) with _ -> 0)
       else if lower_prefix h "authorization:" then auth := Some (header_value h 14)
       else if lower_prefix h "connection:" then close := String.lowercase_ascii (header_value h 11) = "close");
      p := e + 2
    done;
    let bstart = hend + 4 in
    if String.length s < bstart + !clen then None
    else Some (meth, target, !auth, !close, String.sub s bstart !clen, bstart + !clen)

let write_all fd (b : Bytes.t) off len =
  let rec go off len =
    if len > 0 then
      match Unix.single_write fd b off len with
      | k -> go (off + k) (len - k)
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
        (* the domain's buffer may be reused while we wait: wait on a private copy *)
        let rest = Bytes.sub b off len in
        let rec slow off len =
          if len > 0 then begin
            Eio_unix.await_writable fd;
            match Unix.single_write fd rest off len with
            | k -> slow (off + k) (len - k)
            | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> slow off len
          end in
        slow 0 len in
  go off len

let respond ctx fd code (body : body) =
  let bb = ctx.bodyb in
  Buffer.clear bb;
  let code, blen =
    if code = 204 then (204, 0)
    else match body bb with
      | () -> (code, Buffer.length bb)
      | exception e ->
        Printf.eprintf "error: %s\n%!" (Printexc.to_string e);
        Buffer.clear bb; error_body "internal error" bb; (500, Buffer.length bb) in
  let head =
    if code = 204 then "HTTP/1.1 204 No Content\r\n\r\n"
    else if code = 200 then "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " ^ string_of_int blen ^ "\r\n\r\n"
    else "HTTP/1.1 " ^ string_of_int code ^ " " ^ status_text code ^ "\r\nContent-Type: application/json\r\nContent-Length: "
         ^ string_of_int blen ^ "\r\n\r\n" in
  let hl = String.length head in
  if Bytes.length ctx.wbuf < hl + blen then ctx.wbuf <- Bytes.create (2 * (hl + blen));
  Bytes.blit_string head 0 ctx.wbuf 0 hl;
  Buffer.blit bb 0 ctx.wbuf hl blen;
  write_all fd ctx.wbuf 0 (hl + blen)

(* a connection: wait until readable, read into the domain's buffer, answer every complete request; an idle
   connection keeps no buffer of its own *)
let serve ctx fd =
  let pending = ref "" in
  let rec loop () =
    match parse_request !pending with
    | exception Bad_request -> ()
    | Some (meth, target, auth, close, body, used) ->
      let rest = String.length !pending - used in
      pending := (if rest = 0 then "" else String.sub !pending used rest);
      let code, b = dispatch ctx meth target auth body in
      respond ctx fd code b;
      if not close then loop ()
    | None ->
      Eio_unix.await_readable fd;
      match Unix.read fd ctx.rbuf 0 (Bytes.length ctx.rbuf) with
      | 0 -> ()
      | n ->
        pending := (if !pending = "" then Bytes.sub_string ctx.rbuf 0 n else !pending ^ Bytes.sub_string ctx.rbuf 0 n);
        loop ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> loop ()
      | exception Unix.Unix_error _ -> ()
  in
  loop ()

(* ---------- diagnostics: MEMPROF=<rate> samples allocations per domain (Gc.Memprof) and prints the top
   allocation sites (words sampled, words of those promoted) every 30 s. Off by default. ---------- *)

let memprof_rate = float_of_string (getenv "MEMPROF" "0")
let mp_m = Mutex.create ()
let mp_tbl : (string, float ref * float ref) Hashtbl.t = Hashtbl.create 256

let mp_key cs =
  match Printexc.backtrace_slots cs with
  | None -> "?"
  | Some slots ->
    let b = Buffer.create 80 and k = ref 0 in
    Array.iter (fun s ->
        if !k < 4 then
          match Printexc.Slot.location s with
          | Some l when l.Printexc.filename <> "" ->
            incr k; if !k > 1 then Buffer.add_string b " < ";
            Buffer.add_string b (Filename.basename l.Printexc.filename ^ ":" ^ string_of_int l.Printexc.line_number)
          | _ -> ()) slots;
    Buffer.contents b

let mp_add key words promoted =
  Mutex.lock mp_m;
  let a, p = match Hashtbl.find_opt mp_tbl key with
    | Some e -> e | None -> let e = (ref 0., ref 0.) in Hashtbl.replace mp_tbl key e; e in
  a := !a +. words; p := !p +. promoted;
  Mutex.unlock mp_m

let memprof_start () =
  let tracker = { Gc.Memprof.null_tracker with
    alloc_minor = (fun (a : Gc.Memprof.allocation) ->
        let key = mp_key a.callstack in
        let w = float (a.n_samples * (a.size + 1)) in
        mp_add key w 0.; Some (key, w));
    alloc_major = (fun (a : Gc.Memprof.allocation) ->
        mp_add ("MAJOR " ^ mp_key a.callstack) (float (a.n_samples * (a.size + 1))) 0.; None);
    promote = (fun (key, w) -> mp_add key 0. w; None) } in
  ignore (Gc.Memprof.start ~sampling_rate:memprof_rate ~callstack_size:24 tracker)

let memprof_dump () =
  Mutex.lock mp_m;
  let l = Hashtbl.fold (fun k (a, p) acc -> (k, !a, !p) :: acc) mp_tbl [] in
  Mutex.unlock mp_m;
  let tot = List.fold_left (fun s (_, a, _) -> s +. a) 0. l in
  let l = List.sort (fun (_, a, _) (_, b, _) -> compare b a) l in
  Printf.eprintf "memprof total sampled words %.0f (rate %g)\n" tot memprof_rate;
  List.iteri (fun i (k, a, p) -> if i < 40 then
                 Printf.eprintf "memprof %5.1f%% words %.0f promoted %.0f  %s\n" (100. *. a /. tot) a p k) l;
  flush stderr

(* ---------- main ---------- *)

let () =
  Random.self_init ();
  secret := getenv "JWT_SECRET" "multicore-server-challenge";
  let url = Pg.parse_url (getenv "DATABASE_URL" "postgres://conduit:conduit@127.0.0.1:5432/conduit") in
  let host = getenv "HOST" "127.0.0.1" and port = int_of_string (getenv "PORT" "3000") in
  let ncpu = Domain.recommended_domain_count () in
  let domains = int_of_string (getenv "DOMAINS" (string_of_int (max 2 (ncpu * 3 / 4)))) in
  (* PLANNER_CENTRAL=1: one planner for the whole process, on domain 0 with PLANNER_CONNS read connections
     (cheaper below saturation, but domain 0 becomes the ceiling);
     0: a planner per domain on that domain's connections *)
  let central = getenv "PLANNER_CENTRAL" "0" = "1" in
  let planner_loops = int_of_string (getenv "PLANNER_LOOPS" (if central then "4" else "2")) in
  let planner_conns = int_of_string (getenv "PLANNER_CONNS" (string_of_int planner_loops)) in
  let conns_per = int_of_string (getenv "PG_CONNS_PER_DOMAIN" (string_of_int (max 1 (min (if central then 4 else 8) (64 / domains))))) in
  let shared = Plan.create () in
  Bc.start ();
  (* GC_STATS=1: print GC counters every 10 s (diagnostics only) *)
  if getenv "GC_STATS" "0" = "1" then
    ignore (Thread.create (fun () ->
        while true do
          Thread.delay 10.;
          let st = Gc.quick_stat () in
          Printf.eprintf "gc minor_words=%.0f promoted=%.0f major_words=%.0f minor_gcs=%d major_gcs=%d heap_words=%d\n%!"
            st.Gc.minor_words st.Gc.promoted_words st.Gc.major_words st.Gc.minor_collections st.Gc.major_collections st.Gc.heap_words
        done) ());
  if memprof_rate > 0. then
    ignore (Thread.create (fun () -> while true do Thread.delay 30.; memprof_dump () done) ());
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env and dm = Eio.Stdenv.domain_mgr env in
  let clock = Eio.Stdenv.mono_clock env in
  let sleep d = Eio.Time.Mono.sleep clock d in
  let addr = `Tcp (Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string host), port) in
  let picker conns =
    let rr = ref 0 in
    fun () ->
      (* least queued, starting from a rotating index *)
      let n = Array.length conns in
      rr := (!rr + 1) mod n;
      let best = ref conns.(!rr) in
      for j = 1 to n - 1 do
        let c = conns.((!rr + j) mod n) in
        if Queue.length c.Pg.q < Queue.length !best.Pg.q then best := c
      done;
      !best in
  let worker k () =
    if memprof_rate > 0. then memprof_start ();
    Eio.Switch.run @@ fun sw ->
    let conns = Array.init conns_per (fun _ -> Pg.connect ~sw net url) in
    let pick = picker conns in
    let plan =
      if central then begin
        if k = 0 then begin
          let pconns = Array.init planner_conns (fun _ -> Pg.connect ~sw net url) in
          let ppick = picker pconns in
          for _ = 1 to planner_loops do Eio.Fiber.fork_daemon ~sw (fun () -> Plan.loop shared ppick sleep) done
        end;
        shared
      end else begin
        let plan = Plan.create () in
        for _ = 1 to planner_loops do Eio.Fiber.fork_daemon ~sw (fun () -> Plan.loop plan pick sleep) done;
        plan
      end in
    let ctx = { pick; plan; rbuf = Bytes.create 65536; bodyb = Buffer.create 65536; wbuf = Bytes.create 65536 } in
    let sock = Eio.Net.listen ~sw ~backlog:4096 ~reuse_addr:true ~reuse_port:true net addr in
    if k = 0 then Printf.printf "conduit (ocaml %s) on %s:%d, %d domains x %d pg conns\n%!" Sys.ocaml_version host port domains conns_per;
    let rec accept () =
      Eio.Net.accept_fork ~sw sock ~on_error:(fun _ -> ()) (fun flow _ ->
          match Eio_unix.Resource.fd_opt flow with
          | Some fd ->
            Eio_unix.Fd.use_exn "serve" fd (fun u ->
                (try Unix.setsockopt u Unix.TCP_NODELAY true with _ -> ());
                Unix.set_nonblock u;
                serve ctx u)
          | None -> ());
      accept () in
    accept ()
  in
  Eio.Fiber.all (List.init domains (fun k -> if k = 0 then worker 0 else fun () -> Eio.Domain_manager.run dm (worker k)))
