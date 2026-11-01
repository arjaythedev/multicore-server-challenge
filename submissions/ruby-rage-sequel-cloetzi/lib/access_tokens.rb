require "jwt"

# Issues and verifies the API's HS256 JWTs: {"sub": "<user id>", "iat": now, "exp": now + 30 days}.
# Every request verifies its token afresh; nothing is cached.
AccessTokens = Data.define(:secret)

class AccessTokens
  TTL = 30 * 24 * 60 * 60

  def issue(user_id, now: Time.now.to_i)
    JWT.encode({ sub: user_id.to_s, iat: now, exp: now + TTL }, secret, "HS256")
  end

  # The user id the token was issued for, or nil unless it is a well-formed, unexpired HS256 token.
  def user_id(token)
    payload, = JWT.decode(token, secret, true, algorithm: "HS256", required_claims: %w[exp sub])
    sub = payload["sub"]
    sub.to_i if sub.is_a?(String) && sub.match?(/\A[1-9][0-9]{0,17}\z/)
  rescue JWT::DecodeError
    nil
  end
end
