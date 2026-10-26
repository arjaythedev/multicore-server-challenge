// This four-lane EksBlowfish implementation is adapted from the challenge's
// C++ submission (MIT-licensed); see the submission attribution in README.md.
#include "native.h"
#include "native/bcrypt.hpp"

#include <cstring>
#include <exception>
#include <string>

extern "C" int bcryptx_compute(const uint8_t *passwords,
                               const int32_t *lengths,
                               const uint8_t *salts,
                               const int32_t *costs,
                               uint8_t *hashes, int n) {
  if (n < 1 || n > 4) return 1;
  for (int i = 1; i < n; ++i) {
    if (costs[i] != costs[0]) return 1;
  }

  try {
    bcrypt::Job jobs[4];
    bcrypt::Job *job_ptrs[4];
    for (int i = 0; i < n; ++i) {
      if (lengths[i] < 0 || lengths[i] > 72 || costs[i] < 4 || costs[i] > 31)
        return 1;
      auto &job = jobs[i];
      job.password.assign(reinterpret_cast<const char *>(passwords + i * 73),
                          static_cast<size_t>(lengths[i]));
      job.cost = costs[i];
      job.variant = 'a';
      std::memcpy(job.salt, salts + i * 16, 16);
      bcrypt::b64_encode(job.salt_str, job.salt, 16);
      job_ptrs[i] = &job;
    }
    bcrypt::compute(job_ptrs, n);
    for (int i = 0; i < n; ++i) {
      if (jobs[i].result.size() != 60) return 1;
      std::memcpy(hashes + i * 60, jobs[i].result.data(), 60);
    }
  } catch (const std::exception &) {
    return 1;
  } catch (...) {
    return 1;
  }
  return 0;
}
