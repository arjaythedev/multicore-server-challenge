# Issues and verifies the JWTs described in SPEC.md ("Authentication").
module AuthToken
  ALGORITHM = "HS256"
  LIFETIME = 30 * 24 * 60 * 60 # 30 days, in seconds

  module_function

  # Claims are exactly sub (user id as a decimal string), iat and exp.
  def issue(user_id)
    now = Time.now.to_i
    JWT.encode({ sub: user_id.to_s, iat: now, exp: now + LIFETIME }, secret, ALGORITHM)
  end

  # Returns the user id, or nil if the token is invalid: bad signature, expired, missing exp, or not HS256.
  # (Used by the authenticated endpoints you'll build next.)
  def user_id_from(token)
    payload, _header = JWT.decode(token, secret, true, algorithm: ALGORITHM, required_claims: ["exp"])
    Integer(payload["sub"], 10)
  rescue JWT::DecodeError, ArgumentError, TypeError
    nil
  end

  def secret
    # The benchmark box always sets JWT_SECRET; the fallback just saves exporting it for `rails s`.
    ENV.fetch("JWT_SECRET") { Rails.env.production? ? raise(KeyError, "JWT_SECRET is not set") : "multicore-server-challenge" }
  end
end
