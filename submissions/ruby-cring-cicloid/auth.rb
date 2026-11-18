# frozen_string_literal: true

require "json"
require "rbnacl"
require_relative "ext/bcrypt/bcrypt_lanes"
require_relative "ext/jwt/fast_jwt"

# libsodium's one-shot HMAC-SHA256 and constant-time compare, bound through rbnacl's FFI layer.
module Sodium
  extend RbNaCl::Sodium

  sodium_function :hmac_sha256, :crypto_auth_hmacsha256, %i[pointer pointer ulong_long pointer]
  sodium_function :verify32, :crypto_verify_32, %i[pointer pointer]
end

# bcrypt, cost 10, through BcryptLanes (ext/bcrypt). In the server's workers every hash goes to the
# master's BcryptService, which interleaves the hashes of the whole server; without a service (warm-up,
# tests) a hash runs here, one lane, on a helper thread with the GVL released.
module Bcrypt
  MAX = 72 # bytes bcrypt uses; longer passwords are refused at registration

  class << self
    attr_accessor :client
  end

  # The hash of a new password, or nil when bcrypt can't take it (over 72 bytes, or a NUL byte).
  def self.create(password)
    return nil unless usable?(password)

    compute(password, BcryptLanes.salt(Random.urandom(16)))
  end

  def self.verify(password, hash)
    return false unless usable?(password) && hash.start_with?("$2")

    out = compute(password, hash)
    !out.nil? && Sodium.constant_time_equal?(out, hash)
  end

  def self.usable?(password) = password.bytesize <= MAX && !password.include?("\0")

  def self.compute(password, setting)
    return client.hash(password, setting) if client

    Thread.new { BcryptLanes.run([password], [setting])[0] }.value
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

  # The user id of a valid `Authorization: Token <jwt>` header value, or nil. FastJWT (ext/jwt) does the
  # splitting, decoding and the signature check for tokens with the header this server issues.
  def verify(header)
    claims = FastJWT.claims(header, HEADER, @key)
    claims = slow_claims(header) if claims == false
    return nil unless claims

    claims = JSON.parse(claims)
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

  # Any other header: decoded and checked for "alg": "HS256" here; the claims JSON when the signature holds.
  def slow_claims(header)
    return nil unless header.start_with?(PREFIX)

    token = header.byteslice(6, header.bytesize - 6)
    dot1 = token.index(".") or return nil
    dot2 = token.index(".", dot1 + 1) or return nil
    return nil if token.index(".", dot2 + 1) || !hs256?(token.byteslice(0, dot1))

    signature = unb64(token.byteslice(dot2 + 1, token.bytesize - dot2 - 1))
    return nil unless signature&.bytesize == 32

    input = token.byteslice(0, dot2)
    return nil unless Sodium.verify32(sign(input), signature) # rbnacl turns the 0 return into true

    unb64(token.byteslice(dot1 + 1, dot2 - dot1 - 1))
  end

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
