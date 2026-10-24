%% The thin Erlang layer under the Gleam code: sockets, crypto, environment, process tricks (hibernate,
%% persistent_term, atomics), try/catch, and the decode_packet request parser the NIF replaced, kept as the
%% reference the tests hold the NIF to.
-module(conduit_ffi).
-export([getenv/1, now_seconds/0, monotonic_ms/0, hmac_sha256/2, sha256/1, md5_hex/1, hash_equals/2, pbkdf2_sha256/3, random_bytes/1,
         xor_bytes/2, has_nul/1, has_quote_or_backslash/1, needs_decoding/2, is_utf8/1, base64url_encode/1, base64url_decode/1,
         listen/2, accept/1, connect/3, recv/1, recv_timeout/2, send/2, send_nosuspend/2, close/1, parse_request_ref/1, spawn_connection/2,
         hibernate_http/3, heap_words/0, mailbox_len/0, safe/1, log/1,
         pool_init/3, pick_read/1, pick_write/0, sleep/1, stat_add/2, stats/0,
         split_segments/1, split_target/1, bcrypt_init/1, bcrypt_collector/0]).

%% ---------------------------------------------------------------- misc

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        V -> {ok, unicode:characters_to_binary(V)}
    end.

now_seconds() -> erlang:system_time(second).
monotonic_ms() -> erlang:monotonic_time(millisecond).

sleep(Ms) -> timer:sleep(Ms), nil.

log(Msg) -> io:format("~s~n", [Msg]), nil.

%% ---------------------------------------------------------------- crypto

hmac_sha256(Key, Data) -> crypto:mac(hmac, sha256, Key, Data).
sha256(Data) -> crypto:hash(sha256, Data).
md5_hex(Data) -> binary:encode_hex(crypto:hash(md5, Data), lowercase).
hash_equals(A, B) when byte_size(A) =:= byte_size(B) -> crypto:hash_equals(A, B);
hash_equals(_, _) -> false.
pbkdf2_sha256(Password, Salt, Iterations) -> crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32).
random_bytes(N) -> crypto:strong_rand_bytes(N).
xor_bytes(A, B) -> crypto:exor(A, B).

has_nul(Bin) -> binary:match(Bin, <<0>>) =/= nomatch.

