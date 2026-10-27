// Validating JSON parser for request bodies and JWT segments. It builds a flat array of nodes (objects and
// arrays link their children through `next`), decoding strings in place: an unescaped string is never longer
// than its escaped form, so decoded bytes overwrite the input behind the read position.
//
// Semantics follow Go's encoding/json where the reference server depends on them: the last duplicate key wins,
// a lone UTF-16 surrogate escape becomes U+FFFD. Invalid UTF-8 inside strings is rejected (the reference would
// substitute U+FFFD; Postgres would reject the bytes either way).
#pragma once
#include <cstdint>
#include <string_view>
#include <vector>

namespace json {

enum class Type : std::uint8_t { Null, False, True, Number, String, Array, Object };

struct Node {
  Type type;
  std::uint32_t next = 0;    // index of next sibling + 1 (0 = none)
  std::uint32_t child = 0;   // first child index + 1 (objects/arrays)
  const char* key = nullptr; // member name (decoded), for object members
  std::uint32_t key_len = 0;
  const char* str = nullptr; // decoded string, or number text
  std::uint32_t len = 0;
};

class Doc {
 public:
  // Parses [s, s + n) in place. Returns false on any syntax error, trailing garbage or depth > 32.
  bool parse(char* s, std::size_t n);

  const Node* root() const { return nodes_.empty() ? nullptr : &nodes_[0]; }
  // Last member named `key` of object `obj`, or nullptr.
  const Node* get(const Node* obj, std::string_view key) const;
  const Node* first_child(const Node* n) const { return n->child ? &nodes_[n->child - 1] : nullptr; }
  const Node* next(const Node* n) const { return n->next ? &nodes_[n->next - 1] : nullptr; }

 private:
  std::vector<Node> nodes_;
  const char* p_ = nullptr;
  const char* end_ = nullptr;
  char* w_ = nullptr;  // in-place write cursor for decoded strings
  int depth_ = 0;

  bool value(std::uint32_t idx);
  bool string(const char*& out, std::uint32_t& out_len);
  bool number();
  void ws();
};

std::string_view as_string(const Node* n);

}  // namespace json
