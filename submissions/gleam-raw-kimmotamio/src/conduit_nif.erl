%% Loads priv/conduit_nif.so (built by build.sh): JSON string escaping, timestamp formatting, row decoding and
%% JWT verification in C.
-module(conduit_nif).
-export([json_string/1, rfc3339/1, json_rfc3339/1, decode_row/1, decode_text_array/1, jwt_verify/3, hmac_sha256/2, parse_request/1, json_string_array/1]).
-on_load(init/0).

init() ->
    Path = filename:join(code:priv_dir(conduit), "conduit_nif"),
    erlang:load_nif(Path, 0).

%% A JSON string literal as iodata: [$", Bin, $"] when nothing needs escaping, else one escaped binary.
json_string(_Bin) ->
    erlang:nif_error(nif_not_loaded).

%% Microseconds since 2000-01-01 (Postgres binary timestamptz) -> <<"YYYY-MM-DDTHH:MM:SS.mmmZ">>.
rfc3339(_Micros) ->
    erlang:nif_error(nif_not_loaded).

%% The same, quoted.
json_rfc3339(_Micros) ->
    erlang:nif_error(nif_not_loaded).

%% A DataRow body -> [none | {some, SubBinary}] (Gleam's Option(BitArray)).
decode_row(_Payload) ->
    erlang:nif_error(nif_not_loaded).

%% A one-dimensional text[] in binary format -> [SubBinary]; a NULL element is <<>>.
decode_text_array(_Bin) ->
    erlang:nif_error(nif_not_loaded).

%% HS256 JWT fast path: {fast, Sub} | rejected | general (any shape the fast path does not cover).
jwt_verify(_Token, _Secret, _Now) ->
    erlang:nif_error(nif_not_loaded).

%% The NIF's own HMAC-SHA256, for the tests.
hmac_sha256(_Key, _Data) ->
    erlang:nif_error(nif_not_loaded).

%% The HTTP request head: {request, Method, Segments, Query, Authorization, Body, Rest, Close} | more | bad.
parse_request(_Buf) ->
    erlang:nif_error(nif_not_loaded).

%% A JSON array of strings as one binary: [Bin] -> <<"[\"a\",\"b\"]">>.
json_string_array(_Bins) ->
    erlang:nif_error(nif_not_loaded).
