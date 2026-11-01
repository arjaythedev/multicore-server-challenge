require "rayo/bcrypt"
require "random/secure"
@[Link("crypt")]
lib TestCrypt
  fun crypt_rn(phrase : UInt8*, setting : UInt8*, data : Void*, size : Int32) : UInt8*
  fun crypt_gensalt_rn(prefix : UInt8*, count : LibC::ULong, bytes : UInt8*, n : Int32, output : UInt8*, size : Int32) : UInt8*
end

def check_lanes(engine : Rayo::Bcrypt::Lanes::Engine(N), rounds : Int32) forall N
  passwords = Array(String).new(N) { "" }
  settings = Array(Bytes).new(N) { Bytes.new(64) }
  ptrs = Array(UInt8*).new(N, Pointer(UInt8).null)
  salts = Array(UInt8*).new(N, Pointer(UInt8).null)
  lengths = Array(Int32).new(N, 0)
  output = Bytes.new(N * 61)
  data = Bytes.new(32768)
  seed = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
  rounds.times do |round|
    N.times do |k|
      n = (round * N + k) % 73
      bytes = Random::Secure.random_bytes(n)
      # High-bit $2a$ uses libcrypt in production because its safety-bit extension
      # differs from standard EksBlowfish for some short passwords. Test ASCII
      # $2a$ and arbitrary non-NUL $2b$ inputs on the interleaved core.
      bytes.map! do |b|
        b &= 127_u8 if k.even?
        b == 0 ? 1_u8 : b
      end
      passwords[k] = round == 0 ? "password123" : String.new(bytes)
      lengths[k] = passwords[k].bytesize
      ptrs[k] = passwords[k].to_unsafe
      prefix = k.even? ? "$2a$" : "$2b$"
      raise "salt failed" if TestCrypt.crypt_gensalt_rn(prefix.to_unsafe, 10, Pointer(UInt8).null, 0, settings[k].to_unsafe, 64).null?
      salts[k] = settings[k].to_unsafe
      salts[k] = seed.to_unsafe if round == 0 && k == 0
    end
    engine.hash(ptrs.to_unsafe, lengths.to_unsafe, salts.to_unsafe, output.to_unsafe)
    N.times do |k|
      theirs = TestCrypt.crypt_rn(ptrs[k], salts[k], data.to_unsafe, data.size)
      mine = String.new(output.to_unsafe + k * 61)
      raise "mismatch N=#{N} round=#{round} lane=#{k}: #{mine} vs #{String.new(theirs)}" unless mine == String.new(theirs)
      raise "seed mismatch" if round == 0 && k == 0 && mine != seed
    end
  end
  puts "#{N * rounds} hashes at cost 10, #{N} lanes: match libcrypt"
end

check_lanes(Rayo::Bcrypt::Lanes::Engine(1).new, 80)
check_lanes(Rayo::Bcrypt::Lanes::Engine(2).new, 20)
check_lanes(Rayo::Bcrypt::Lanes::Engine(3).new, 20)
check_lanes(Rayo::Bcrypt::Lanes::Engine(5).new, 20)
check_lanes(Rayo::Bcrypt::Lanes::Engine(4).new, 40)
check_lanes(Rayo::Bcrypt::Lanes::Engine(6).new, 40)
check_lanes(Rayo::Bcrypt::Lanes::Engine(8).new, 40)
