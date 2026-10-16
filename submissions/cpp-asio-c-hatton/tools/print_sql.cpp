// Prints every prepared statement (for tools/difftest.py). Not part of the server build.
#include <cstdio>
#include "../src/sql.hpp"
int main() {
  auto s = all_sql();
  for (size_t i = 0; i < s.size(); ++i) std::printf("%s\n\x1e\n", s[i].c_str());
}
