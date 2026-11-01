class User < Sequel::Model
  one_to_many :articles, key: :author_id
  one_to_many :comments, key: :author_id
  one_to_many :favorites
  one_to_many :follows, key: :follower_id

  # The author's profile columns, for selecting alongside the articles or comments they wrote.
  AUTHOR_COLUMNS = [
    Sequel[:users][:username].as(:author_username), Sequel[:users][:bio].as(:author_bio),
    Sequel[:users][:image].as(:author_image)
  ].freeze

  # The profile at /api/profiles/:username, plus whether the viewer follows them.
  PROFILE = select(:id, :username, :bio, :image, Follow.following(Sequel[:users][:id]))
    .where(username: :$username).prepare(:first, :user_profile)

  def self.profile(viewer_id, username) = PROFILE.call(viewer: viewer_id, username:)

  # The user with this email if the password matches. With no such user it still runs bcrypt once, so a login
  # takes as long whether or not the email exists (as Active Record's authenticate_by does).
  def self.authenticate_by(email:, password:)
    user = first(email:)
    return user if user&.authenticate(password)

    new(password:) unless user
    nil
  end

  # bcrypt only reads the first 72 bytes, so a longer password is refused rather than silently truncated (as
  # has_secure_password does).
  MAX_PASSWORD_BYTES = 72

  # bcrypt takes tens of milliseconds and releases the GVL, so hash on a short-lived thread: only this request
  # waits for it, while the worker's event loop keeps serving everyone else's.
  def password=(plain)
    @password_too_long = plain.bytesize > MAX_PASSWORD_BYTES
    return if @password_too_long

    self.password_hash = Thread.new { BCrypt::Password.create(plain, cost: BCrypt::Engine.cost).to_s }.value
  end

  def authenticate(plain)
    Thread.new { BCrypt::Password.new(password_hash).is_password?(plain) }.value
  end

  # Sets the given fields and saves the ones that changed. False if they don't validate. (Sequel's update
  # returns nil when nothing changed, which is not a failure here.)
  def revise(fields)
    set(fields)
    !modified? || !save_changes.nil?
  end

  def validate
    super
    errors.add(:username, "can't be blank") if username.to_s.empty?
    errors.add(:email, "can't be blank") if email.to_s.empty?
    errors.add(:password, "can't be blank") if password_hash.to_s.empty?
    errors.add(:password, "is too long") if @password_too_long
  end
end
