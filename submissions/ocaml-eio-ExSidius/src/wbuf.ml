(* Eio writes Cstructs, and allocating a bigarray per write is expensive. Each domain keeps a free list of scratch
   buffers; a buffer is held only for the duration of one write. *)
let size = 65536
let free : Cstruct.t Stack.t Domain.DLS.key = Domain.DLS.new_key Stack.create

let write flow a b =
  let la = String.length a and lb = String.length b in
  if la + lb > size then Eio.Flow.write flow [ Cstruct.of_string (a ^ b) ]
  else begin
    let stack = Domain.DLS.get free in
    let buf = match Stack.pop_opt stack with Some b -> b | None -> Cstruct.create size in
    Cstruct.blit_from_string a 0 buf 0 la;
    Cstruct.blit_from_string b 0 buf la lb;
    Fun.protect ~finally:(fun () -> Stack.push buf stack)
      (fun () -> Eio.Flow.write flow [ Cstruct.sub buf 0 (la + lb) ])
  end
