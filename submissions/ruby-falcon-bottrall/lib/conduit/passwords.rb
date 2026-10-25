require "bcrypt"

module Conduit
  # bcrypt at cost 10, run on a thread of its own. bcrypt releases the GVL while it hashes, but each worker is
  # one event loop, so hashing on the loop's thread would stall every other request on that worker for ~50 ms.
  # On its own thread only the request that's waiting for it waits.
  module Passwords
    module_function

    COST = 10
    # bcrypt only reads the first 72 bytes, so a longer password can't be stored faithfully.
    MAX_BYTES = 72

    def acceptable?(password) = password.bytesize <= MAX_BYTES

    def hash(password) = off_loop { BCrypt::Password.create(password, cost: COST).to_s }

    def verify?(password, stored_hash) = off_loop { BCrypt::Password.new(stored_hash).is_password?(password) }

    def off_loop(&) = Thread.new(&).value
  end
end
