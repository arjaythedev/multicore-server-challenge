#include <openssl/rand.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *test_case = "selector";
#define CHECK(c) do { if (!(c)) { \
    fprintf(stderr, "%s:%d: %s\n", test_case, __LINE__, #c); exit(1); \
} } while (0)

struct span { const void *pointer; size_t size; unsigned seen; };
static struct span core[3], wrapper[2], expansion[2];
static unsigned runs, expansion_calls, wipes, nonzero_wipes, key_calls;
static size_t expected_geometry;
static int fault_lane = -1, fault_guard, fault_key;
static unsigned entropy_calls;
static int entropy_fail = -1;

static void require_seen(struct span *spans, size_t count)
{
    for (size_t i = 0; i < count; i++)
        if (spans[i].pointer) CHECK(spans[i].seen == 1);
}

static void conduit_test_buffers(void *a, void *b, size_t size, size_t count)
{
    expected_geometry = count;
    wrapper[0] = (struct span){a, size, 0};
    wrapper[1] = (struct span){b, size, 0};
    memset(a, 0xa5, size);
    memset(b, 0xa5, size);
    memset(core, 0, sizeof(core));
    memset(expansion, 0, sizeof(expansion));
    runs = expansion_calls = 0;
}

static void conduit_test_run(size_t lanes, void *d, size_t ds,
    void *l, size_t ls, void *r, size_t rs)
{
    require_seen(core, 3);
    require_seen(expansion, 2);
    CHECK(lanes == expected_geometry);
    core[0] = (struct span){d, ds, 0};
    core[1] = (struct span){l, ls, 0};
    core[2] = (struct span){r, rs, 0};
    memset(d, 0xa5, ds);
    memset(l, 0xa5, ls);
    memset(r, 0xa5, rs);
    memset(expansion, 0, sizeof(expansion));
    runs++;
}

static void conduit_test_expand(void *l, size_t ls, void *r, size_t rs)
{
    require_seen(expansion, 2);
    expansion[0] = (struct span){l, ls, 0};
    expansion[1] = (struct span){r, rs, 0};
    expansion_calls++;
}

static void conduit_test_wiping(const void *p, size_t size)
{
    const unsigned char *bytes = p;
    unsigned nonzero = 0;
    for (size_t i = 0; i < size; i++) nonzero |= bytes[i];
    nonzero_wipes += nonzero != 0;
}

static void conduit_test_wiped(const void *p, size_t size)
{
    const unsigned char *bytes = p;
    for (size_t i = 0; i < size; i++) CHECK(bytes[i] == 0);
    struct span *groups[] = {core, wrapper, expansion};
    size_t counts[] = {3, 2, 2};
    for (size_t g = 0; g < 3; g++)
        for (size_t i = 0; i < counts[g]; i++)
            if (groups[g][i].pointer == p && groups[g][i].size == size)
                groups[g][i].seen++;
    wipes++;
}

static int conduit_test_guard(char (*guard)[61], size_t count)
{
    CHECK(runs == 2);
    require_seen(core, 3);
    require_seen(expansion, 2);
    if (fault_lane >= 0) {
        CHECK((size_t)fault_lane < count);
        guard[fault_lane][40] ^= 1;
    }
    return 1;
}

static int conduit_test_raw_result(void)
{
    return !(fault_guard && runs == 2);
}

static void conduit_test_key_enter(void) { key_calls++; }
static int conduit_test_key_check(int okay)
{
    CHECK(okay && key_calls > 0);
    return !fault_key;
}

#define CONDUIT_PASSWORD_TEST
#include "crypt_blowfish.c"

static int test_rand(unsigned char *bytes, int length)
{
    unsigned call = entropy_calls++;
    if ((int)call == entropy_fail) return 0;
    for (int i = 0; i < length; i++) bytes[i] = call * 19 + i * 7;
    return 1;
}

#define RAND_bytes test_rand
#include "password.c"
#undef RAND_bytes

static const char *vectors[] = {
    "$2b$10$......................F5mzCEQ5E01or2Zs1UUMeqS/7rfVb16",
    "$2b$10$......................naFBfND/0rjnzNKXE2KCY4zIW5UdykO",
    "$2b$10$......................a2md9ZUXOMO5mFpVaptzVNswqH//l/y",
    "$2b$10$......................fiFpKnksqdh4kPbcKBE07aRafSx.Ybu"};
