#include "json_read.hpp"

#include <cstring>

namespace json {
namespace {

constexpr int kMaxDepth = 32;

int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Writes code point cp as UTF-8 at w; returns bytes written.
int put_utf8(char* w, std::uint32_t cp) {
  if (cp < 0x80) {
    w[0] = char(cp);
    return 1;
  }
  if (cp < 0x800) {
    w[0] = char(0xC0 | (cp >> 6));
    w[1] = char(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    w[0] = char(0xE0 | (cp >> 12));
    w[1] = char(0x80 | ((cp >> 6) & 0x3F));
    w[2] = char(0x80 | (cp & 0x3F));
    return 3;
  }
  w[0] = char(0xF0 | (cp >> 18));
  w[1] = char(0x80 | ((cp >> 12) & 0x3F));
  w[2] = char(0x80 | ((cp >> 6) & 0x3F));
  w[3] = char(0x80 | (cp & 0x3F));
  return 4;
}

// Length of a valid UTF-8 sequence starting at p (lead byte >= 0x80), or 0 if invalid.
int utf8_seq(const unsigned char* p, const unsigned char* end) {
  unsigned char c = p[0];
  int n;
  std::uint32_t cp;
  if (c >= 0xC2 && c <= 0xDF) { n = 2; cp = c & 0x1F; }
  else if (c >= 0xE0 && c <= 0xEF) { n = 3; cp = c & 0x0F; }
  else if (c >= 0xF0 && c <= 0xF4) { n = 4; cp = c & 0x07; }
  else return 0;
  if (end - p < n) return 0;
  for (int i = 1; i < n; ++i) {
    if ((p[i] & 0xC0) != 0x80) return 0;
    cp = (cp << 6) | (p[i] & 0x3F);
  }
  if (n == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return 0;
  if (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return 0;
  return n;
}

bool read_hex4(const char* p, std::uint32_t& v) {
  v = 0;
  for (int i = 0; i < 4; ++i) {
    int h = hexval(p[i]);
    if (h < 0) return false;
    v = (v << 4) | std::uint32_t(h);
  }
  return true;
}

}  // namespace

void Doc::ws() {
  while (p_ < end_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r')) ++p_;
}

bool Doc::parse(char* s, std::size_t n) {
  nodes_.clear();
  p_ = s;
  end_ = s + n;
  depth_ = 0;
  ws();
  nodes_.push_back(Node{Type::Null});
  if (!value(0)) return false;
  ws();
  return p_ == end_;
}

// Decodes the string starting at p_ (just after the opening quote) in place at the same position.
bool Doc::string(const char*& out, std::uint32_t& out_len) {
  char* w = const_cast<char*>(p_);
  char* start = w;
  while (true) {
    if (p_ >= end_) return false;
    unsigned char c = static_cast<unsigned char>(*p_);
    if (c == '"') {
      ++p_;
      break;
    }
    if (c < 0x20) return false;
    if (c == '\\') {
      if (end_ - p_ < 2) return false;
      char e = p_[1];
      p_ += 2;
      switch (e) {
        case '"': *w++ = '"'; break;
        case '\\': *w++ = '\\'; break;
        case '/': *w++ = '/'; break;
        case 'b': *w++ = '\b'; break;
        case 'f': *w++ = '\f'; break;
        case 'n': *w++ = '\n'; break;
        case 'r': *w++ = '\r'; break;
        case 't': *w++ = '\t'; break;
        case 'u': {
          std::uint32_t cp;
          if (end_ - p_ < 4 || !read_hex4(p_, cp)) return false;
          p_ += 4;
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            std::uint32_t lo;
            if (end_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u' && read_hex4(p_ + 2, lo) && lo >= 0xDC00 &&
                lo <= 0xDFFF) {
              p_ += 6;
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else {
              cp = 0xFFFD;  // lone high surrogate (Go's behaviour)
            }
          } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            cp = 0xFFFD;  // lone low surrogate
          }
          // Output (<= 4 bytes) never overtakes input: a \uXXXX escape consumed 6 bytes (12 for a pair).
          w += put_utf8(w, cp);
          break;
        }
        default:
          return false;
      }
      continue;
    }
    if (c < 0x80) {
      *w++ = char(c);
      ++p_;
      continue;
    }
    int n = utf8_seq(reinterpret_cast<const unsigned char*>(p_), reinterpret_cast<const unsigned char*>(end_));
    if (n == 0) return false;
    std::memmove(w, p_, std::size_t(n));
    w += n;
    p_ += n;
  }
  out = start;
  out_len = std::uint32_t(w - start);
  return true;
}

bool Doc::number() {
  const char* s = p_;
  if (p_ < end_ && *p_ == '-') ++p_;
  if (p_ >= end_) return false;
  if (*p_ == '0') {
    ++p_;
  } else if (*p_ >= '1' && *p_ <= '9') {
    while (p_ < end_ && *p_ >= '0' && *p_ <= '9') ++p_;
  } else {
    return false;
  }
  if (p_ < end_ && *p_ == '.') {
    ++p_;
    const char* d = p_;
    while (p_ < end_ && *p_ >= '0' && *p_ <= '9') ++p_;
    if (p_ == d) return false;
  }
  if (p_ < end_ && (*p_ == 'e' || *p_ == 'E')) {
    ++p_;
    if (p_ < end_ && (*p_ == '+' || *p_ == '-')) ++p_;
    const char* d = p_;
    while (p_ < end_ && *p_ >= '0' && *p_ <= '9') ++p_;
    if (p_ == d) return false;
  }
  return p_ > s;
}

bool Doc::value(std::uint32_t idx) {
  if (p_ >= end_) return false;
  char c = *p_;
  switch (c) {
    case '{': {
      if (++depth_ > kMaxDepth) return false;
      nodes_[idx].type = Type::Object;
      ++p_;
      ws();
      if (p_ < end_ && *p_ == '}') {
        ++p_;
        --depth_;
        return true;
      }
      std::uint32_t prev = 0;
      while (true) {
        ws();
        if (p_ >= end_ || *p_ != '"') return false;
        ++p_;
        const char* k;
        std::uint32_t kl;
        if (!string(k, kl)) return false;
        ws();
        if (p_ >= end_ || *p_ != ':') return false;
        ++p_;
        ws();
        std::uint32_t me = std::uint32_t(nodes_.size());
        nodes_.push_back(Node{Type::Null});
        nodes_[me].key = k;
        nodes_[me].key_len = kl;
        if (prev == 0) nodes_[idx].child = me + 1;
        else nodes_[prev - 1].next = me + 1;
        prev = me + 1;
        if (!value(me)) return false;
        ws();
        if (p_ >= end_) return false;
        if (*p_ == ',') {
          ++p_;
          continue;
        }
        if (*p_ == '}') {
          ++p_;
          --depth_;
          return true;
        }
        return false;
      }
    }
    case '[': {
      if (++depth_ > kMaxDepth) return false;
      nodes_[idx].type = Type::Array;
      ++p_;
      ws();
      if (p_ < end_ && *p_ == ']') {
        ++p_;
        --depth_;
        return true;
      }
      std::uint32_t prev = 0;
      while (true) {
        ws();
        std::uint32_t me = std::uint32_t(nodes_.size());
        nodes_.push_back(Node{Type::Null});
        if (prev == 0) nodes_[idx].child = me + 1;
        else nodes_[prev - 1].next = me + 1;
        prev = me + 1;
        if (!value(me)) return false;
        ws();
        if (p_ >= end_) return false;
        if (*p_ == ',') {
          ++p_;
          continue;
        }
        if (*p_ == ']') {
          ++p_;
          --depth_;
          return true;
        }
        return false;
      }
    }
    case '"': {
      ++p_;
      const char* s;
      std::uint32_t l;
      if (!string(s, l)) return false;
      nodes_[idx].type = Type::String;
      nodes_[idx].str = s;
      nodes_[idx].len = l;
      return true;
    }
    case 't':
      if (end_ - p_ >= 4 && std::memcmp(p_, "true", 4) == 0) {
        p_ += 4;
        nodes_[idx].type = Type::True;
        return true;
      }
      return false;
    case 'f':
      if (end_ - p_ >= 5 && std::memcmp(p_, "false", 5) == 0) {
        p_ += 5;
        nodes_[idx].type = Type::False;
        return true;
      }
      return false;
    case 'n':
      if (end_ - p_ >= 4 && std::memcmp(p_, "null", 4) == 0) {
        p_ += 4;
        nodes_[idx].type = Type::Null;
        return true;
      }
      return false;
    default: {
      const char* s = p_;
      if (!number()) return false;
      nodes_[idx].type = Type::Number;
      nodes_[idx].str = s;
      nodes_[idx].len = std::uint32_t(p_ - s);
      return true;
    }
  }
}

const Node* Doc::get(const Node* obj, std::string_view key) const {
  if (!obj || obj->type != Type::Object) return nullptr;
  const Node* found = nullptr;
  for (const Node* m = first_child(obj); m; m = next(m))
    if (m->key_len == key.size() && std::memcmp(m->key, key.data(), key.size()) == 0) found = m;
  return found;
}

std::string_view as_string(const Node* n) { return std::string_view(n->str, n->len); }

}  // namespace json
