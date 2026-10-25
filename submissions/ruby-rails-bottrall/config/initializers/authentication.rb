require "access_tokens"

# Passwords are bcrypt cost 10, as the seed data's are (BCrypt's own default is 12).
BCrypt::Engine.cost = 10

Rails.application.config.x.access_tokens = AccessTokens.new(secret: Rails.application.config.x.jwt_secret)
