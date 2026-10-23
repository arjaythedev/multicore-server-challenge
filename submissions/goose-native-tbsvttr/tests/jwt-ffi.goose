// Integration check only: verifies actual Goose slice/builder FFI and
// copying an initialized read-only global key into independent workers.
import std;
import jwt;

var test_key: u8[>..] = [];

thread_fn check_worker(id: i64) {
    for turn in 100 {
        var token: u8[>..] = [];
        assert(jwt_issue(token, test_key, id + 1, 1000 + turn));
        assert(jwt_verify(test_key, token, (1000 + turn) * 1000 + 1) == id + 1);
        assert(jwt_verify(test_key, token, (1000 + turn + JWT_TTL) * 1000) == 0);
        assert(jwt_verify("different key", token, (1000 + turn) * 1000 + 1) == 0);
        token[token.len - 1] = if token[token.len - 1] == 'A' { 'B' } else { 'A' };
        assert(jwt_verify(test_key, token, (1000 + turn) * 1000 + 1) == 0);
    }
}

fn main() {
    test_key.append("our initialized JWT key copied into each Goose worker");
    var ids: i64[>..] = [];
    for id in 8 { ids.push(thread_spawn(check_worker, id)); }
    for id in ids { thread_wait(id); }
    print("PASS: 4000 Goose JWT assertions across 8 workers, including initialized global key, expiration, wrong key and tampering");
}
