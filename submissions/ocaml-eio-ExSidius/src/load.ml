(* How long batch lanes collect, from how busy the CPUs this process may run on are. Waiting makes batches bigger, and
   that saves CPU, which is only worth its latency when CPU is short. So the window follows the load: [low] below
   [busy_low], [high] above [busy_high], linear in between. A longer window lowers the load, so this settles instead of
   running away. Niced time counts as busy: it's bcrypt, which has to happen anyway. *)
let period = 0.2
let current = Atomic.make 0.
let window () = Atomic.get current

let range_of s =
  match String.split_on_char '-' s with
  | [ a ] -> let a = int_of_string a in (a, a)
  | [ a; b ] -> (int_of_string a, int_of_string b)
  | _ -> failwith "cpu range"

let with_lines path f =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> f ic)

(* The list in /proc/self/status, so that a process pinned with taskset watches its own CPUs. None means all of them. *)
let allowed_cpus () =
  try
    with_lines "/proc/self/status" (fun ic ->
        let rec find () =
          let line = input_line ic in
          match String.split_on_char ':' line with
          | [ "Cpus_allowed_list"; v ] -> List.map range_of (String.split_on_char ',' (String.trim v))
          | _ -> find ()
        in
        Some (find ()))
  with Sys_error _ | End_of_file | Failure _ | Invalid_argument _ -> None

(* (busy, total) ticks since boot over the allowed CPUs. *)
let read_ticks allowed =
  with_lines "/proc/stat" (fun ic ->
      let wanted cpu =
        match allowed with None -> true | Some l -> List.exists (fun (a, b) -> cpu >= a && cpu <= b) l
      in
      let busy = ref 0 and total = ref 0 in
      let rec go () =
        match input_line ic with
        | exception End_of_file -> ()
        | line when String.length line >= 3 && String.sub line 0 3 = "cpu" ->
            (match
               Scanf.sscanf line "cpu%d %d %d %d %d %d %d %d %d" (fun cpu user nice sys idle iowait irq soft steal ->
                   (cpu, user + nice + sys + irq + soft + steal, idle + iowait))
             with
            | cpu, b, free when wanted cpu ->
                busy := !busy + b;
                total := !total + b + free
            | _ -> ()
            | exception (Scanf.Scan_failure _ | Failure _ | End_of_file) -> () (* the "cpu " summary line *));
            go ()
        | _ -> ()
      in
      go ();
      (!busy, !total))

let window_for ~low ~high ~busy_low ~busy_high busy =
  if high <= low then high
  else low +. ((high -. low) *. Float.min 1. (Float.max 0. ((busy -. busy_low) /. (busy_high -. busy_low))))

(* Runs for the life of the server, on one domain. Without /proc/stat the window stays at [high]. *)
let run ~clock ~low ~high ~busy_low ~busy_high =
  let allowed = allowed_cpus () in
  let read () = try Some (read_ticks allowed) with Sys_error _ -> None in
  let rec loop last busy =
    Eio.Time.sleep clock period;
    match (last, read ()) with
    | Some (b0, t0), (Some (b1, t1) as now) when t1 > t0 ->
        let busy = (busy +. (float (b1 - b0) /. float (t1 - t0))) /. 2. in
        Atomic.set current (window_for ~low ~high ~busy_low ~busy_high busy);
        loop now busy
    | Some _, (Some _ as now) -> loop now busy
    | _, None ->
        Atomic.set current high;
        loop None busy
    | None, now -> loop now busy
  in
  loop (read ()) 0.
