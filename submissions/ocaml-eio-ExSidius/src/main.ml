(* One Eio event loop per domain, each with its own SO_REUSEPORT listener and share of the Postgres connections,
   plus C threads for bcrypt. *)
let getenv k default = match Sys.getenv_opt k with Some v when v <> "" -> v | _ -> default
let getenv_int k default = int_of_string (getenv k (string_of_int default))
let queue_depth = 4096

let serve ~host ~port ~db ~pool_size ~secret ~lanes ~workers ~list_fibers domain env : unit =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let app = App.{ pool = Pg.create_pool ~size:pool_size db; secret; lanes } in
  let addr = `Tcp (Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string host), port) in
  let sock = Eio.Net.listen ~sw ~reuse_addr:true ~reuse_port:true ~backlog:65535 net addr in
  let clock = Eio.Stdenv.clock env in
  (* Each lane's fiber lives on one domain, which does its decoding and rendering of shared rows. *)
  let lane home l f =
    if ((home - 1) mod workers) + 1 = domain then Eio.Fiber.fork ~sw (fun () -> Batch.run l ~clock ~url:db f)
  in
  (* The list statements are the slow ones, so they get several fibers, on consecutive domains. Write lanes keep one:
     concurrent batches could lock the same rows in different orders. *)
  let list_lane home l f =
    for i = 0 to list_fibers - 1 do
      lane (home + i) l f
    done
  in
  Option.iter
    (fun (l : App.lanes) ->
      lane 1 l.tags_lane App.run_tags;
      list_lane 2 l.global_lane (App.run_pages App.global_batch);
      list_lane 3 l.feed_lane App.run_feed;
      list_lane 5 l.tag_lane (App.run_pages App.tag_batch);
      list_lane 6 l.author_lane (App.run_pages App.author_batch);
      list_lane 1 l.favorited_lane (App.run_pages App.favorited_batch);
      lane 2 l.article_lane (App.run_pages App.article_batch);
      lane 5 l.comments_lane App.run_comments;
      lane 4 l.profile_lane App.run_profiles;
      lane 5 l.user_lane App.run_users;
      lane 6 l.favorite_lane (App.run_favorites App.favorite_batch);
      lane 1 l.unfavorite_lane (App.run_favorites App.unfavorite_batch);
      lane 2 l.add_comment_lane App.run_add_comments;
      lane 4 l.follow_lane (App.run_follows App.follow_batch);
      lane 5 l.unfollow_lane (App.run_follows App.unfollow_batch))
    lanes;
  Eio.Fiber.fork ~sw (fun () ->
      Stats.reporter ~clock ~domain ~pool_free:(fun () -> Eio.Stream.length app.pool.q));
  let on_error e = Printf.eprintf "connection error: %s\n%!" (Printexc.to_string e) in
  while true do
    Eio.Net.accept_fork ~sw sock ~on_error (fun flow _ ->
        (match Eio_unix.Resource.fd_opt flow with
        | Some fd -> Eio_unix.Fd.use_exn "nodelay" fd (fun fd -> Unix.setsockopt fd Unix.TCP_NODELAY true)
        | None -> ());
        Http.serve flow (App.handle app))
  done

(* The box doesn't restart anything: a dead worker takes the whole server down, visibly. *)
let die e =
  Printf.eprintf "worker failed: %s\n%!" (Printexc.to_string e);
  Unix._exit 1

let () =
  let host = getenv "HOST" "127.0.0.1" in
  let port = getenv_int "PORT" 3000 in
  let db = Sys.getenv "DATABASE_URL" in
  let secret = Sys.getenv "JWT_SECRET" in
  let workers = max 1 (getenv_int "WORKERS" 6) in
  let pool_size = max 1 (getenv_int "PG_CONNECTIONS" 30 / workers) in
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let window = float (getenv_int "BATCH_WINDOW_MS" 150) /. 1000. in
  let lanes =
    if window <= 0. then None
    else
      let lane name = Batch.create ~name ~window in
      Some
        App.
          {
            tags_lane = lane "tags";
            global_lane = lane "global";
            feed_lane = lane "feed";
            tag_lane = lane "tag";
            author_lane = lane "author";
            favorited_lane = lane "favorited";
            article_lane = lane "article";
            comments_lane = lane "comments";
            profile_lane = lane "profile";
            user_lane = lane "user";
            favorite_lane = lane "favorite";
            unfavorite_lane = lane "unfavorite";
            add_comment_lane = lane "add_comment";
            follow_lane = lane "follow";
            unfollow_lane = lane "unfollow";
          }
  in
  let list_fibers = max 1 (getenv_int "LIST_LANE_FIBERS" 2) in
  let serve = serve ~host ~port ~db ~pool_size ~secret ~lanes ~workers ~list_fibers in
  try
    Bcrypt.start
      ~threads:(max 1 (getenv_int "BCRYPT_THREADS" 2))
      ~wait_ms:(getenv_int "BCRYPT_WAIT_MS" 400)
      ~nice:(getenv_int "BCRYPT_NICE" 19);
    Eio_linux.run ~queue_depth @@ fun env ->
    for d = 2 to workers do
      ignore (Domain.spawn (fun () -> try Eio_linux.run ~queue_depth (serve d) with e -> die e))
    done;
    serve 1 env
  with e -> die e
