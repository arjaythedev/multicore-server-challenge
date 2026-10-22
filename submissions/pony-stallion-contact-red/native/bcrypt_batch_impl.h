static inline __attribute__((always_inline)) void
BC_JOIN(BC_encrypt, BC_LANES)(struct BC_data *d, BF_word *L, BF_word *R)
{
    for (unsigned l = 0; l < BC_LANES; l++) L[l] ^= d[l].ctx.P[0];
    for (unsigned i = 1; i <= 16; i += 2) {
        for (unsigned l = 0; l < BC_LANES; l++)
            R[l] ^= BC_f(&d[l].ctx, L[l]) ^ d[l].ctx.P[i];
        for (unsigned l = 0; l < BC_LANES; l++)
            L[l] ^= BC_f(&d[l].ctx, R[l]) ^ d[l].ctx.P[i + 1];
    }
    for (unsigned l = 0; l < BC_LANES; l++) {
        BF_word t = L[l];
        L[l] = R[l] ^ d[l].ctx.P[17];
        R[l] = t;
    }
}

static inline __attribute__((always_inline)) void
BC_JOIN(BC_expand, BC_LANES)(struct BC_data *d, unsigned mode)
{
    if (mode == 1) {
        for (unsigned l = 0; l < BC_LANES; l++)
            for (unsigned i = 0; i < 18; i++)
                d[l].ctx.P[i] ^= d[l].expanded_key[i];
    } else if (mode == 2) {
        for (unsigned l = 0; l < BC_LANES; l++)
            for (unsigned i = 0; i < 18; i++)
                d[l].ctx.P[i] ^= d[l].binary.salt[i & 3];
    }
    BF_word L[BC_LANES] = {0}, R[BC_LANES] = {0};
#ifdef CONDUIT_PASSWORD_TEST
    conduit_test_expand(L, sizeof(L), R, sizeof(R));
#endif
    for (unsigned i = 0; i < 18; i += 2) {
        if (mode == 0) for (unsigned l = 0; l < BC_LANES; l++) {
            L[l] ^= d[l].binary.salt[i & 2];
            R[l] ^= d[l].binary.salt[(i & 2) + 1];
        }
        BC_JOIN(BC_encrypt, BC_LANES)(d, L, R);
        for (unsigned l = 0; l < BC_LANES; l++) {
            d[l].ctx.P[i] = L[l];
            d[l].ctx.P[i + 1] = R[l];
        }
    }
    for (unsigned b = 0; b < 4; b++) {
        for (unsigned i = 0; i < 256; i += 2) {
            if (mode == 0) for (unsigned l = 0; l < BC_LANES; l++) {
                L[l] ^= d[l].binary.salt[(i + 18) & 3];
                R[l] ^= d[l].binary.salt[(i + 19) & 3];
            }
            BC_JOIN(BC_encrypt, BC_LANES)(d, L, R);
            for (unsigned l = 0; l < BC_LANES; l++) {
                d[l].ctx.S[b][i] = L[l];
                d[l].ctx.S[b][i + 1] = R[l];
            }
        }
    }
    BC_wipe(L, sizeof(L));
    BC_wipe(R, sizeof(R));
}

static __attribute__((noinline)) int
BC_JOIN(BC_run, BC_LANES)(const char *const *keys, const size_t *lengths,
    const char *const *settings, char (*out)[61])
{
    struct BC_data d[BC_LANES];
    BF_word L[BC_LANES] = {0}, R[BC_LANES] = {0};
    unsigned cost = 0;
    int okay = 0;
#ifdef CONDUIT_PASSWORD_TEST
    conduit_test_run(BC_LANES, d, sizeof(d), L, sizeof(L), R, sizeof(R));
#endif
    for (unsigned l = 0; l < BC_LANES; l++) {
        const char *s = settings[l];
        if (strlen(s) < 29 || s[0] != '$' || s[1] != '2' ||
            s[2] != 'b' || s[3] != '$' || s[4] < '0' || s[4] > '3' ||
            s[5] < '0' || s[5] > '9' || s[6] != '$') goto cleanup;
        unsigned c = (s[4] - '0') * 10 + s[5] - '0';
        if (c < 4 || c > 31 || (l && c != cost)) goto cleanup;
        cost = c;
        if (BF_decode(d[l].binary.salt, s + 7, 16)) goto cleanup;
        BF_swap(d[l].binary.salt, 4);
        BF_set_key(keys[l], lengths[l], d[l].expanded_key, d[l].ctx.P, 4);
        memcpy(d[l].ctx.S, BF_init_state.S, sizeof(d[l].ctx.S));
    }
    BC_JOIN(BC_expand, BC_LANES)(d, 0);
    for (BF_word n = (BF_word)1 << cost; n; --n) {
        BC_JOIN(BC_expand, BC_LANES)(d, 1);
        BC_JOIN(BC_expand, BC_LANES)(d, 2);
    }
    for (unsigned i = 0; i < 6; i += 2) {
        for (unsigned l = 0; l < BC_LANES; l++) {
            L[l] = BF_magic_w[i];
            R[l] = BF_magic_w[i + 1];
        }
        for (unsigned j = 0; j < 64; j++)
            BC_JOIN(BC_encrypt, BC_LANES)(d, L, R);
        for (unsigned l = 0; l < BC_LANES; l++) {
            d[l].binary.output[i] = L[l];
            d[l].binary.output[i + 1] = R[l];
        }
    }
    for (unsigned l = 0; l < BC_LANES; l++) {
        memcpy(out[l], settings[l], 28);
        out[l][28] = BF_itoa64[
            BF_atoi64[(unsigned char)settings[l][28] - 0x20] & 0x30];
        BF_swap(d[l].binary.output, 6);
        BF_encode(out[l] + 29, d[l].binary.output, 23);
        out[l][60] = 0;
    }
#ifdef CONDUIT_PASSWORD_TEST
    if (!conduit_test_raw_result()) goto cleanup;
#endif
    okay = 1;
cleanup:
    BC_wipe(d, sizeof(d));
    BC_wipe(L, sizeof(L));
    BC_wipe(R, sizeof(R));
    return okay;
}
