# Passwords are bcrypt cost 10, as the seed data's are (BCrypt's own default is 12).
BCrypt::Engine.cost = 10

ACCESS_TOKENS = AccessTokens.new(secret: ENV.fetch("JWT_SECRET"))
