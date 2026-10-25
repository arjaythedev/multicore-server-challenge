// bcrypt ($2b$) with N independent hashes advanced in lockstep on one thread. A single Blowfish chain is bound by
// L1 load latency; interleaving up to 4 chains keeps the load ports busy. Hashing is rare next to the rest of the
// traffic, so the pool threads run at low priority.
#include "bcrypt.h"
#include "prof.h"

#include <openssl/crypto.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

#include "bf_init.h"
#include "worker.h"

namespace {

constexpr int kMaxLanes = 4;
// Measured per hash (cost 10): 1 lane 40 ms, 2 lanes 23 ms, 3 lanes 17 ms, 4 lanes 17 ms. Logins arrive ~20/s, so a longer
// window fills the batches (less CPU per hash) and stays far below the latency budget of a login.
constexpr auto kCollectWindow = std::chrono::milliseconds(200);

struct Lane {
    uint32_t P[18];
    uint32_t S[4][256];
};

struct Input {
    uint32_t key[18];   // password bytes + NUL, cyclic, as big-endian words
    uint32_t salt[4];
    int cost;
};

inline uint32_t F(const Lane &s, uint32_t x) {
    return ((s.S[0][x >> 24] + s.S[1][(x >> 16) & 255]) ^ s.S[2][(x >> 8) & 255]) + s.S[3][x & 255];
}

// Encrypts (l, r) of every lane at once.
template <int N>
inline void enc(Lane *s, uint32_t *l, uint32_t *r) {
#pragma GCC unroll 4
    for (int k = 0; k < N; k++) l[k] ^= s[k].P[0];
#pragma GCC unroll 8  // 8 rounds fully unrolled: -8% per hash vs a counted loop
    for (int i = 1; i <= 15; i += 2) {
#pragma GCC unroll 4
        for (int k = 0; k < N; k++) r[k] ^= F(s[k], l[k]) ^ s[k].P[i];
#pragma GCC unroll 4
        for (int k = 0; k < N; k++) l[k] ^= F(s[k], r[k]) ^ s[k].P[i + 1];
    }
#pragma GCC unroll 4
    for (int k = 0; k < N; k++) {
        uint32_t t = l[k];
        l[k] = r[k] ^ s[k].P[17];
        r[k] = t;
    }
}

// salt == nullptr: expand0state(key); otherwise expandstate(salt, key).
template <int N>
void expand(Lane *s, const uint32_t (*key)[18], const uint32_t (*salt)[4]) {
    uint32_t l[N], r[N];
    for (int k = 0; k < N; k++) {
        for (int i = 0; i < 18; i++) s[k].P[i] ^= key[k][i];
        l[k] = r[k] = 0;
    }
    int m = 0;
    auto step = [&](auto store) {
        if (salt) {
            int j = (m & 1) * 2;
            for (int k = 0; k < N; k++) {
                l[k] ^= salt[k][j];
                r[k] ^= salt[k][j + 1];
            }
        }
        m++;
        enc<N>(s, l, r);
        for (int k = 0; k < N; k++) store(k, l[k], r[k]);
    };
    for (int i = 0; i < 18; i += 2)
        step([&](int k, uint32_t a, uint32_t b) { s[k].P[i] = a; s[k].P[i + 1] = b; });
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < 256; i += 2)
            step([&](int k, uint32_t x, uint32_t y) { s[k].S[b][i] = x; s[k].S[b][i + 1] = y; });
}

// Hashes N inputs that share one cost; out[k] receives the 24-byte ciphertext.
template <int N>
void run(const Input *in, uint8_t (*out)[24]) {
    alignas(64) Lane s[N];
    uint32_t key[N][18], salt[N][4], saltk[N][18];
    for (int k = 0; k < N; k++) {
        memcpy(s[k].P, kBfP, sizeof kBfP);
        memcpy(s[k].S, kBfS, sizeof kBfS);
        memcpy(key[k], in[k].key, sizeof key[k]);
        memcpy(salt[k], in[k].salt, sizeof salt[k]);
        for (int i = 0; i < 18; i++) saltk[k][i] = salt[k][i & 3];
    }
    expand<N>(s, key, salt);
    for (uint64_t n = uint64_t(1) << in[0].cost; n; n--) {
        expand<N>(s, key, nullptr);
        expand<N>(s, saltk, nullptr);
    }
    static const char magic[25] = "OrpheanBeholderScryDoubt";
    for (int k = 0; k < N; k++) {
        uint32_t c[6];
        for (int i = 0; i < 6; i++)
            c[i] = uint32_t(uint8_t(magic[4 * i])) << 24 | uint32_t(uint8_t(magic[4 * i + 1])) << 16 |
                   uint32_t(uint8_t(magic[4 * i + 2])) << 8 | uint8_t(magic[4 * i + 3]);
        for (int rep = 0; rep < 64; rep++)
            for (int b = 0; b < 3; b++) enc<1>(&s[k], &c[2 * b], &c[2 * b + 1]);
        for (int i = 0; i < 6; i++) {
            out[k][4 * i] = uint8_t(c[i] >> 24);
            out[k][4 * i + 1] = uint8_t(c[i] >> 16);
            out[k][4 * i + 2] = uint8_t(c[i] >> 8);
            out[k][4 * i + 3] = uint8_t(c[i]);
        }
    }
}