static const uint8_t nul_key[] = {'a', 0, 'b'};
static const uint8_t utf_key[] =
    {'p', 0xc3, 0xa4, 's', 's', 'w', 0xc3, 0xb6, 'r', 'd'};

struct batch {
    uint8_t kinds[4], output[4][60], statuses[4];
    const uint8_t *passwords[4], *hashes[4];
    uint8_t *outputs[4];
    size_t lengths[4], hash_lengths[4], execution[2];
};

static void init(struct batch *b)
{
    memset(b, 0xa5, sizeof(*b));
    const uint8_t *keys[] = {(const uint8_t *)"",
        (const uint8_t *)"password123", nul_key, utf_key};
    size_t sizes[] = {0, 11, sizeof(nul_key), sizeof(utf_key)};
    for (size_t i = 0; i < 4; i++) {
        b->kinds[i] = CONDUIT_VERIFY;
        b->passwords[i] = keys[i];
        b->lengths[i] = sizes[i];
        b->hashes[i] = (const uint8_t *)vectors[i];
        b->hash_lengths[i] = 60;
        b->outputs[i] = b->output[i];
    }
}

static int call(struct batch *b, size_t count)
{
    return conduit_password_batch(count, b->kinds, b->passwords, b->lengths,
        b->hashes, b->hash_lengths, b->outputs, b->statuses, b->execution);
}

static void descriptors(void)
{
    struct batch b, saved;
    for (unsigned which = 0; which < 16; which++) {
        init(&b);
        size_t n = 4;
        if (which == 0) n = 0;
        if (which == 1) n = 5;
        if (which >= 10 && which <= 13) b.kinds[which - 10] = 2;
        if (which == 14) b.passwords[3] = NULL;
        if (which == 15) b.hashes[3] = NULL;
        saved = b;
        int result = conduit_password_batch(n,
            which == 2 ? NULL : b.kinds,
            which == 3 ? NULL : b.passwords,
            which == 4 ? NULL : b.lengths,
            which == 5 ? NULL : b.hashes,
            which == 6 ? NULL : b.hash_lengths,
            which == 7 ? NULL : b.outputs,
            which == 8 ? NULL : b.statuses,
            which == 9 ? NULL : b.execution);
        CHECK(result == 0);
        CHECK(memcmp(&b, &saved, sizeof(b)) == 0);
    }
    init(&b);
    b.kinds[3] = CONDUIT_HASH;
    b.outputs[3] = NULL;
    saved = b;
    CHECK(call(&b, 4) == 0);
    CHECK(memcmp(&b, &saved, sizeof(b)) == 0);
    init(&b);
    b.passwords[0] = NULL;
    b.outputs[0] = NULL;
    CHECK(call(&b, 1) == 1);
    CHECK(b.statuses[0] == CONDUIT_VERIFIED);
    b.hashes[0] = NULL;
    b.hash_lengths[0] = 0;
    CHECK(call(&b, 1) == 1);
    CHECK(b.statuses[0] == CONDUIT_REJECTED);
}

static void fixed_vectors(void)
{
    struct batch b;
    for (size_t n = 1; n <= 4; n++) {
        init(&b);
        CHECK(call(&b, n) == 1);
        CHECK(b.execution[0] == (n == 1 ? 0 : n));
        CHECK(b.execution[1] == (n == 1 ? 1 : 0));
        for (size_t i = 0; i < n; i++) {
            CHECK(b.statuses[i] == CONDUIT_VERIFIED);
            for (size_t j = 0; j < 60; j++) CHECK(b.output[i][j] == 0xa5);
        }
        for (size_t i = n; i < 4; i++) CHECK(b.statuses[i] == 0xa5);
        if (n > 1) {
            char output[4][61];
            const char *keys[4], *settings[4];
            for (size_t i = 0; i < n; i++) {
                keys[i] = (const char *)b.passwords[i];
                settings[i] = vectors[i];
            }
            CHECK(_crypt_blowfish_batch_rn(keys, b.lengths, settings,
                output, n));
            for (size_t i = 0; i < n; i++)
                CHECK(memcmp(output[i], vectors[i], 61) == 0);
        }
    }
    CHECK(conduit_password_selftest());
}

