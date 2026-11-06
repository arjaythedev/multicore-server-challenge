(* The hot responses are written directly, byte-identical to what Yojson makes of the derived types. Requests and every
   other response still go through ppx_deriving_yojson. *)
let hex = "0123456789abcdef"

let add_string b s =
  Buffer.add_char b '"';
  let n = String.length s in
  let start = ref 0 in
  let flush i = if i > !start then Buffer.add_substring b s !start (i - !start) in
  for i = 0 to n - 1 do
    let c = String.unsafe_get s i in
    if c < ' ' || c = '"' || c = '\\' || c = '\127' then begin
      flush i;
      start := i + 1;
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | _ ->
          Buffer.add_string b "\\u00";
          Buffer.add_char b hex.[Char.code c lsr 4];
          Buffer.add_char b hex.[Char.code c land 15]
    end
  done;
  flush n;
  Buffer.add_char b '"'

let add_option b = function Some s -> add_string b s | None -> Buffer.add_string b "null"
let add_bool b v = Buffer.add_string b (if v then "true" else "false")
