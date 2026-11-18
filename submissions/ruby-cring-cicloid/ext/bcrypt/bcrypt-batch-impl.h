/* Included for each fixed lane count, so the compiler can schedule independent loads. */
static inline __attribute__((always_inline)) void JOIN(batch_encrypt, LANES)(
    struct BF_data *d, BF_word *L, BF_word *R) {
    for (unsigned l = 0; l < LANES; ++l) L[l] ^= d[l].ctx.P[0];
    for (unsigned i = 1; i <= 16; i += 2) {
        for (unsigned l = 0; l < LANES; ++l)
            R[l] ^= batch_f(&d[l].ctx, L[l]) ^ d[l].ctx.P[i];
        for (unsigned l = 0; l < LANES; ++l)
            L[l] ^= batch_f(&d[l].ctx, R[l]) ^ d[l].ctx.P[i+1];
    }
    for (unsigned l = 0; l < LANES; ++l) {
        BF_word t = L[l]; L[l] = R[l] ^ d[l].ctx.P[17]; R[l] = t;
    }
}

/* mode 0: initial salted expansion, 1: password, 2: salt used as key. */
static inline __attribute__((always_inline)) void JOIN(batch_expand, LANES)(
    struct BF_data *d, unsigned mode) {
    if (mode == 1) {
        for (unsigned l = 0; l < LANES; ++l)
            for (unsigned i = 0; i < 18; ++i) d[l].ctx.P[i] ^= d[l].expanded_key[i];
    } else if (mode == 2) {
        for (unsigned l = 0; l < LANES; ++l)
            for (unsigned i = 0; i < 18; ++i) d[l].ctx.P[i] ^= d[l].binary.salt[i & 3];
    }
    BF_word L[LANES] = {0}, R[LANES] = {0};
    for (unsigned i = 0; i < 18; i += 2) {
        if (mode == 0) for (unsigned l = 0; l < LANES; ++l) {
            L[l] ^= d[l].binary.salt[i & 2]; R[l] ^= d[l].binary.salt[(i & 2)+1];
        }
        JOIN(batch_encrypt, LANES)(d,L,R);
        for (unsigned l = 0; l < LANES; ++l) {
            d[l].ctx.P[i] = L[l]; d[l].ctx.P[i+1] = R[l];
        }
    }
    for (unsigned b = 0; b < 4; ++b) for (unsigned i = 0; i < 256; i += 2) {
        if (mode == 0) for (unsigned l = 0; l < LANES; ++l) {
            L[l] ^= d[l].binary.salt[(i+18) & 3]; R[l] ^= d[l].binary.salt[(i+19) & 3];
        }
        JOIN(batch_encrypt, LANES)(d,L,R);
        for (unsigned l = 0; l < LANES; ++l) {
            d[l].ctx.S[b][i] = L[l]; d[l].ctx.S[b][i+1] = R[l];
        }
    }
}

static int JOIN(batch_run, LANES)(const char *const *keys, const char *const *settings,
                                  unsigned char (*out)[61]) {
    struct BF_data d[LANES];
    unsigned cost = 0;
    for (unsigned l = 0; l < LANES; ++l) {
        const char *s = settings[l];
        if (strlen(keys[l]) > 72 || strlen(s) < 29 || s[0] != '$' || s[1] != '2' ||
            (s[2] != 'a' && s[2] != 'b' && s[2] != 'y') || s[3] != '$' ||
            s[4] < '0' || s[4] > '3' || s[5] < '0' || s[5] > '9' || s[6] != '$') return 0;
        unsigned c = (s[4]-'0')*10 + s[5]-'0';
        if (c < 4 || c > 31 || (l && c != cost)) return 0;
        cost = c;
        if (BF_decode(d[l].binary.salt, s+7, 16)) return 0;
        BF_swap(d[l].binary.salt,4);
        BF_set_key(keys[l], d[l].expanded_key, d[l].ctx.P, flags_by_subtype[(unsigned)s[2]-'a']);
        memcpy(d[l].ctx.S, BF_init_state.S, sizeof(d[l].ctx.S));
    }
    JOIN(batch_expand, LANES)(d,0);
    for (BF_word n = (BF_word)1 << cost; n; --n) {
        JOIN(batch_expand, LANES)(d,1);
        JOIN(batch_expand, LANES)(d,2);
    }
    BF_word L[LANES], R[LANES];
    for (unsigned i = 0; i < 6; i += 2) {
        for (unsigned l = 0; l < LANES; ++l) { L[l] = BF_magic_w[i]; R[l] = BF_magic_w[i+1]; }
        for (unsigned j = 0; j < 64; ++j) JOIN(batch_encrypt, LANES)(d,L,R);
        for (unsigned l = 0; l < LANES; ++l) { d[l].binary.output[i] = L[l]; d[l].binary.output[i+1] = R[l]; }
    }
    for (unsigned l = 0; l < LANES; ++l) {
        memcpy(out[l], settings[l], 28);
        out[l][28] = BF_itoa64[(int)BF_atoi64[(int)settings[l][28]-0x20] & 0x30];
        BF_swap(d[l].binary.output,6);
        BF_encode(out[l]+29,d[l].binary.output,23);
        out[l][60] = 0;
    }
    /* Volatile stores keep password-derived state from surviving this call. */
    volatile unsigned char *wipe = (volatile unsigned char *)d;
    for (size_t i = 0; i < sizeof(d); ++i) wipe[i] = 0;
    return 1;
}
