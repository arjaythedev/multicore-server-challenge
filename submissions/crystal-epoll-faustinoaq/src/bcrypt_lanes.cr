require "crypto/blowfish"

# The standard hexadecimal digits of pi, supplied by Crystal's Blowfish tables.
class Crypto::Blowfish
  def self.initial_words(dst : UInt32*) : Nil
    dst.copy_from(P.to_unsafe, 18)
    (dst + 18).copy_from(S.to_unsafe, 1024)
  end
end

# Independent EksBlowfish states, interleaved at each round to overlap S-box loads.
# Scratch state is overwritten on every call. All lanes execute every cost-10 round.
module BcryptLanes
  ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  MAGIC = StaticArray[0x4f727068_u32, 0x65616e42_u32, 0x65686f6c_u32, 0x64657253_u32, 0x63727944_u32, 0x6f756274_u32]

  def self.decode(src : UInt8*, dst : UInt8*, n : Int32) : Bool
    bits = 0_u32
    count = 0
    pos = 0
    i = 0
    while pos < n
      v = -1
      64.times { |k| v = k if ALPHABET.to_unsafe[k] == src[i] }
      return false if v < 0
      bits = (bits << 6) | v.to_u32
      count += 6
      if count >= 8
        count -= 8
        dst[pos] = (bits >> count).to_u8!
        pos += 1
      end
      i += 1
    end
    true
  end

  def self.encode(src : UInt8*, n : Int32, dst : UInt8*) : Nil
    bits = 0_u32
    count = 0
    pos = 0
    n.times do |i|
      bits = (bits << 8) | src[i]
      count += 8
      while count >= 6
        count -= 6
        dst[pos] = ALPHABET.to_unsafe[(bits >> count) & 63]
        pos += 1
      end
    end
    dst[pos] = ALPHABET.to_unsafe[(bits << (6 - count)) & 63] if count > 0
  end

  struct Engine(N)
    @st : UInt32*
    @words : UInt32*
    @salt : UInt32*
    def initialize
      @st = LibC.malloc(N * 1042 * 4).as(UInt32*)
      @words = LibC.malloc(N * 18 * 4).as(UInt32*)
      @salt = LibC.malloc(N * 18 * 4).as(UInt32*)
    end

    def free : Nil
      LibC.free(@st)
      LibC.free(@words)
      LibC.free(@salt)
    end

    @[AlwaysInline]
    def f(s : UInt32*, x : UInt32) : UInt32
      ((s[x >> 24] &+ s[256 + ((x >> 16) & 255)]) ^ s[512 + ((x >> 8) & 255)]) &+ s[768 + (x & 255)]
    end

    @[AlwaysInline]
    def encrypt(l : UInt32*, r : UInt32*) : Nil
      8.times do |i|
        {% for k in 0...N %}
          l[{{k}}] ^= @st[{{k * 1042}} + 2 * i]
          r[{{k}}] ^= f(@st + {{k * 1042 + 18}}, l[{{k}}])
        {% end %}
        {% for k in 0...N %}
          r[{{k}}] ^= @st[{{k * 1042}} + 2 * i + 1]
          l[{{k}}] ^= f(@st + {{k * 1042 + 18}}, r[{{k}}])
        {% end %}
      end
      {% for k in 0...N %}
        x = l[{{k}}] ^ @st[{{k * 1042 + 16}}]
        l[{{k}}] = r[{{k}}] ^ @st[{{k * 1042 + 17}}]
        r[{{k}}] = x
      {% end %}
    end

    def expand(words : UInt32*, salted : Bool) : Nil
      N.times do |k|
        18.times { |i| @st[k * 1042 + i] ^= words[k * 18 + i] }
      end
      l = StaticArray(UInt32, N).new(0_u32)
      r = StaticArray(UInt32, N).new(0_u32)
      521.times do |i|
        if salted
          N.times do |k|
            l.to_unsafe[k] ^= @salt[k * 18 + ((i * 2) & 3)]
            r.to_unsafe[k] ^= @salt[k * 18 + ((i * 2 + 1) & 3)]
          end
        end
        encrypt(l.to_unsafe, r.to_unsafe)
        N.times do |k|
          @st[k * 1042 + i * 2] = l.to_unsafe[k]
          @st[k * 1042 + i * 2 + 1] = r.to_unsafe[k]
        end
      end
    end

    # settings contain the 29-byte $2a$10$ or $2b$10$ salt prefix.
    def hash(passwords : UInt8**, lengths : Int32*, settings : UInt8**, output : UInt8*) : Nil
      saltbytes = uninitialized UInt8[16]
      N.times do |k|
        Crypto::Blowfish.initial_words(@st + k * 1042)
        BcryptLanes.decode(settings[k] + 7, saltbytes.to_unsafe, 16)
        pos = 0
        18.times do |i|
          w = 0_u32
          4.times do
            w = (w << 8) | (pos == lengths[k] ? 0_u8 : passwords[k][pos])
            pos += 1
            pos = 0 if pos >= lengths[k] + 1
          end
          @words[k * 18 + i] = w
          sw = 0_u32
          4.times { |j| sw = (sw << 8) | saltbytes.to_unsafe[(i * 4 + j) & 15] }
          @salt[k * 18 + i] = sw
        end
      end
      expand(@words, true)
      1024.times do
        expand(@words, false)
        expand(@salt, false)
      end
      cp = LibC.malloc(N * 6 * 4).as(UInt32*)
      c = Slice(UInt32).new(cp, N * 6)
      N.times { |k| 6.times { |i| c.to_unsafe[k * 6 + i] = MAGIC.to_unsafe[i] } }
      l = uninitialized UInt32[N]
      r = uninitialized UInt32[N]
      64.times do
        3.times do |i|
          N.times do |k|
            l.to_unsafe[k] = c.to_unsafe[k * 6 + i * 2]
            r.to_unsafe[k] = c.to_unsafe[k * 6 + i * 2 + 1]
          end
          encrypt(l.to_unsafe, r.to_unsafe)
          N.times do |k|
            c.to_unsafe[k * 6 + i * 2] = l.to_unsafe[k]
            c.to_unsafe[k * 6 + i * 2 + 1] = r.to_unsafe[k]
          end
        end
      end
      raw = uninitialized UInt8[24]
      N.times do |k|
        24.times { |i| raw.to_unsafe[i] = (c.to_unsafe[k * 6 + i // 4] >> (24 - (i & 3) * 8)).to_u8! }
        dst = output + k * 61
        dst.copy_from(settings[k], 29)
        BcryptLanes.encode(raw.to_unsafe, 23, dst + 29)
        dst[60] = 0_u8
      end
      LibC.free(cp)
    end
  end
end