static void entropy(void)
{
    struct batch b;
    for (size_t n = 2; n <= 4; n++) {
        init(&b);
        entropy_calls = 0;
        for (size_t i = 0; i < n; i++) b.kinds[i] = CONDUIT_HASH;
        CHECK(call(&b, n) == 1);
        CHECK(entropy_calls == n);
        for (size_t i = 0; i < n; i++) {
            unsigned char salt[16];
            char setting[30], expected[61];
            for (size_t j = 0; j < 16; j++) salt[j] = i * 19 + j * 7;
            CHECK(_crypt_gensalt_blowfish_rn("$2b$", 10,
                (const char *)salt, 16, setting, 30));
            CHECK(_crypt_blowfish_len_rn((const char *)b.passwords[i],
                b.lengths[i], setting, expected, 61));
            CHECK(b.statuses[i] == CONDUIT_HASHED);
            CHECK(memcmp(b.output[i], expected, 60) == 0);
        }
        entropy_calls = 0;
        entropy_fail = 1;
        memset(b.output, 0xa5, sizeof(b.output));
        CHECK(call(&b, n) == 1);
        CHECK(b.statuses[1] == CONDUIT_FAILED);
        CHECK(b.execution[0] == (n > 2 ? n - 1 : 0));
        CHECK(b.execution[1] == (n == 2 ? 1 : 0));
        for (size_t i = 0; i < n; i++) {
            if (i == 1) {
                for (size_t j = 0; j < 60; j++)
                    CHECK(b.output[i][j] == 0xa5);
            } else {
                unsigned char salt[16];
                char setting[30], expected[61];
                for (size_t j = 0; j < 16; j++) salt[j] = i * 19 + j * 7;
                CHECK(_crypt_gensalt_blowfish_rn("$2b$", 10,
                    (const char *)salt, 16, setting, 30));
                CHECK(_crypt_blowfish_len_rn((const char *)b.passwords[i],
                    b.lengths[i], setting, expected, 61));
                CHECK(b.statuses[i] == CONDUIT_HASHED);
                CHECK(memcmp(b.output[i], expected, 60) == 0);
            }
        }
        entropy_fail = -1;
    }
}

static void guards(void)
{
    struct batch b;
    for (size_t n = 2; n <= 4; n++) {
        for (int fault = 0; fault < (int)n + 2; fault++) {
            init(&b);
            for (size_t i = 0; i < n; i++) b.kinds[i] = CONDUIT_HASH;
            fault_lane = fault < (int)n ? fault : -1;
            fault_guard = fault == (int)n;
            fault_key = fault == (int)n + 1;
            nonzero_wipes = wipes = key_calls = 0;
            CHECK(call(&b, n) == 1);
            CHECK(b.execution[0] == n && b.execution[1] == 0);
            for (size_t i = 0; i < n; i++) {
                CHECK(b.statuses[i] == CONDUIT_FAILED);
                for (size_t j = 0; j < 60; j++)
                    CHECK(b.output[i][j] == 0xa5);
            }
            require_seen(core, 3);
            require_seen(expansion, 2);
            require_seen(wrapper, 2);
            CHECK(runs == 2 && expansion_calls > 0);
            CHECK(wipes > 0 && nonzero_wipes > 0);
            const char *keys[4], *settings[4];
            char raw[4][61];
            for (size_t i = 0; i < n; i++) {
                keys[i] = (const char *)b.passwords[i];
                settings[i] = vectors[i];
            }
            memset(raw, 0xa5, sizeof(raw));
            CHECK(!_crypt_blowfish_batch_rn(keys, b.lengths, settings,
                raw, n));
            for (size_t i = 0; i < sizeof(raw); i++)
                CHECK(((unsigned char *)raw)[i] == 0xa5);
            fault_lane = -1;
            fault_guard = fault_key = 0;
        }
        init(&b);
        CHECK(call(&b, n) == 1);
        for (size_t i = 0; i < n; i++)
            CHECK(b.statuses[i] == CONDUIT_VERIFIED);
    }
    fault_lane = 0;
    CHECK(!conduit_password_selftest());
    fault_lane = -1;
    CHECK(conduit_password_selftest());
}

