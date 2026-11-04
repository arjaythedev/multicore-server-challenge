# frozen_string_literal: true

require "json"
require "rbnacl"
require "ffi"

# libsodium's one-shot HMAC-SHA256 and constant-time compare, bound through rbnacl's FFI layer.
module Sodium
  extend RbNaCl::Sodium

  sodium_function :hmac_sha256, :crypto_auth_hmacsha256, %i[pointer pointer ulong_long pointer]
  sodium_function :verify32, :crypto_verify_32, %i[pointer pointer]
end

# bcrypt through libxcrypt (Ubuntu's libcrypt.so.1, the same library `crypt(3)` uses), called with the
# GVL released: a cost-10 hash takes ~40 ms of CPU, and while one runs on a helper thread the event loop
# keeps serving. Hashes are standard `$2b$10$...`; the seed's `$2a$` hashes verify the same way.
module Bcrypt
  extend FFI::Library
  ffi_lib ["libcrypt.so.1", "crypt"]

  DATA_SIZE = 32_768 # sizeof(struct crypt_data) in libxcrypt
  OUTPUT_SIZE = 384 # CRYPT_GENSALT_OUTPUT_SIZE
  COST = 10

  attach_function :crypt_rn, %i[string string pointer int], :pointer, blocking: true
  attach_function :crypt_gensalt_rn, %i[string ulong pointer int pointer int], :pointer

  # Hashes on a fresh thread so the GVL-free crypt call overlaps the event loop. Thread#value waits
  # through the fiber scheduler, so only the calling fiber waits.
  def self.create(password)
    Thread.new(password) do |pw|
      salt = FFI::MemoryPointer.new(:char, OUTPUT_SIZE)
      crypt_gensalt_rn("$2b$", COST, nil, 0, salt, OUTPUT_SIZE).null? and raise "crypt_gensalt failed"
      crypt(pw, salt.read_string)
    end.value
  end

  def self.verify(password, hash)
    return false unless hash.start_with?("$2")

    Thread.new(password, hash) do |pw, h|
      out = crypt(pw, h)
      out.bytesize == h.bytesize && Sodium.constant_time_equal?(out, h)
    end.value
  end

  def self.crypt(password, setting)
    data = FFI::MemoryPointer.new(:char, DATA_SIZE)
    result = crypt_rn(password, setting, data, DATA_SIZE)
    raise "crypt failed" if result.null?

    out = result.read_string
    raise "crypt failed" if out.start_with?("*")

    out
  end
end

module Sodium
  # Constant-time compare for two equal-length strings of any length.
  def self.constant_time_equal?(a, b)
    return false unless a.bytesize == b.bytesize

    diff = 0
    a.each_byte.with_index { |byte, i| diff |= byte ^ b.getbyte(i) }
    diff.zero?
  end
end

# HS256 JWTs: {"sub": "<id>", "iat": now, "exp": now + 30 days}. Every request verifies the signature and
# `exp`; nothing is cached.
class Tokens
  HEADER = ["{\"alg\":\"HS256\",\"typ\":\"JWT\"}"].pack("m0").tr("+/", "-_").delete("=").freeze
  TTL = 30 * 24 * 3600
  DIGITS = /\A[0-9]{1,18}\z/
  PREFIX = "Token "

  def initialize(secret)
    # crypto_auth_hmacsha256 takes a 32-byte key; HMAC zero-pads shorter keys to the block size, so a
    # zero-padded 32-byte key gives the same MAC. Longer secrets would need hashing first.
    raise ArgumentError, "JWT_SECRET longer than 32 bytes is not supported" if secret.bytesize > 32

    @key = secret.b.ljust(32, "\0").freeze
    @mac = String.new("\0" * 32, encoding: Encoding::BINARY)
    @coder = JSON::Coder.new
  end

  def issue(user_id)
    now = Time.now.to_i
    claims = b64(%({"sub":"#{user_id}","iat":#{now},"exp":#{now + TTL}}))
    input = "#{HEADER}.#{claims}"
    "#{input}.#{b64(sign(input))}"
  end

  # The user id of a valid `Authorization: Token <jwt>` header value, or nil.
  def verify(header)
    return nil unless header.start_with?(PREFIX)

    token = header.byteslice(6, header.bytesize - 6)
    dot1 = token.index(".") or return nil
    dot2 = token.index(".", dot1 + 1) or return nil
    return nil if token.index(".", dot2 + 1)

    header_part = token.byteslice(0, dot1)
    return nil unless header_part == HEADER || hs256?(header_part)

    signature = unb64(token.byteslice(dot2 + 1, token.bytesize - dot2 - 1))
    return nil unless signature&.bytesize == 32

    input = token.byteslice(0, dot2)
    return nil unless Sodium.verify32(sign(input), signature) # rbnacl turns the 0 return into true

    claims = JSON.parse(unb64(token.byteslice(dot1 + 1, dot2 - dot1 - 1)) || (return nil))
    return nil unless claims.is_a?(Hash)

    sub = claims["sub"]
    exp = claims["exp"]
    return nil unless sub.is_a?(String) && DIGITS.match?(sub) && exp.is_a?(Numeric) && exp > Time.now.to_i

    id = sub.to_i
    id.positive? ? id : nil
  rescue JSON::ParserError, ArgumentError
    nil
  end

  # The token a request presented (after "Token ").
  def self.token_of(header) = header.byteslice(6, header.bytesize - 6)

  private

  def sign(input)
    Sodium.hmac_sha256(@mac, input, input.bytesize, @key)
    @mac.dup
  end

  def hs256?(part)
    header = JSON.parse(unb64(part) || (return false))
    header.is_a?(Hash) && header["alg"] == "HS256"
  rescue JSON::ParserError
    false
  end

  def b64(data) = [data].pack("m0").tr("+/", "-_").delete("=")

  def unb64(data)
    return nil if data.empty? || !data.match?(/\A[A-Za-z0-9_-]+\z/)

    data.tr("-_", "+/").unpack1("m")
  end
end
