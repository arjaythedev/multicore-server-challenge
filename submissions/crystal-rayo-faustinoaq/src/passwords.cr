require "rayo/bcrypt"

module Passwords
  class_property pool : Rayo::Bcrypt::Pool? = nil

  def self.start
    self.pool = Rayo::Bcrypt::Pool.new(
      threads: ENV.fetch("BCRYPT_THREADS", "1").to_i, capacity: 1024,
      cost: 10, window_ms: ENV.fetch("BCRYPT_WINDOW_MS", "200").to_i.clamp(0, 400))
    pool.not_nil!.attach
  end

  def self.acquire(ctx, password : Bytes, operation : Int32, hash : Bytes? = nil, user_id = 0_i64)
    if password.size > 72 || password.includes?(0_u8)
      return Conduit.error(ctx, operation == 1 ? 401 : 422)
    end
    case operation
    when 0
      pool.not_nil!.hash(ctx, password) do |result, ctx|
        result.ok? ? Conduit.register(ctx, result.hash) : Conduit.error(ctx, 422)
      end
    when 1
      Conduit.state(ctx).viewer = user_id
      pool.not_nil!.verify(ctx, password, hash.not_nil!) do |result, ctx|
        if result.ok?
          Conduit.state(ctx).fresh = true
          ctx.db.query(Sql::USER_BY_ID, Conduit.state(ctx).viewer) { |res, ctx| Conduit.user(ctx, res) }
        else
          Conduit.error(ctx, 401)
        end
      end
    when 2
      pool.not_nil!.hash(ctx, password) do |result, ctx|
        result.ok? ? Conduit.update_user(ctx, result.hash) : Conduit.error(ctx, 422)
      end
    end
  end
end