static void policy(void)
{
    char hash[61], setting[61];
    const size_t positions[] = {0, 1, 2, 3, 4, 5, 6, 7, 10, 28, 29, 40, 59};
    for (unsigned cost = 0; cost <= 33; cost++) {
        memcpy(hash, vectors[1], 61);
        hash[4] = '0' + cost / 10;
        hash[5] = '0' + cost % 10;
        CHECK(prepare_verify((const uint8_t *)hash, 60, setting) ==
            (cost >= 4 && cost <= 31));
    }
    for (size_t i = 0; i < sizeof(positions) / sizeof(positions[0]); i++) {
        memcpy(hash, vectors[1], 61);
        hash[positions[i]] = '!';
        CHECK(!prepare_verify((const uint8_t *)hash, 60, setting));
    }
    memcpy(hash, vectors[1], 61);
    hash[28] = '/';
    CHECK(!prepare_verify((const uint8_t *)hash, 60, setting));
    memcpy(hash, vectors[1], 61);
    hash[59] = 'P';
    CHECK(!prepare_verify((const uint8_t *)hash, 60, setting));
    memcpy(hash, vectors[1], 61);
    hash[10] = 0;
    CHECK(!prepare_verify((const uint8_t *)hash, 60, setting));
    CHECK(!prepare_verify((const uint8_t *)vectors[1], 59, setting));
    CHECK(!prepare_verify((const uint8_t *)vectors[1], 61, setting));
    const char versions[] = {'a', 'b', 'x', 'y'};
    for (size_t i = 0; i < 4; i++) {
        struct batch b;
        init(&b);
        memcpy(hash, vectors[3], 61);
        hash[2] = versions[i];
        b.hashes[3] = (const uint8_t *)hash;
        CHECK(call(&b, 4) == 1);
        CHECK(b.statuses[3] == CONDUIT_VERIFIED);
        CHECK(prepare_verify((const uint8_t *)hash, 60, setting));
        CHECK(setting[2] == 'b');
    }
}

static void mixed(void)
{
    struct batch b;
    char fallback[61];
    CHECK(_crypt_blowfish_len_rn("password123", 11,
        "$2b$04$......................", fallback, 61));
    for (size_t hole = 0; hole < 4; hole++) {
        init(&b);
        b.hash_lengths[hole] = 59;
        CHECK(call(&b, 4) == 1);
        for (size_t i = 0; i < 4; i++)
            CHECK(b.statuses[i] == (i == hole ?
                CONDUIT_REJECTED : CONDUIT_VERIFIED));
        CHECK(b.execution[0] == 3 && b.execution[1] == 0);
    }
    init(&b);
    b.hashes[1] = (const uint8_t *)fallback;
    b.hash_lengths[2] = 59;
    CHECK(call(&b, 4) == 1);
    CHECK(b.statuses[0] == CONDUIT_VERIFIED);
    CHECK(b.statuses[1] == CONDUIT_VERIFIED);
    CHECK(b.statuses[2] == CONDUIT_REJECTED);
    CHECK(b.statuses[3] == CONDUIT_VERIFIED);
    CHECK(b.execution[0] == 2 && b.execution[1] == 1);
    fault_lane = 1;
    CHECK(call(&b, 4) == 1);
    CHECK(b.statuses[0] == CONDUIT_FAILED);
    CHECK(b.statuses[1] == CONDUIT_VERIFIED);
    CHECK(b.statuses[2] == CONDUIT_REJECTED);
    CHECK(b.statuses[3] == CONDUIT_FAILED);
    CHECK(b.execution[0] == 2 && b.execution[1] == 1);
    fault_lane = -1;
    b.hash_lengths[3] = 59;
    CHECK(call(&b, 4) == 1);
    CHECK(b.execution[0] == 0 && b.execution[1] == 2);
    b.hash_lengths[0] = b.hash_lengths[1] = 59;
    CHECK(call(&b, 4) == 1);
    CHECK(b.execution[0] == 0 && b.execution[1] == 0);
    for (size_t i = 0; i < 4; i++)
        CHECK(b.statuses[i] == CONDUIT_REJECTED);
    const unsigned costs[] = {9, 11};
    for (size_t i = 0; i < 2; i++) {
        char setting[] = "$2b$09$......................";
        setting[4] = '0' + costs[i] / 10;
        setting[5] = '0' + costs[i] % 10;
        CHECK(_crypt_blowfish_len_rn("password123", 11, setting,
            fallback, 61));
        init(&b);
        b.hashes[1] = (const uint8_t *)fallback;
        b.hash_lengths[2] = 59;
        CHECK(call(&b, 4) == 1);
        CHECK(b.statuses[1] == CONDUIT_VERIFIED);
        CHECK(b.execution[0] == 2 && b.execution[1] == 1);
    }
    init(&b);
    CHECK(conduit_verify(b.passwords[1], b.lengths[1], b.hashes[1], 60));
    CHECK(conduit_verify(b.passwords[3], b.lengths[3], b.hashes[3], 60));
    CHECK(!conduit_verify(b.passwords[1], b.lengths[1], b.hashes[3], 60));
    CHECK(!conduit_verify(b.passwords[3], b.lengths[3], b.hashes[1], 60));
    b.hash_lengths[0] = b.hash_lengths[2] = 59;
    b.passwords[3] = b.passwords[1];
    b.lengths[3] = b.lengths[1];
    CHECK(call(&b, 4) == 1);
    CHECK(b.execution[0] == 2 && b.execution[1] == 0);
    CHECK(b.statuses[0] == CONDUIT_REJECTED);
    CHECK(b.statuses[1] == CONDUIT_VERIFIED);
    CHECK(b.statuses[2] == CONDUIT_REJECTED);
    CHECK(b.statuses[3] == CONDUIT_REJECTED);
    const uint8_t *hash = b.hashes[1];
    b.hashes[1] = b.hashes[3];
    b.hashes[3] = hash;
    CHECK(call(&b, 4) == 1);
    CHECK(b.execution[0] == 2 && b.execution[1] == 0);
    CHECK(b.statuses[1] == CONDUIT_REJECTED);
    CHECK(b.statuses[3] == CONDUIT_VERIFIED);
}