has_quote_or_backslash(Bin) -> binary:match(Bin, [<<$">>, <<$\\>>]) =/= nomatch.

%% Whether percent-decoding has anything to do (`+` counts in query strings).
needs_decoding(Bin, true) -> binary:match(Bin, [<<$%>>, <<$+>>]) =/= nomatch;
needs_decoding(Bin, false) -> binary:match(Bin, <<$%>>) =/= nomatch.

is_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    end.

base64url_encode(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

base64url_decode(Bin) ->
    try {ok, base64:decode(Bin, #{mode => urlsafe, padding => false})}
    catch _:_ -> {error, nil}
    end.

split_segments(Path) -> binary:split(Path, <<"/">>, [global]).

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [P, Q] -> {P, Q};
        [P] -> {P, <<>>}
    end.

%% ---------------------------------------------------------------- sockets

listen(Host, Port) ->
    Ip = case inet:parse_address(binary_to_list(Host)) of
        {ok, I} -> I;
        _ -> {ok, I} = inet:getaddr(binary_to_list(Host), inet), I
    end,
    case gen_tcp:listen(Port, [binary, {ip, Ip}, {packet, raw}, {active, true}, {reuseaddr, true},
                               {backlog, 65535}, {nodelay, true}, {send_timeout, 30000},
                               {send_timeout_close, true}]) of
        {ok, L} -> {ok, L};
        {error, R} -> {error, atom_to_binary(R)}
    end.

accept(L) ->
    case gen_tcp:accept(L) of
        {ok, S} -> {ok, S};
        {error, R} -> {error, atom_to_binary(R)}
    end.

%% Postgres side: active socket (the backend only ever sends in reply to this process, so no flow control is
%% needed, and a message per read beats a port_control round trip per read), large buffers.
connect(Host, Port, Timeout) ->
    H = binary_to_list(Host),
    case gen_tcp:connect(H, Port, [binary, {packet, raw}, {active, true}, {nodelay, true},
                                   {buffer, 1048576}, {recbuf, 1048576}, {sndbuf, 262144}], Timeout) of
        {ok, S} -> {ok, S};
        {error, R} -> {error, atom_to_binary(R)}
    end.

%% Active-mode receive for an HTTP connection.
recv(Sock) ->
    receive
        {tcp, Sock, Data} -> {ok, Data};
        {tcp_closed, Sock} -> {error, nil};
        {tcp_error, Sock, _} -> {error, nil}
    end.

%% Active-mode receive with a timeout, for the Postgres socket. Requests queued in the same mailbox are left alone.
recv_timeout(Sock, Timeout) ->
    receive
        {tcp, Sock, Data} -> {ok, Data};
        {tcp_closed, Sock} -> {error, nil};
        {tcp_error, Sock, _} -> {error, nil}
    after Timeout -> {error, nil}
    end.

%% prim_inet:send is what gen_tcp:send comes down to for inet-driver sockets, minus a lookup per call.
send(Sock, IoData) ->
    case prim_inet:send(Sock, IoData, []) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% A write that never waits for the client, for a shared process. The driver answers a write into an empty queue
%% at once (whatever the kernel did not take stays queued and is flushed as the client reads), but a write into a
%% non-empty queue may be held until the queue drains; so a socket whose previous response has not drained yet is
%% reported `busy` and the response is left to the socket's owner, which blocks on it like any slow client's
%% process would. That keeps the back-pressure of one blocked process per slow client and bounds the memory a
%% client that stopped reading can hold here to one response.
send_nosuspend(Sock, IoData) ->
    case erlang:port_info(Sock, queue_size) of
        {queue_size, 0} ->
            case prim_inet:send(Sock, IoData, [nosuspend]) of
                ok -> sent;
                {error, busy} -> busy;
                {error, _} -> gone
            end;
        {queue_size, _} -> busy;
        undefined -> gone
    end.

%% A connection process. Its heap starts at MinHeap words so the first requests do not grow it in steps (each
%% step is a collection); it hibernates only when a request grew it past HIB_WORDS.
spawn_connection(Fun, MinHeap) ->
    erlang:spawn_opt(Fun, [{min_heap_size, MinHeap}]),
    nil.

close(Sock) -> gen_tcp:close(Sock), nil.

%% ---------------------------------------------------------------- HTTP request parsing (reference)

-define(DECODE_OPTS, [{packet_size, 16384}, {line_length, 16384}]).

%% {request, Method, Target, Authorization, Body, Rest, Close} | more | bad: the decode_packet parser that served
%% until conduit_nif:parse_request/1 took over; the tests compare the two.
parse_request_ref(Buf) ->
    case parse_request_old(Buf) of
        {request, M, T, A, B, R, C} -> {ref_request, M, T, A, B, R, C};
        more -> ref_more;
        bad -> ref_bad
    end.

parse_request_old(Buf) ->
    case erlang:decode_packet(http_bin, Buf, ?DECODE_OPTS) of
        {ok, {http_request, Method, {abs_path, Target}, _}, Rest} ->
            case is_utf8(Target) of
                true -> headers(Rest, method(Method), Target, <<>>, 0, false, false);
                false -> bad
            end;
        {ok, {http_request, _, _, _}, _} -> bad;
        {ok, {http_error, _}, _} -> bad;
        {ok, {http_response, _, _, _}, _} -> bad;
        {more, _} -> more;
        {error, _} -> bad
    end.

headers(Buf, M, T, Auth, CL, Close, Chunked) ->
    case erlang:decode_packet(httph_bin, Buf, ?DECODE_OPTS) of
        {ok, {http_header, _, 'Authorization', _, V}, Rest} ->
            headers(Rest, M, T, V, CL, Close, Chunked);
        {ok, {http_header, _, 'Content-Length', _, V}, Rest} ->
            try binary_to_integer(V) of
                N when N >= 0, N =< 1048576 -> headers(Rest, M, T, Auth, N, Close, Chunked);
                _ -> bad
            catch _:_ -> bad
            end;
        {ok, {http_header, _, 'Connection', _, V}, Rest} ->
            headers(Rest, M, T, Auth, CL, string:lowercase(V) =:= <<"close">>, Chunked);
        {ok, {http_header, _, 'Transfer-Encoding', _, _}, Rest} ->
            headers(Rest, M, T, Auth, CL, Close, true);
        {ok, {http_header, _, _, _, _}, Rest} ->
            headers(Rest, M, T, Auth, CL, Close, Chunked);
        {ok, http_eoh, Rest} ->
            case Chunked of
                true -> bad;
                false ->
                    case Rest of
                        <<Body:CL/binary, Rest2/binary>> -> {request, M, T, Auth, Body, Rest2, Close};
                        _ -> more
                    end
            end;
        {ok, {http_error, _}, _} -> bad;
        {more, _} -> more;
        {error, _} -> bad
    end.

method(M) when is_atom(M) -> atom_to_binary(M);
method(M) when is_binary(M) -> M.

%% ---------------------------------------------------------------- processes

%% Drops the stack and compacts the heap, then waits for the next socket message in conduit@http:loop/2.
hibernate_http(Sock, Buf, Ctx) -> erlang:hibernate(conduit@http, loop, [Sock, Buf, Ctx]).

heap_words() ->
    {total_heap_size, W} = erlang:process_info(self(), total_heap_size),
    W.

mailbox_len() ->
    {message_queue_len, N} = erlang:process_info(self(), message_queue_len),
    N.

safe(Fun) ->
    try {ok, Fun()}
    catch Class:Reason:Stack ->
        io:format("handler crashed: ~p~n", [{Class, Reason, Stack}]),
        {error, nil}
    end.

%% ---------------------------------------------------------------- connection pools

%% The read connections are split into groups by statement kind (conduit@sql:read_group/1), each group chosen
%% round-robin through its own atomics counter.
pool_init(Reads, Writes, Weights) ->
    Groups = assign(Reads, Weights),
    persistent_term:put({?MODULE, reads}, list_to_tuple([list_to_tuple(G) || G <- Groups])),
    persistent_term:put({?MODULE, writes}, list_to_tuple(Writes)),
    persistent_term:put({?MODULE, counters}, atomics:new(length(Weights) + 1, [])),
    nil.

%% Greedy proportional fill: each connection goes to the group furthest behind its weight share, so any number
%% of connections works. A group left with no connection of its own uses all of them.
assign(Reads, Weights) ->
    N = length(Weights),
    Assigned = assign_loop(Reads, Weights, lists:duplicate(N, 0), []),
    [case [R || {R, G} <- Assigned, G =:= I] of [] -> Reads; L -> L end || I <- lists:seq(1, N)].

assign_loop([], _, _, Acc) -> lists:reverse(Acc);
assign_loop([R | Rest], Weights, Counts, Acc) ->
    {_, Best} = lists:min([{(C + 1) / W, I} || {I, {C, W}} <- lists:enumerate(lists:zip(Counts, Weights))]),
    Counts2 = [case I of Best -> C + 1; _ -> C end || {I, C} <- lists:enumerate(Counts)],
    assign_loop(Rest, Weights, Counts2, [{R, Best} | Acc]).

pick_read(Group) ->
    T = element(Group + 1, persistent_term:get({?MODULE, reads})),
    pick(T, Group + 2).

pick_write() -> pick(persistent_term:get({?MODULE, writes}), 1).

pick(T, Ix) ->
    N = atomics:add_get(persistent_term:get({?MODULE, counters}), Ix, 1),
    element((N rem tuple_size(T)) + 1, T).

%% ---------------------------------------------------------------- bcrypt collector registry

bcrypt_init(Subject) -> persistent_term:put({?MODULE, bcrypt}, Subject), nil.
bcrypt_collector() -> persistent_term:get({?MODULE, bcrypt}).

%% ---------------------------------------------------------------- counters (optional STATS=1 logging)

stat_add(Ix, N) ->
    counters:add(stat_ref(), Ix, N),
    nil.

stats() ->
    R = stat_ref(),
    [counters:get(R, I) || I <- lists:seq(1, 4)].

stat_ref() ->
    case persistent_term:get({?MODULE, stats}, undefined) of
        undefined ->
            R = counters:new(4, [write_concurrency]),
            persistent_term:put({?MODULE, stats}, R),
            R;
        R -> R
    end.
