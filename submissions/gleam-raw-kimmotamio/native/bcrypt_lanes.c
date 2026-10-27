/*
 * Multi-lane bcrypt: up to LANES independent hashes computed in lockstep, round by round, so the CPU can
 * overlap the dependent S-box loads of one hash with those of another. Every lane performs exactly the
 * work of the OpenBSD reference (same expansion order, same number of rounds, same output); only the
 * instruction interleaving differs. Lanes whose salts disagree on the cost are hashed one by one.
 *
 * This file includes bcrypt.c so it can reuse its base64 helpers; build this file instead of bcrypt.c.
 */
#include "bcrypt.c"

#define LANES 4

#define FX(s, x) ((((s)[(((x) >> 24) & 0xFF)] + (s)[0x100 + (((x) >> 16) & 0xFF)]) ^ (s)[0x200 + (((x) >> 8) & 0xFF)]) + (s)[0x300 + ((x) & 0xFF)])

/* One Blowfish block encryption per lane, interleaved. */
static inline void encipher_lanes(blf_ctx *c, u_int32_t *xl, u_int32_t *xr) {
    u_int32_t Xl[LANES], Xr[LANES];
    const u_int32_t *S[LANES], *P[LANES];
    int k, r;
    for (k = 0; k < LANES; k++) {
        S[k] = (const u_int32_t *)c[k].S;
        P[k] = c[k].P;
        Xl[k] = xl[k] ^ P[k][0];
        Xr[k] = xr[k];
    }
    for (r = 1; r <= BLF_N; r += 2) {
        for (k = 0; k < LANES; k++) Xr[k] ^= FX(S[k], Xl[k]) ^ P[k][r];
        for (k = 0; k < LANES; k++) Xl[k] ^= FX(S[k], Xr[k]) ^ P[k][r + 1];
    }
    for (k = 0; k < LANES; k++) {
        xl[k] = Xr[k] ^ P[k][BLF_N + 1];
        xr[k] = Xl[k];
    }
}

/* Blowfish_expand0state for every lane at once. */
static void expand0state_lanes(blf_ctx *c, const u_int8_t **key, const u_int16_t *keybytes) {
    u_int16_t i, j, k;
    int l;
    u_int32_t datal[LANES], datar[LANES];
    for (l = 0; l < LANES; l++) {
        j = 0;
        for (i = 0; i < BLF_N + 2; i++) c[l].P[i] ^= Blowfish_stream2word(key[l], keybytes[l], &j);
        datal[l] = 0;
        datar[l] = 0;
    }
    for (i = 0; i < BLF_N + 2; i += 2) {
        encipher_lanes(c, datal, datar);
        for (l = 0; l < LANES; l++) {
            c[l].P[i] = datal[l];
            c[l].P[i + 1] = datar[l];
        }
    }
    for (i = 0; i < 4; i++) {
        for (k = 0; k < 256; k += 2) {
            encipher_lanes(c, datal, datar);
            for (l = 0; l < LANES; l++) {
                c[l].S[i][k] = datal[l];
                c[l].S[i][k + 1] = datar[l];
            }
        }
    }
}

/* Blowfish_expandstate (salted) for every lane at once. */
static void expandstate_lanes(blf_ctx *c, const u_int8_t **data, const u_int16_t *databytes,
                              const u_int8_t **key, const u_int16_t *keybytes) {
    u_int16_t i, j[LANES], k;
    int l;
    u_int32_t datal[LANES], datar[LANES];
    for (l = 0; l < LANES; l++) {
        u_int16_t kj = 0;
        for (i = 0; i < BLF_N + 2; i++) c[l].P[i] ^= Blowfish_stream2word(key[l], keybytes[l], &kj);
        j[l] = 0;
        datal[l] = 0;
        datar[l] = 0;
    }
    for (i = 0; i < BLF_N + 2; i += 2) {
        for (l = 0; l < LANES; l++) {
            datal[l] ^= Blowfish_stream2word(data[l], databytes[l], &j[l]);
            datar[l] ^= Blowfish_stream2word(data[l], databytes[l], &j[l]);
        }
        encipher_lanes(c, datal, datar);
        for (l = 0; l < LANES; l++) {
            c[l].P[i] = datal[l];
            c[l].P[i + 1] = datar[l];
        }
    }
    for (i = 0; i < 4; i++) {
        for (k = 0; k < 256; k += 2) {
            for (l = 0; l < LANES; l++) {
                datal[l] ^= Blowfish_stream2word(data[l], databytes[l], &j[l]);
                datar[l] ^= Blowfish_stream2word(data[l], databytes[l], &j[l]);
            }
            encipher_lanes(c, datal, datar);
            for (l = 0; l < LANES; l++) {
                c[l].S[i][k] = datal[l];
                c[l].S[i][k + 1] = datar[l];
            }
        }
    }
}

typedef struct {
    u_int8_t csalt[BCRYPT_MAXSALT];
    u_int8_t logr, minor;
    u_int8_t key_len;
    const char *key;
    int ok;
} lane_salt;