static void bytes(void)
{
    const size_t sizes[] = {0, 1, 71, 72, 73};
    unsigned lengths_seen[5] = {0}, counts_seen[4] = {0};
    uint8_t key[73], other[73];
    for (size_t sample = 0; sample < 12; sample++) {
        size_t length = sizes[sample % 5];
        size_t count = sample % 4 + 1;
        lengths_seen[sample % 5]++;
        counts_seen[count - 1]++;
        for (size_t j = 0; j < sizeof(key); j++)
            key[j] = (sample * 37 + j * 19) & 255;
        if (length > 2) key[1] = 0;
        struct batch b;
        init(&b);
        b.kinds[0] = CONDUIT_HASH;
        b.passwords[0] = key;
        b.lengths[0] = length;
        CHECK(call(&b, count) == 1);
        CHECK(b.statuses[0] == (length <= 72 ?
            CONDUIT_HASHED : CONDUIT_FAILED));
        size_t eligible = count - (length > 72);
        CHECK(b.execution[0] == (eligible >= 2 ? eligible : 0));
        CHECK(b.execution[1] == (eligible == 1 ? 1 : 0));
        if (length <= 72) {
            CHECK(conduit_verify(key, length, b.output[0], 60));
            char expected[61], setting[61];
            memcpy(setting, b.output[0], 60);
            setting[60] = 0;
            CHECK(_crypt_blowfish_len_rn((const char *)key, length,
                setting, expected, 61));
            CHECK(memcmp(expected, b.output[0], 60) == 0);
            memcpy(other, key, sizeof(key));
            if (length) {
                other[length - 1] ^= 0x40;
                CHECK(!conduit_verify(other, length, b.output[0], 60));
            }
            if (length == 72) {
                other[71] = key[71];
                other[72] ^= 0x80;
                CHECK(conduit_verify(other, 73, b.output[0], 60));
            }
        }
        for (size_t i = 1; i < count; i++)
            CHECK(b.statuses[i] == CONDUIT_VERIFIED);
        struct batch permuted;
        init(&permuted);
        for (size_t j = 0; j < count; j++) {
            size_t src = (j + sample + 1) % count;
            permuted.kinds[j] = b.kinds[src];
            permuted.passwords[j] = b.passwords[src];
            permuted.lengths[j] = b.lengths[src];
            permuted.hashes[j] = b.hashes[src];
            permuted.hash_lengths[j] = b.hash_lengths[src];
        }
        CHECK(call(&permuted, count) == 1);
        CHECK(permuted.execution[0] == b.execution[0]);
        CHECK(permuted.execution[1] == b.execution[1]);
        for (size_t j = 0; j < count; j++) {
            size_t src = (j + sample + 1) % count;
            CHECK(permuted.statuses[j] == b.statuses[src]);
            if (permuted.kinds[j] == CONDUIT_HASH && length <= 72)
                CHECK(conduit_verify(permuted.passwords[j],
                    permuted.lengths[j], permuted.output[j], 60));
        }
    }
    for (size_t i = 0; i < 5; i++) CHECK(lengths_seen[i] > 0);
    for (size_t i = 0; i < 4; i++) CHECK(counts_seen[i] > 0);
}

