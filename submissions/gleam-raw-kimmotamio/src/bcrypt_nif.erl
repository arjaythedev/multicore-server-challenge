%% Loads priv/bcrypt_nif.so (built by build.sh) and exposes the two NIFs to Gleam.
-module(bcrypt_nif).
-export([encode_salt/2, hashpw/2, hashpw_lanes/1, gen_salt/1, hash/2, verify/2]).
-on_load(init/0).

init() ->
    Path = filename:join(code:priv_dir(conduit), "bcrypt_nif"),
    erlang:load_nif(Path, 0).

encode_salt(_Raw, _Rounds) ->
    erlang:nif_error(nif_not_loaded).

hashpw(_Password, _Salt) ->
    erlang:nif_error(nif_not_loaded).

%% [{Password, Salt}] (1..4) -> [{ok, Hash} | {error, nil}], the hashes computed in lockstep.
hashpw_lanes(_Jobs) ->
    erlang:nif_error(nif_not_loaded).

gen_salt(Rounds) ->
    encode_salt(crypto:strong_rand_bytes(16), Rounds).

%% Fresh random salt, bcrypt cost `Rounds`.
hash(Password, Rounds) ->
    Salt = encode_salt(crypto:strong_rand_bytes(16), Rounds),
    {ok, Hash} = hashpw(Password, Salt),
    Hash.

%% Constant-time comparison; a malformed stored hash is simply a mismatch.
verify(Password, Hash) ->
    case hashpw(Password, Hash) of
        {ok, Computed} -> crypto:hash_equals(Computed, Hash);
        _ -> false
    end.
