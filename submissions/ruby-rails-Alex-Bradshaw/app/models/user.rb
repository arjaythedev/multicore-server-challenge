class User < ApplicationRecord
  BCRYPT_COST = 10       # rule 7: every password is hashed with bcrypt cost 10
  MAX_PASSWORD_BYTES = 72 # bcrypt ignores anything past 72 bytes, so the spec rejects longer passwords

  def self.hash_password(password)
    BCrypt::Password.create(password, cost: BCRYPT_COST)
  end

  # Rule 7: every login verifies against the stored bcrypt hash.
  def password_matches?(password)
    BCrypt::Password.new(password_hash).is_password?(password)
  end

  # The Profile object from SPEC.md: username, bio, image, and whether the viewer follows this user.
  def as_profile_json(following)
    { username: username, bio: bio, image: image, following: following }
  end

  # The User object from SPEC.md: exactly email, token, username, bio, image.
  def as_auth_json(token)
    { email: email, token: token, username: username, bio: bio, image: image }
  end
end