static void grammar(void)
{
    unsigned classes[8] = {0};
    unsigned alphabets[2] = {0};
    for (size_t sample = 0; sample < 56; sample++) {
        char hash[61], prepared[61];
        BF_word words[6];
        for (size_t j = 0; j < 6; j++)
            words[j] = (sample + 1) * 0x01030709u + j * 0x1020304u;
        memcpy(hash, "$2b$04$", 7);
        hash[2] = "abxy"[sample % 4];
        unsigned cost = 4 + sample % 28;
        hash[4] = '0' + cost / 10;
        hash[5] = '0' + cost % 10;
        BF_encode(hash + 7, words, 16);
        BF_encode(hash + 29, words, 23);
        hash[60] = 0;
        CHECK(prepare_verify((const uint8_t *)hash, 60, prepared));
        CHECK(prepared[2] == 'b');
        CHECK(prepared[4] == hash[4] && prepared[5] == hash[5]);
        size_t length = 60;
        unsigned rule = sample % 8;
        switch (rule) {
        case 0: length = 59; break;
        case 1: hash[(sample % 3 == 0) ? 0 : 6] = '!'; break;
        case 2: hash[2] = 'c'; break;
        case 3: hash[4] = '+'; break;
        case 4: hash[10] = 0; break;
        case 5:
            alphabets[(sample / 8) % 2]++;
            hash[((sample / 8) % 2) ? 8 : 40] = '!';
            break;
        case 6: hash[28] = '/'; break;
        case 7: hash[59] = '/'; break;
        }
        classes[rule]++;
        CHECK(!prepare_verify((const uint8_t *)hash, length, prepared));
    }
    for (size_t i = 0; i < 8; i++) CHECK(classes[i] > 0);
    CHECK(alphabets[0] > 0 && alphabets[1] > 0);
    for (size_t position = 7; position < 60; position++) {
        char hash[61], prepared[61], label[32];
        snprintf(label, sizeof(label), "grammar-alphabet-%zu", position);
        test_case = label;
        memcpy(hash, vectors[1], 61);
        CHECK(prepare_verify((const uint8_t *)hash, 60, prepared));
        hash[position] = '!';
        CHECK(!prepare_verify((const uint8_t *)hash, 60, prepared));
    }
    test_case = "grammar";
    for (size_t position = 29; position <= 59; position += 30) {
        struct batch b;
        char hash[61];
        init(&b);
        memcpy(hash, vectors[1], 61);
        hash[position] = hash[position] == '.' ? 'C' : '.';
        b.hashes[1] = (const uint8_t *)hash;
        CHECK(call(&b, 4) == 1);
        CHECK(b.statuses[1] == CONDUIT_REJECTED);
        CHECK(b.statuses[0] == CONDUIT_VERIFIED);
    }
}

static void cleanup(void)
{
    struct batch b;
    init(&b);
    for (size_t n = 2; n <= 4; n++) {
        const char *keys[4], *settings[4];
        char output[4][61];
        for (size_t i = 0; i < n; i++) {
            keys[i] = (const char *)b.passwords[i];
            settings[i] = vectors[i];
        }
        settings[n - 1] = "$2b$03$......................";
        memset(output, 0xa5, sizeof(output));
        CHECK(!_crypt_blowfish_batch_rn(keys, b.lengths, settings,
            output, n));
        CHECK(runs == 1 && expansion_calls == 0);
        require_seen(core, 3);
        require_seen(wrapper, 2);
        for (size_t i = 0; i < sizeof(output); i++)
            CHECK(((unsigned char *)output)[i] == 0xa5);
    }
}

int main(int argc, char **argv)
{
    const char *names[] = {"descriptors", "vectors", "entropy", "guards",
        "policy", "mixed", "bytes", "cleanup", "grammar"};
    void (*tests[])(void) = {descriptors, fixed_vectors, entropy, guards,
        policy, mixed, bytes, cleanup, grammar};
    int selected = 0;
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
        if (argc > 1 && strcmp(argv[1], names[i])) continue;
        selected = 1;
        test_case = names[i];
        tests[i]();
        printf("batch %s passed\n", test_case);
    }
    CHECK(selected);
    return 0;
}