const char kAlpha[] = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

void b64enc(const uint8_t *d, int n, char *o) {
    for (int i = 0; i < n;) {
        uint32_t c1 = d[i++];
        *o++ = kAlpha[c1 >> 2];
        c1 = (c1 & 3) << 4;
        if (i >= n) { *o++ = kAlpha[c1]; break; }
        uint32_t c2 = d[i++];
        c1 |= c2 >> 4;
        *o++ = kAlpha[c1];
        c1 = (c2 & 15) << 2;
        if (i >= n) { *o++ = kAlpha[c1]; break; }
        c2 = d[i++];
        c1 |= c2 >> 6;
        *o++ = kAlpha[c1];
        *o++ = kAlpha[c2 & 63];
    }
}

int b64val(char c) {
    const char *p = c ? strchr(kAlpha, c) : nullptr;
    return p ? int(p - kAlpha) : -1;
}

// Decodes exactly `chars` characters into `n` bytes.
bool b64dec(const char *s, int chars, uint8_t *o, int n) {
    int w = 0;
    for (int i = 0; i + 1 < chars && w < n; i += 4) {
        int c1 = b64val(s[i]), c2 = b64val(s[i + 1]);
        if (c1 < 0 || c2 < 0) return false;
        o[w++] = uint8_t(c1 << 2 | (c2 & 0x30) >> 4);
        if (w >= n || i + 2 >= chars) break;
        int c3 = b64val(s[i + 2]);
        if (c3 < 0) return false;
        o[w++] = uint8_t((c2 & 15) << 4 | (c3 & 0x3c) >> 2);
        if (w >= n || i + 3 >= chars) break;
        int c4 = b64val(s[i + 3]);
        if (c4 < 0) return false;
        o[w++] = uint8_t((c3 & 3) << 6 | c4);
    }
    return w == n;
}

uint32_t be32(const uint8_t *p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }

struct Job {
    BcryptAwait *a = nullptr;
    Input in{};
    uint8_t salt[16];
    char cost_str[3] = {};
    bool valid = false;
    uint8_t ct[24];
};

// Prepares the key/salt/cost of a job; false = cannot be hashed (verify then fails).
bool prepare(Job &j) {
    BcryptAwait &a = *j.a;
    if (a.hash) {
        if (getrandom(j.salt, 16, 0) != 16) return false;
        j.in.cost = 10;
    } else {
        const std::string &h = a.stored;
        if (h.size() != 60 || h[0] != '$' || h[1] != '2' || (h[2] != 'a' && h[2] != 'b' && h[2] != 'y') || h[3] != '$' ||
            h[6] != '$' || h[4] < '0' || h[4] > '3' || h[5] < '0' || h[5] > '9')
            return false;
        j.in.cost = (h[4] - '0') * 10 + (h[5] - '0');
        if (j.in.cost < 4 || j.in.cost > 16) return false;
        if (!b64dec(h.data() + 7, 22, j.salt, 16)) return false;
    }
    // Key = password + NUL, at most 72 bytes, repeated cyclically (as $2b$ does).
    size_t len = a.password.size() + 1;
    if (len > 72) len = 72;
    uint8_t kb[72];
    for (size_t i = 0; i < len; i++) kb[i] = i < a.password.size() ? uint8_t(a.password[i]) : 0;
    for (int i = 0; i < 18; i++) {
        uint32_t w = 0;
        for (int b = 0; b < 4; b++) w = w << 8 | kb[(i * 4 + b) % len];
        j.in.key[i] = w;
    }
    for (int i = 0; i < 4; i++) j.in.salt[i] = be32(j.salt + 4 * i);
    return true;
}

