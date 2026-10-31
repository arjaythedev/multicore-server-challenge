(* A lane batches requests of one kind from every domain into one execution. Its fibers take turns collecting: one
   takes whatever is waiting, lets more arrive until the oldest request has waited [window] seconds, and runs them as
   one statement on its own connection, while the next fiber starts collecting. So a slow statement doesn't hold up
   the requests behind it unless every fiber is busy. Only requests already queued when the statement starts share
   it, and nothing is kept afterwards. *)
type ('a, 'b) job = { input : 'a; reply : ('b, exn) result Eio.Promise.u; queued : float }

type ('a, 'b) t = {
  q : ('a, 'b) job Eio.Stream.t;
  collecting : Eio.Semaphore.t;
  window : float;
  name : string;
}

let create ~name ~window =
  { q = Eio.Stream.create max_int; collecting = Eio.Semaphore.make 1; window; name }

(* Eio's stream and promises are safe across domains. *)
let submit t input =
  let p, reply = Eio.Promise.create () in
  Eio.Stream.add t.q { input; reply; queued = Unix.gettimeofday () };
  Eio.Promise.await_exn p

let rec drain q acc = match Eio.Stream.take_nonblocking q with Some j -> drain q (j :: acc) | None -> List.rev acc

(* [f] gets the inputs in order and returns one result per input. *)
let run t ~clock ~url f =
  let conn = ref (Pg.connect url) in
  let jobs_n = ref 0 and runs = ref 0 and busy = ref 0. and last = ref (Stats.now ()) in
  while true do
    let jobs =
      Eio.Semaphore.acquire t.collecting;
      Fun.protect
        ~finally:(fun () -> Eio.Semaphore.release t.collecting)
        (fun () ->
          let first = Eio.Stream.take t.q in
          let left = first.queued +. t.window -. Unix.gettimeofday () in
          if left > 0. then Eio.Time.sleep clock left;
          first :: drain t.q [])
    in
    let t0 = if Stats.enabled then Stats.now () else 0. in
    if not !conn.alive then conn := Pg.connect url;
    (match f !conn (List.map (fun j -> j.input) jobs) with
    | results -> List.iter2 (fun j r -> Eio.Promise.resolve_ok j.reply r) jobs results
    | exception ((Eio.Cancel.Cancelled _) as e) -> raise e
    | exception e ->
        (* One bad request (say, invalid UTF-8 in a tag) mustn't fail the others: each gets its own answer. *)
        List.iter
          (fun j ->
            if !conn.busy then Pg.discard !conn;
            if not !conn.alive then conn := Pg.connect url;
            match f !conn [ j.input ] with
            | [ r ] -> Eio.Promise.resolve_ok j.reply r
            | _ -> Eio.Promise.resolve_error j.reply e
            | exception e -> Eio.Promise.resolve_error j.reply e)
          jobs);
    if Stats.enabled then begin
      jobs_n := !jobs_n + List.length jobs;
      incr runs;
      let t1 = Stats.now () in
      busy := !busy +. (t1 -. t0);
      if t1 -. !last >= 1. then begin
        Printf.eprintf "batch lane=%s runs=%d jobs=%d avg=%.1f ms=%.1f\n%!" t.name !runs !jobs_n
          (float !jobs_n /. float !runs)
          (1000. *. !busy /. float !runs);
        jobs_n := 0;
        runs := 0;
        busy := 0.;
        last := t1
      end
    end
  done