/* Parses "$2a$NN$<22 chars>" exactly like ts_bcrypt does. */
static int parse_salt(const char *salt, lane_salt *out) {
    int n;
    salt++;
    if (*salt > BCRYPT_VERSION) return -1;
    if (salt[1] != '$') {
        switch (salt[1]) {
        case 'a': case 'b': case 'y':
            out->minor = salt[1];
            salt++;
            break;
        default:
            return -1;
        }
    } else
        out->minor = 0;
    salt += 2;
    if (salt[2] != '$') return -1;
    n = atoi(salt);
    if (n > 31 || n < 0) return -1;
    out->logr = (u_int8_t)n;
    if (((u_int32_t)1 << out->logr) < BCRYPT_MINROUNDS) return -1;
    salt += 3;
    if (strlen(salt) * 3 / 4 < BCRYPT_MAXSALT) return -1;
    decode_base64(out->csalt, BCRYPT_MAXSALT, (u_int8_t *)salt);
    return 0;
}

/*
 * n hashes (1..LANES) in lockstep. keys/salts are NUL-terminated; outs[i] must hold 64 bytes. Returns 0
 * when every lane succeeded; a lane that fails leaves outs[i][0] == 0.
 */
int bcrypt_lanes(int n, const char **keys, const char **salts, char **outs) {
    blf_ctx state[LANES];
    lane_salt ls[LANES];
    const u_int8_t *keyp[LANES], *saltp[LANES];
    u_int16_t keylen[LANES], saltlen[LANES];
    u_int32_t cdata[LANES][BCRYPT_BLOCKS];
    u_int8_t ciphertext[LANES][4 * BCRYPT_BLOCKS];
    u_int32_t rounds, k;
    u_int16_t j;
    int l, i, all_ok = 0, same_cost = 1;

    for (l = 0; l < n; l++) {
        outs[l][0] = 0;
        ls[l].ok = parse_salt(salts[l], &ls[l]) == 0;
        ls[l].key = keys[l];
        if (!ls[l].ok) all_ok = -1;
        if (l > 0 && ls[l].logr != ls[0].logr) same_cost = 0;
    }
    if (all_ok != 0 || !same_cost || n < 2) {
        /* Fall back to the reference routine lane by lane. */
        for (l = 0; l < n; l++) {
            if (ls[l].ok && ts_bcrypt(outs[l], keys[l], salts[l]) != 0) outs[l][0] = 0;
        }
        return all_ok;
    }
    /* Unused lanes repeat lane 0: the same work, discarded. */
    for (l = 0; l < LANES; l++) {
        const lane_salt *s = &ls[l < n ? l : 0];
        keyp[l] = (const u_int8_t *)s->key;
        keylen[l] = (u_int16_t)(strlen(s->key) + (s->minor >= 'a' ? 1 : 0));
        saltp[l] = s->csalt;
        saltlen[l] = BCRYPT_MAXSALT;
        Blowfish_initstate(&state[l]);
    }
    rounds = (u_int32_t)1 << ls[0].logr;
    expandstate_lanes(state, saltp, saltlen, keyp, keylen);
    for (k = 0; k < rounds; k++) {
        expand0state_lanes(state, keyp, keylen);
        expand0state_lanes(state, saltp, saltlen);
    }
    for (l = 0; l < LANES; l++) {
        memcpy(ciphertext[l], "OrpheanBeholderScryDoubt", 4 * BCRYPT_BLOCKS);
        j = 0;
        for (i = 0; i < BCRYPT_BLOCKS; i++) cdata[l][i] = Blowfish_stream2word(ciphertext[l], 4 * BCRYPT_BLOCKS, &j);
    }
    for (k = 0; k < 64; k++) {
        for (i = 0; i < BCRYPT_BLOCKS; i += 2) {
            u_int32_t xl[LANES], xr[LANES];
            for (l = 0; l < LANES; l++) {
                xl[l] = cdata[l][i];
                xr[l] = cdata[l][i + 1];
            }
            encipher_lanes(state, xl, xr);
            for (l = 0; l < LANES; l++) {
                cdata[l][i] = xl[l];
                cdata[l][i + 1] = xr[l];
            }
        }
    }
    for (l = 0; l < n; l++) {
        char *encrypted = outs[l];
        for (i = 0; i < BCRYPT_BLOCKS; i++) {
            ciphertext[l][4 * i + 3] = cdata[l][i] & 0xff;
            cdata[l][i] = cdata[l][i] >> 8;
            ciphertext[l][4 * i + 2] = cdata[l][i] & 0xff;
            cdata[l][i] = cdata[l][i] >> 8;
            ciphertext[l][4 * i + 1] = cdata[l][i] & 0xff;
            cdata[l][i] = cdata[l][i] >> 8;
            ciphertext[l][4 * i + 0] = cdata[l][i] & 0xff;
        }
        i = 0;
        encrypted[i++] = '$';
        encrypted[i++] = BCRYPT_VERSION;
        if (ls[l].minor) encrypted[i++] = ls[l].minor;
        encrypted[i++] = '$';
        snprintf(encrypted + i, 4, "%2.2u$", ls[l].logr);
        encode_base64((u_int8_t *)encrypted + i + 3, ls[l].csalt, BCRYPT_MAXSALT);
        encode_base64((u_int8_t *)encrypted + strlen(encrypted), ciphertext[l], 4 * BCRYPT_BLOCKS - 1);
    }
    memset(state, 0, sizeof(state));
    memset(cdata, 0, sizeof(cdata));
    memset(ciphertext, 0, sizeof(ciphertext));
    return 0;
}
