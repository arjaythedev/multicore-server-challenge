/*
 * bcrypt's expensive part, in C: EksBlowfishSetup and the 64 final encryptions for up to 8 hashes at once.
 *
 * This is the same algorithm as conduit.security.BCrypt (Java), which prepares the inputs and formats the result.
 * A Blowfish round is a chain of dependent table lookups that leaves most of a core idle, so several independent
 * hashes run with their rounds interleaved: the CPU overlaps their lookups. In Java four lanes is the limit before
 * the JIT runs out of registers; C with 8 lanes keeps going (about 12-13 ms per hash at cost 10 instead of 20).
 * Every hash still does all 2^cost rounds with its own key and salt; nothing is shared between hashes or calls.
 *
 * Built by build.sh: cc -O3 -fPIC -shared -o target/libconduit-bcrypt.so native/bcrypt_lanes.c
 * (-O3 matters: the lane loops below must be fully unrolled for the lanes to live in registers.)
 */
#include <stdint.h>
#include <string.h>

#define P_WORDS 18                      /* the P-array */
#define STATE_WORDS (18 + 4 * 256)      /* P-array, then the four S-boxes */
#define S0 18
#define S1 (S0 + 256)
#define S2 (S1 + 256)
#define S3 (S2 + 256)
#define MAX_LANES 8

/* Blowfish's initial state (the digits of pi), handed over once by the Java side, which computes it. */
static uint32_t initial_state[STATE_WORDS];
static int initialized;

/* "OrpheanBeholderScryDoubt" as six big-endian words. */
static const uint32_t MAGIC[6] = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};

/* Blowfish's round function: four S-box lookups mixed with addition and xor. */
#define F(s, x) ((((s)[S0 + ((x) >> 24)] + (s)[S1 + (((x) >> 16) & 0xff)]) ^ (s)[S2 + (((x) >> 8) & 0xff)]) \
                 + (s)[S3 + ((x) & 0xff)])

/* One block, 16 rounds. */
static void encrypt(const uint32_t *s, uint32_t *left, uint32_t *right) {
    uint32_t l = *left ^ s[0], r = *right;
    for (int i = 1; i <= 16; i += 2) {
        r ^= F(s, l) ^ s[i];
        l ^= F(s, r) ^ s[i + 1];
    }
    *left = r ^ s[17];
    *right = l;
}

/*
 * Re-derives each lane's whole state from itself: starting from a zero block, each encryption's output replaces the
 * next two words of the P-array and then of the S-boxes (521 encryptions). The lanes' rounds are interleaved; with
 * `lanes` a constant (see the wrappers below) the compiler unrolls the lane loops and keeps l[] and r[] in registers.
 */
static inline __attribute__((always_inline)) void rekey(uint32_t st[][STATE_WORDS], const int lanes) {
    uint32_t l[MAX_LANES] = {0}, r[MAX_LANES] = {0};
    for (int i = 0; i < STATE_WORDS; i += 2) {
        for (int k = 0; k < lanes; k++) l[k] ^= st[k][0];
        for (int round = 1; round <= 16; round += 2) {
            for (int k = 0; k < lanes; k++) r[k] ^= F(st[k], l[k]) ^ st[k][round];
            for (int k = 0; k < lanes; k++) l[k] ^= F(st[k], r[k]) ^ st[k][round + 1];
        }
        for (int k = 0; k < lanes; k++) {
            uint32_t t = l[k];
            l[k] = r[k] ^ st[k][17];
            r[k] = t;
            st[k][i] = l[k];
            st[k][i + 1] = r[k];
        }
    }
}

static void rekey1(uint32_t st[][STATE_WORDS]) { rekey(st, 1); }
static void rekey2(uint32_t st[][STATE_WORDS]) { rekey(st, 2); }
static void rekey4(uint32_t st[][STATE_WORDS]) { rekey(st, 4); }
static void rekey6(uint32_t st[][STATE_WORDS]) { rekey(st, 6); }
static void rekey8(uint32_t st[][STATE_WORDS]) { rekey(st, 8); }

/* The initial state, then ExpandKey(state, salt, key): the salt (repeated) is the data stream. */
static void setup(uint32_t *s, const int32_t *key, const int32_t *salt) {
    memcpy(s, initial_state, sizeof initial_state);
    for (int i = 0; i < P_WORDS; i++) s[i] ^= (uint32_t) key[i];
    uint32_t l = 0, r = 0;
    for (int i = 0; i < STATE_WORDS; i += 2) {
        l ^= (uint32_t) salt[i % 4];
        r ^= (uint32_t) salt[(i + 1) % 4];
        encrypt(s, &l, &r);
        s[i] = l;
        s[i + 1] = r;
    }
}

/* Called once at startup with the 18 + 1024 words of Blowfish's initial state. Returns 1. */
int conduit_bcrypt_init(const int32_t *state) {
    memcpy(initial_state, state, sizeof initial_state);
    initialized = 1;
    return 1;
}

/*
 * Computes `count` (1..8) bcrypt hashes of the same cost:
 *   keys:  count x 18 words, each password's key (its bytes and a NUL, repeated to 72 bytes) as big-endian words
 *   salts: count x 4 words, each 16-byte salt as big-endian words
 *   out:   count x 6 words, "OrpheanBeholderScryDoubt" encrypted 64 times (the hash string encodes 23 of its bytes)
 * 3, 5 and 7 hashes run with the next wider kernel; its extra lanes repeat the last hash and are discarded.
 * Returns 1, or 0 if not initialized or the arguments are out of range.
 */
int conduit_bcrypt_lanes(int count, int cost, const int32_t *keys, const int32_t *salts, int32_t *out) {
    if (!initialized || count < 1 || count > MAX_LANES || cost < 4 || cost > 31) return 0;
    int width = count == 1 ? 1 : count == 2 ? 2 : count <= 4 ? 4 : count <= 6 ? 6 : 8;

    static __thread uint32_t st[MAX_LANES][STATE_WORDS];   /* 33 KB per thread: too big for comfort on the stack */
    const int32_t *key[MAX_LANES], *salt[MAX_LANES];
    for (int k = 0; k < width; k++) {
        int lane = k < count ? k : count - 1;
        key[k] = keys + 18 * lane;
        salt[k] = salts + 4 * lane;
        setup(st[k], key[k], salt[k]);
    }

    for (uint64_t round = 0, rounds = 1ull << cost; round < rounds; round++) {
        for (int k = 0; k < width; k++)
            for (int i = 0; i < P_WORDS; i++) st[k][i] ^= (uint32_t) key[k][i];
        switch (width) {
            case 1: rekey1(st); break;
            case 2: rekey2(st); break;
            case 4: rekey4(st); break;
            case 6: rekey6(st); break;
            default: rekey8(st); break;
        }
        for (int k = 0; k < width; k++)
            for (int i = 0; i < P_WORDS; i++) st[k][i] ^= (uint32_t) salt[k][i % 4];
        switch (width) {
            case 1: rekey1(st); break;
            case 2: rekey2(st); break;
            case 4: rekey4(st); break;
            case 6: rekey6(st); break;
            default: rekey8(st); break;
        }
    }

    for (int k = 0; k < count; k++) {
        uint32_t text[6];
        memcpy(text, MAGIC, sizeof text);
        for (int i = 0; i < 64; i++)
            for (int j = 0; j < 6; j += 2) encrypt(st[k], &text[j], &text[j + 1]);
        for (int j = 0; j < 6; j++) out[6 * k + j] = (int32_t) text[j];
    }
    memset(st, 0, sizeof st);                                 /* no key material left behind */
    return 1;
}
