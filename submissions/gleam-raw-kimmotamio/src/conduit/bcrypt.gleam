//// bcrypt cost 10 through the vendored OpenBSD implementation in native/, running as a dirty-CPU NIF.

@external(erlang, "bcrypt_nif", "hash")
fn do_hash(password: BitArray, rounds: Int) -> BitArray

@external(erlang, "bcrypt_nif", "verify")
fn do_verify(password: BitArray, hash: BitArray) -> Bool

pub const cost = 10

pub fn hash(password: BitArray) -> BitArray {
  do_hash(password, cost)
}

/// bcrypt only looks at the first 72 bytes; longer inputs are cut there like the reference implementations.
pub fn verify(password: BitArray, hash: BitArray) -> Bool {
  let password = case password {
    <<head:bytes-size(72), _:bytes>> -> head
    _ -> password
  }
  do_verify(password, hash)
}
