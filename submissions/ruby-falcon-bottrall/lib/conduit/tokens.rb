require "openssl"
require "json"

module Conduit
  class Tokens
    TTL = 30 * 24 * 60 * 60
    USER_ID = /\A[1-9][0-9]{0,17}\z/
    PADDING = ["", nil, "==", "="].freeze

    def self.to_base64url(bytes)
      text = [bytes].pack("m0")
      text.tr!("+/", "-_")
      text.delete!("=")
      text
    end

    def self.from_base64url(text)
      padding = PADDING[text.bytesize % 4] or return
      (text.tr("-_", "+/") << padding).unpack1("m0")
    rescue ArgumentError
      nil
    end

    HEADER = to_base64url('{"alg":"HS256","typ":"JWT"}').freeze

    def initialize(secret:)
      # Keyed once and copied per token: OpenSSL 3 looks the algorithm up on every HMAC.new, which made signing 5x slower.
      @keyed = OpenSSL::HMAC.new(secret, "SHA256").freeze
    end

    def issue(user_id, now: Time.now.to_i)
      signed = "#{HEADER}.#{Tokens.to_base64url(JSON.generate({ sub: user_id.to_s, iat: now, exp: now + TTL }))}"
      "#{signed}.#{signature(signed)}"
    end

    def user_id(token, now: Time.now.to_i)
      header_end = token.index(".") or return
      payload_end = token.index(".", header_end + 1) or return
      return if token.index(".", payload_end + 1) || !hs256?(token, header_end)

      # Compared in canonical encoding, so a signature re-encoded with stray bits doesn't verify.
      expected = signature(token.byteslice(0, payload_end))
      given = token.byteslice(payload_end + 1, token.bytesize)
      # fixed_length_secure_compare raises on a length mismatch.
      return unless given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)

      claims = json(token.byteslice(header_end + 1, payload_end - header_end - 1))
      sub, exp = claims["sub"], claims["exp"] if claims.is_a?(Hash)
      sub.to_i if exp.is_a?(Numeric) && exp > now && sub.is_a?(String) && sub.match?(USER_ID)
    end

    private

    def signature(signed) = Tokens.to_base64url(@keyed.dup.update(signed).digest)

    def hs256?(token, header_end)
      return true if header_end == HEADER.bytesize && token.start_with?(HEADER)

      fields = json(token.byteslice(0, header_end))
      fields.is_a?(Hash) && fields["alg"] == "HS256"
    end

    def json(part)
      bytes = Tokens.from_base64url(part)
      JSON.parse(bytes) if bytes
    rescue JSON::ParserError
      nil
    end
  end
end
