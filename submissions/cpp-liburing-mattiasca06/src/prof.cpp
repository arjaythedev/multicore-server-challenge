#include "prof.h"

#ifdef PROF
#include <signal.h>
#include <time.h>

#include <atomic>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

namespace prof {

thread_local Counters *tl = nullptr;
static std::mutex g_mu;
static std::vector<Counters *> g_all;
static std::atomic<uint64_t> g_bc_cyc{0}, g_bc_n{0};
static std::atomic<uint64_t> g_rg{0}, g_rg_members{0}, g_rg_sent{0}, g_rg_hist[8];

void attach() {
    auto *c = new Counters;
    c->last = __rdtsc();
    tl = c;
    std::lock_guard lk(g_mu);
    g_all.push_back(c);
}

void bcrypt_done(uint64_t cyc, int n) {
    g_bc_cyc += cyc;
    g_bc_n += uint64_t(n);
}

void read_group(size_t members, size_t sent) {
    g_rg++;
    g_rg_members += members;
    g_rg_sent += sent;
    g_rg_hist[members >= 8 ? 7 : members - 1]++;
}

static double tsc_ghz() {
    timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    uint64_t t0 = __rdtsc();
    do clock_gettime(CLOCK_MONOTONIC, &b);
    while ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec) < 50e6);
    uint64_t t1 = __rdtsc();
    return double(t1 - t0) / ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec));
}

void start_dumper() {
    sigset_t s;
    sigemptyset(&s);
    sigaddset(&s, SIGUSR1);
    pthread_sigmask(SIG_BLOCK, &s, nullptr);  // inherited by every thread created afterwards
    std::thread([s] {
        const double ghz = tsc_ghz();
        uint64_t prev[kCount] = {}, prev_req = 0, prev_bc = 0, prev_bn = 0;
        for (;;) {
            int sig;
            sigwait(&s, &sig);
            uint64_t cur[kCount] = {}, req = 0;
            {
                std::lock_guard lk(g_mu);
                for (Counters *c : g_all) {
                    for (int i = 0; i < kCount; i++) cur[i] += c->cyc[i];
                    req += c->requests;
                }
            }
            uint64_t bc = g_bc_cyc, bn = g_bc_n;
            uint64_t dreq = req - prev_req;
            if (dreq == 0) {
                fprintf(stderr, "PROF: no requests since last dump (baseline taken)\n");
            } else {
                uint64_t busy = 0, tot = 0;
                for (int i = 0; i < kCount; i++) {
                    tot += cur[i] - prev[i];
                    if (i != kWait) busy += cur[i] - prev[i];
                }
                fprintf(stderr, "PROF ---- %llu requests, TSC %.3f GHz ----\n", (unsigned long long)dreq, ghz);
                fprintf(stderr, "PROF %-40s %10s %8s\n", "phase (event-loop thread CPU)", "us/req", "% busy");
                for (int i = 0; i < kCount; i++) {
                    uint64_t d = cur[i] - prev[i];
                    double us = double(d) / ghz / 1000.0 / double(dreq);
                    if (i == kWait) fprintf(stderr, "PROF %-40s %10.2f %8s\n", kNames[i], us, "-");
                    else fprintf(stderr, "PROF %-40s %10.2f %7.1f%%\n", kNames[i], us, 100.0 * double(d) / double(busy));
                }
                fprintf(stderr, "PROF %-40s %10.2f\n", "TOTAL busy per request",
                        double(busy) / ghz / 1000.0 / double(dreq));
                fprintf(stderr, "PROF event-loop utilisation %.1f%%\n", 100.0 * double(busy) / double(tot));
                uint64_t dbn = bn - prev_bn;
                if (dbn)
                    fprintf(stderr, "PROF bcrypt: %llu hashes, %.0f us per hash (thread CPU), %.2f us per request overall\n",
                            (unsigned long long)dbn, double(bc - prev_bc) / ghz / 1000.0 / double(dbn),
                            double(bc - prev_bc) / ghz / 1000.0 / double(dreq));
            }
            if (g_rg)
                fprintf(stderr, "PROF read segments: %llu, %.2f requests per segment, %.2f statements sent per segment; size histogram 1..8+: %llu %llu %llu %llu %llu %llu %llu %llu\n",
                        (unsigned long long)g_rg, double(g_rg_members) / double(g_rg), double(g_rg_sent) / double(g_rg),
                        (unsigned long long)g_rg_hist[0], (unsigned long long)g_rg_hist[1],
                        (unsigned long long)g_rg_hist[2], (unsigned long long)g_rg_hist[3],
                        (unsigned long long)g_rg_hist[4], (unsigned long long)g_rg_hist[5],
                        (unsigned long long)g_rg_hist[6], (unsigned long long)g_rg_hist[7]);
            fflush(stderr);
            for (int i = 0; i < kCount; i++) prev[i] = cur[i];
            prev_req = req;
            prev_bc = bc;
            prev_bn = bn;
        }
    }).detach();
}

}  // namespace prof
#endif