void finish(Job &j) {
    BcryptAwait &a = *j.a;
    // 23 of the 24 ciphertext bytes are encoded.
    char enc[31];
    b64enc(j.ct, 23, enc);
    if (a.hash) {
        char out[61] = "$2b$10$";
        b64enc(j.salt, 16, out + 7);
        memcpy(out + 29, enc, 31);
        a.result.hash.assign(out, 60);
        a.result.ok = true;
    } else {
        // Compare only the hash part; the salt part of the stored string is what we decoded.
        a.result.ok = CRYPTO_memcmp(enc, a.stored.data() + 29, 31) == 0;
    }
}

void process(Job *jobs, int n) {
    // Group by cost (virtually always all the same).
    bool used[kMaxLanes] = {};
    for (int i = 0; i < n; i++) {
        if (used[i] || !jobs[i].valid) continue;
        Input in[kMaxLanes];
        uint8_t out[kMaxLanes][24];
        int idx[kMaxLanes], c = 0;
        for (int k = i; k < n; k++)
            if (!used[k] && jobs[k].valid && jobs[k].in.cost == jobs[i].in.cost) {
                used[k] = true;
                idx[c] = k;
                in[c++] = jobs[k].in;
            }
        switch (c) {
            case 1: run<1>(in, out); break;
            case 2: run<2>(in, out); break;
            case 3: run<3>(in, out); break;
            default: run<4>(in, out); break;
        }
        for (int k = 0; k < c; k++) {
            memcpy(jobs[idx[k]].ct, out[k], 24);
            finish(jobs[idx[k]]);
        }
    }
}

alignas(64) std::mutex g_mu;  // shared by the bcrypt threads and the enqueuing workers: keep it off other globals' lines
std::condition_variable g_cv;
std::deque<BcryptAwait *> g_jobs;
bool g_collecting = false;  // one leader at a time waits for company; the other threads only take backlog

void loop() {
    const pid_t tid = pid_t(syscall(SYS_gettid));
    setpriority(PRIO_PROCESS, tid, 10);
    for (;;) {
        Job jobs[kMaxLanes];
        int n = 0;
        bool backlog;
        {
            std::unique_lock lk(g_mu);
            // Work for a thread that is not the leader exists only once a whole batch is already queued.
            g_cv.wait(lk, [] { return !g_jobs.empty() && (!g_collecting || g_jobs.size() >= size_t(kMaxLanes)); });
            backlog = g_collecting || g_jobs.size() >= size_t(kMaxLanes);
            if (!backlog) g_collecting = true;
            while (n < kMaxLanes && !g_jobs.empty()) {
                jobs[n++].a = g_jobs.front();
                g_jobs.pop_front();
            }
            if (!backlog) {
                // A lone hash is a serial chain (~40 ms); four in lockstep cost little more than two. Wait briefly for
                // company, far below the latency budget of a login.
                auto deadline = std::chrono::steady_clock::now() + kCollectWindow;
                while (n < kMaxLanes && g_cv.wait_until(lk, deadline, [] { return !g_jobs.empty(); })) {
                    while (n < kMaxLanes && !g_jobs.empty()) {
                        jobs[n++].a = g_jobs.front();
                        g_jobs.pop_front();
                    }
                }
                g_collecting = false;
            }
            if (!g_jobs.empty()) g_cv.notify_all();
        }
        // Under backlog the logins gate everything else users do, so hash at normal priority.
        if (backlog) setpriority(PRIO_PROCESS, tid, 0);
        for (int i = 0; i < n; i++) jobs[i].valid = prepare(jobs[i]);
#ifdef PROF
        uint64_t prof_t0 = __rdtsc();
#endif
        process(jobs, n);
#ifdef PROF
        prof::bcrypt_done(__rdtsc() - prof_t0, n);
#endif
        for (int i = 0; i < n; i++) jobs[i].a->w.post_done(jobs[i].a);
        if (backlog) setpriority(PRIO_PROCESS, tid, 10);
    }
}

}  // namespace

void BcryptAwait::await_suspend(std::coroutine_handle<> c) {
    h = c;
    {
        std::lock_guard lk(g_mu);
        g_jobs.push_back(this);
    }
    g_cv.notify_all();  // the leader and the backlog takers wait on different predicates
}

void bcrypt_pool::start(int threads) {
    for (int i = 0; i < threads; i++) std::thread(loop).detach();
}
