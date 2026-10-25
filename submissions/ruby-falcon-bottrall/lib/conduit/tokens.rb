require "openssl"
require "json"

module Conduit
  # The API's HS256 JWTs: {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Every request verifies its
  # token's signature and expiry afresh; nothing is remembered between requests.
  class Tokens
    TTL = 30 * 24 * 60 * 60
    USER_ID = /\A[1-9][0-9]{0,17}\z/

    # Keying an HMAC is most of its cost (OpenSSL 3 looks the algorithm up each time), so key one up front
    # and sign with copies of it: 1 µs a token instead of 5.
    def initialize(secret:)
      @keyed = OpenSSL::HMAC.new(secret, "SHA256").freeze
    end

    # Unpadded base64url, the encoding of each of a JWT's three parts.
    def self.encode(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    # Decoded bytes, or nil if `text` isn't base64url.
    def self.decode(text)
      padded = text.tr("-_", "+/") + ("=" * (-text.bytesize % 4))
      padded.unpack1("m0")
    rescue ArgumentError
      nil
    end

    HEADER = encode('{"alg":"HS256","typ":"JWT"}').freeze

    def issue(user_id, now: Time.now.to_i)
      signed = "#{HEADER}.#{Tokens.encode(JSON.generate({ sub: user_id.to_s, iat: now, exp: now + TTL }))}"
      "#{signed}.#{signature(signed)}"
    end

    # The user id the token was issued for, or nil unless it's a well-formed, correctly signed, unexpired HS256
    # token. The signature is compared in its canonical encoding, so one re-encoded with stray bits doesn't verify.
    def user_id(token, now: Time.now.to_i)
      header, payload, sig = token.split(".", -1)
      return unless sig && token.count(".") == 2 && hs256?(header)
      return unless OpenSSL.fixed_length_secure_compare(signature("#{header}.#{payload}"), sig)

      claims = json(payload)
      sub, exp = claims["sub"], claims["exp"] if claims.is_a?(Hash)
      sub.to_i if exp.is_a?(Numeric) && exp > now && sub.is_a?(String) && sub.match?(USER_ID)
    end

    private

    def signature(signed) = Tokens.encode(@keyed.dup.update(signed).digest)

    # Tokens this server issued share one header, so there's no need to decode it.
    def hs256?(header)
      return true if header == HEADER

      fields = json(header)
      fields.is_a?(Hash) && fields["alg"] == "HS256"
    end

    # The JSON in a token part, or nil if it isn't base64url-encoded JSON.
    def json(part)
      bytes = Tokens.decode(part)
      JSON.parse(bytes) if bytes
    rescue JSON::ParserError
      nil
    end
  end
end
