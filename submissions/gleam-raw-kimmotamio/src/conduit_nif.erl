%% Loads priv/conduit_nif.so (built by build.sh): JSON string escaping and timestamp formatting in C.
-module(conduit_nif).
-export([json_string/1, rfc3339/1, json_rfc3339/1]).
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
