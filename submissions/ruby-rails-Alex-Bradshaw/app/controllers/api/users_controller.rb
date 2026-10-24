class Api::UsersController < ApplicationController
  before_action :require_auth!, only: %i[show update]

  # GET /api/user: the current user
  def show
    user = User.find_by(id: viewer_id)
    # A validly signed token for a user that doesn't exist is still a 401.
    return render_error(:unauthorized, "user not found") unless user

    # The token in the response is the one the request presented, not a new one.
    render json: { user: user.as_auth_json(current_token) }
  end

  # PUT /api/user: update any of email, username, password, bio, image
  def update
    attrs = params[:user]
    return render_error(:unprocessable_content, "user must be an object") unless attrs.is_a?(ActionController::Parameters)

    changes = {}
    UPDATABLE_FIELDS.each do |field|
      value = attrs[field]
      next if value.nil? # absent or null: leave unchanged

      return render_error(:unprocessable_content, "#{field} must be a string") unless value.is_a?(String)
      if value.empty? && NON_EMPTY_FIELDS.include?(field)
        return render_error(:unprocessable_content, "#{field} can't be empty")
      end

      changes[field] = value
    end

    if (password = changes.delete(:password))
      if password.bytesize > User::MAX_PASSWORD_BYTES
        return render_error(:unprocessable_content, "password is longer than 72 bytes")
      end
      changes[:password_hash] = User.hash_password(password)
    end

    user = User.find_by(id: viewer_id)
    return render_error(:unauthorized, "user not found") unless user

    user.update!(changes) # an empty hash is a no-op, so {"user": {}} just returns the user unchanged
    render json: { user: user.as_auth_json(current_token) }
  rescue ActiveRecord::RecordNotUnique
    render_error(:unprocessable_content, "username or email is already taken")
  end

  # POST /api/users: register
  def create
    username, email, password = required_user_strings(:username, :email, :password)
    unless username
      return render_error(:unprocessable_content, "user must be an object with non-empty username, email and password")
    end
    if password.bytesize > User::MAX_PASSWORD_BYTES
      return render_error(:unprocessable_content, "password is longer than 72 bytes")
    end

    # No model validations: the unique indexes on username and email are the check, so we don't pay for
    # extra SELECTs. Any other fields in the body (bio, admin, ...) are deliberately ignored.
    user = User.create!(username: username, email: email, password_hash: User.hash_password(password))
    render json: { user: user.as_auth_json(AuthToken.issue(user.id)) }, status: :created
  rescue ActiveRecord::RecordNotUnique
    render_error(:unprocessable_content, "username or email is already taken")
  end

  # POST /api/users/login
  def login
    email, password = required_user_strings(:email, :password)
    return render_error(:unprocessable_content, "user must be an object with non-empty email and password") unless email

    user = User.find_by(email: email)
    # An unknown email and a wrong password get the same 401, so the response doesn't reveal which emails exist.
    # A password over 72 bytes can never match (register rejects them), so it's a plain 401 too.
    unless user && password.bytesize <= User::MAX_PASSWORD_BYTES && user.password_matches?(password)
      return render_error(:unauthorized, "email or password is invalid")
    end

    render json: { user: user.as_auth_json(AuthToken.issue(user.id)) }
  end

  private

  UPDATABLE_FIELDS = %i[email username password bio image].freeze
  NON_EMPTY_FIELDS = %i[email username password].freeze # bio and image may be set to ""

  # Reads the given keys from the {"user": {...}} wrapper. Returns their values in order if the wrapper is an
  # object and every one is a non-empty string; otherwise nil (which destructures to all-nil in the caller).
  def required_user_strings(*keys)
    attrs = params[:user]
    return unless attrs.is_a?(ActionController::Parameters)

    values = keys.map { |key| attrs[key] }
    values if values.all? { |value| value.is_a?(String) && !value.empty? }
  end
end
