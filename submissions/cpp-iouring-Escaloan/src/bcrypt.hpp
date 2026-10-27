// bcrypt ($2a$ / $2b$ / $2y$, cost 4..31) with up to four independent hashes computed in lockstep.
//
// Each Blowfish encryption is a chain of 16 dependent rounds of S-box loads; one hash leaves most of the core's
// load ports idle. Advancing four hashes together overlaps their chains. Every round of every hash is computed;
// only the instruction scheduling changes. Semantics match OpenBSD / Go x/crypto: the key is the password's first
// 72 bytes plus a NUL terminator (the NUL is reached only for passwords shorter than 72 bytes); "$2a$" uses the
// same (correct) algorithm as "$2b$".
#pragma once
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace bcrypt {

inline constexpr std::size_t kHashLen = 60;

struct Job {
  std::string_view password;
  // In: for hashing, `salt` (16 random bytes) and `cost`; for verifying, the stored hash string.
  std::string_view stored;      // verify mode when non-empty
  unsigned char salt[16];
  int cost = 10;
  // Out
  char out[64];                 // computed hash string (60 chars + NUL)
  bool ok = false;              // hash: produced; verify: matched
};

// Parses a stored hash. Returns false for anything that is not a well-formed $2a$/$2b$/$2y$ hash.
bool parse(std::string_view stored, int& cost, unsigned char salt[16], char prefix[4]);

// Runs 1..4 jobs. All jobs must have the same cost (callers group by cost). Verify jobs compare in constant time.
void run(Job* jobs, int n);

// Startup self-test against fixed vectors at cost 4/5; returns false on mismatch.
bool self_test();

}  // namespace bcrypt
