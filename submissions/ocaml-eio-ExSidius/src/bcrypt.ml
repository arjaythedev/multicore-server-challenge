(* bcrypt cost 10 on C threads that hash up to 5 passwords at once (bcrypt_stubs.c). The calling fiber suspends on the
   job's eventfd, so its domain keeps serving other connections. *)
external start_stub : int -> int -> int -> unit = "conduit_bcrypt_start"
external submit : string -> string -> int = "conduit_bcrypt_submit"
external job_fd : int -> Unix.file_descr = "conduit_bcrypt_fd" [@@noalloc]
external result : int -> string = "conduit_bcrypt_result"
external release : int -> unit = "conduit_bcrypt_release" [@@noalloc]

let start ~threads ~wait_ms ~nice = start_stub threads wait_ms nice

let run password setting =
  Stats.bcrypt (fun () ->
      let job = submit password setting in
      Fun.protect
        ~finally:(fun () -> release job)
        (fun () ->
          Eio_unix.await_readable (job_fd job);
          result job))

(* C strings stop at NUL, so a password containing one would be silently truncated: it never matches. *)
let verify ~password ~hash =
  (not (String.contains password '\000'))
  && String.length hash > 0
  &&
  let got = run password hash in
  String.length got = String.length hash && Eqaf.equal got hash

(* None for a password bcrypt can't represent. *)
let hash password =
  if String.length password > 72 || String.contains password '\000' then None
  else
    match run password "" with
    | "" -> failwith "bcrypt: hash failed"
    | h -> Some h
