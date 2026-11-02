(* Optional per-domain telemetry: with CONDUIT_STATS=1 each domain prints one line per second to stderr. Off by
   default, when the only cost is testing [enabled]. Local diagnostics only: nothing here affects responses. *)
let enabled = Sys.getenv_opt "CONDUIT_STATS" = Some "1"
let now = Unix.gettimeofday

external bcrypt_hashes : unit -> int = "conduit_bcrypt_hashes" [@@noalloc]
external bcrypt_batches : unit -> int = "conduit_bcrypt_batches" [@@noalloc]

type t = {
  mutable conns : int;
  mutable requests : int;
  mutable errors : int; (* 5xx *)
  mutable pool_waiting : int;
  mutable pool_takes : int;
  mutable pool_wait : float;
  mutable pool_wait_max : float;
  mutable pg_calls : int;
  mutable pg_time : float;
  mutable handler_time : float;
  mutable handler_max : float;
  mutable bcrypt_calls : int;
  mutable bcrypt_time : float;
  mutable lag_max : float;
  mutable lag_total : float;
}

let key =
  Domain.DLS.new_key (fun () ->
      {
        conns = 0; requests = 0; errors = 0; pool_waiting = 0; pool_takes = 0; pool_wait = 0.; pool_wait_max = 0.;
        pg_calls = 0; pg_time = 0.; handler_time = 0.; handler_max = 0.; bcrypt_calls = 0; bcrypt_time = 0.;
        lag_max = 0.; lag_total = 0.;
      })

let get () = Domain.DLS.get key

let pool_take take =
  if not enabled then take ()
  else begin
    let s = get () in
    let t0 = now () in
    s.pool_waiting <- s.pool_waiting + 1;
    let v = take () in
    let d = now () -. t0 in
    s.pool_waiting <- s.pool_waiting - 1;
    s.pool_takes <- s.pool_takes + 1;
    s.pool_wait <- s.pool_wait +. d;
    if d > s.pool_wait_max then s.pool_wait_max <- d;
    v
  end

let pg f =
  if not enabled then f ()
  else begin
    let s = get () in
    let t0 = now () in
    Fun.protect f ~finally:(fun () ->
        s.pg_calls <- s.pg_calls + 1;
        s.pg_time <- s.pg_time +. (now () -. t0))
  end

let bcrypt f =
  if not enabled then f ()
  else begin
    let s = get () in
    let t0 = now () in
    Fun.protect f ~finally:(fun () ->
        s.bcrypt_calls <- s.bcrypt_calls + 1;
        s.bcrypt_time <- s.bcrypt_time +. (now () -. t0))
  end

let connection f =
  if not enabled then f ()
  else begin
    let s = get () in
    s.conns <- s.conns + 1;
    Fun.protect f ~finally:(fun () -> s.conns <- s.conns - 1)
  end

let handler status_of f =
  if not enabled then f ()
  else begin
    let s = get () in
    let t0 = now () in
    let r = f () in
    let d = now () -. t0 in
    s.requests <- s.requests + 1;
    if status_of r >= 500 then s.errors <- s.errors + 1;
    s.handler_time <- s.handler_time +. d;
    if d > s.handler_max then s.handler_max <- d;
    r
  end

let ms x = x *. 1000.

(* Runs as a fiber in each domain. A sleep that overshoots shows how long this event loop was stalled. *)
let reporter ~clock ~domain ~pool_free =
  if enabled then begin
    let s = get () in
    let tick = 0.05 in
    let last = ref (now ()) and gc0 = ref (Gc.quick_stat ()) in
    while true do
      let t0 = now () in
      Eio.Time.sleep clock tick;
      let lag = now () -. t0 -. tick in
      if lag > s.lag_max then s.lag_max <- lag;
      s.lag_total <- s.lag_total +. lag;
      let t = now () in
      if t -. !last >= 1. then begin
        let gc = Gc.quick_stat () in
        Printf.eprintf
          "stats ts=%.3f domain=%d conns=%d requests=%d errors=%d pool_free=%d pool_waiting=%d pool_takes=%d pool_wait_ms=%.1f pool_wait_max_ms=%.1f pg_calls=%d pg_ms=%.1f handler_ms=%.1f handler_max_ms=%.1f bcrypt_calls=%d bcrypt_ms=%.1f bcrypt_hashes_total=%d bcrypt_batches_total=%d lag_max_ms=%.1f lag_total_ms=%.1f minor_gcs=%d major_gcs=%d minor_mwords=%.1f heap_mwords=%d\n%!"
          t domain s.conns s.requests s.errors (pool_free ()) s.pool_waiting s.pool_takes (ms s.pool_wait)
          (ms s.pool_wait_max) s.pg_calls (ms s.pg_time) (ms s.handler_time) (ms s.handler_max) s.bcrypt_calls
          (ms s.bcrypt_time) (bcrypt_hashes ()) (bcrypt_batches ()) (ms s.lag_max) (ms s.lag_total)
          (gc.minor_collections - !gc0.minor_collections)
          (gc.major_collections - !gc0.major_collections)
          ((gc.minor_words -. !gc0.minor_words) /. 1e6)
          (gc.heap_words / 1_000_000);
        s.requests <- 0; s.errors <- 0; s.pool_takes <- 0; s.pool_wait <- 0.; s.pool_wait_max <- 0.; s.pg_calls <- 0;
        s.pg_time <- 0.; s.handler_time <- 0.; s.handler_max <- 0.; s.bcrypt_calls <- 0; s.bcrypt_time <- 0.;
        s.lag_max <- 0.; s.lag_total <- 0.;
        gc0 := gc;
        last := t
      end
    done
  end
