require "bcrypt"

module Conduit
  module Passwords
    module_function

    COST = 10
    MAX_BYTES = 72 # bcrypt ignores anything past this

    def acceptable?(password) = password.bytesize <= MAX_BYTES

    def hash(password) = off_loop { BCrypt::Password.create(password, cost: COST).to_s }

    def verify?(password, stored_hash) = off_loop { BCrypt::Password.new(stored_hash).is_password?(password) }

    # bcrypt releases the GVL, but on the event loop's thread a hash would still stall every request on the worker.
    def off_loop(&) = Thread.new(&).value
  end
end
