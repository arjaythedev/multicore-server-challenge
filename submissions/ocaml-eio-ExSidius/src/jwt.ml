(* HS256 tokens. Every request verifies the signature and exp: nothing is remembered between requests. *)
module H = Digestif.SHA256

let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let b64url_encode s =
  let n = String.length s in
  let out = Buffer.create (((n * 4) + 2) / 3) in
  let c i = Char.code s.[i] in
  let put v = Buffer.add_char out alphabet.[v land 63] in
  let i = ref 0 in
  while !i + 2 < n do
    let v = (c !i lsl 16) lor (c (!i + 1) lsl 8) lor c (!i + 2) in
    put (v lsr 18);
    put (v lsr 12);
    put (v lsr 6);
    put v;
    i := !i + 3
  done;
  (match n - !i with
  | 1 ->
      let v = c !i lsl 16 in
      put (v lsr 18);
      put (v lsr 12)
  | 2 ->
      let v = (c !i lsl 16) lor (c (!i + 1) lsl 8) in
      put (v lsr 18);
      put (v lsr 12);
      put (v lsr 6)
  | _ -> ());
  Buffer.contents out

let b64url_value = function
  | 'A' .. 'Z' as c -> Char.code c - 65
  | 'a' .. 'z' as c -> Char.code c - 71
  | '0' .. '9' as c -> Char.code c + 4
  | '-' -> 62
  | '_' -> 63
  | _ -> -1

let b64url_decode s =
  let out = Buffer.create (String.length s) in
  let acc = ref 0 and bits = ref 0 and ok = ref true in
  String.iter
    (fun ch ->
      let v = b64url_value ch in
      if v < 0 then ok := false
      else begin
        acc := ((!acc lsl 6) lor v) land 0xffffff;
        bits := !bits + 6;
        if !bits >= 8 then begin
          bits := !bits - 8;
          Buffer.add_char out (Char.chr ((!acc lsr !bits) land 255))
        end
      end)
    s;
  if !ok then Some (Buffer.contents out) else None

let signature ~secret msg = b64url_encode (H.to_raw_string (H.hmac_string ~key:secret msg))
let header = b64url_encode {|{"alg":"HS256","typ":"JWT"}|}

let sign ~secret id =
  let now = int_of_float (Unix.time ()) in
  let payload =
    b64url_encode (Printf.sprintf {|{"sub":"%d","iat":%d,"exp":%d}|} id now (now + (30 * 86400)))
  in
  let msg = header ^ "." ^ payload in
  msg ^ "." ^ signature ~secret msg

let json_of_b64 s =
  match b64url_decode s with
  | None -> None
  | Some raw -> ( try Some (Yojson.Safe.from_string raw) with Yojson.Json_error _ -> None)

let number = function `Int n -> Some (float_of_int n) | `Float f -> Some f | _ -> None

(* The user id when the token is valid. *)
let verify ~secret token =
  match String.split_on_char '.' token with
  | [ h; p; s ] when Eqaf.equal s (signature ~secret (h ^ "." ^ p)) -> (
      match (json_of_b64 h, json_of_b64 p) with
      | Some (`Assoc hd), Some (`Assoc claims) when List.assoc_opt "alg" hd = Some (`String "HS256") -> (
          let now = Unix.gettimeofday () in
          let exp = Option.bind (List.assoc_opt "exp" claims) number in
          let nbf = Option.bind (List.assoc_opt "nbf" claims) number in
          match (exp, nbf, List.assoc_opt "sub" claims) with
          | Some exp, nbf, Some (`String sub)
            when exp > now
                 && (match nbf with Some t -> t <= now | None -> true)
                 && sub <> ""
                 && String.for_all (fun c -> c >= '0' && c <= '9') sub -> (
              match int_of_string_opt sub with Some id when id > 0 -> Some id | _ -> None)
          | _ -> None)
      | _ -> None)
  | _ -> None
