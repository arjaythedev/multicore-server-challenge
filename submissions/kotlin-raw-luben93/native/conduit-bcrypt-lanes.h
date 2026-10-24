/* Included by conduit-bcrypt.c once per LANES, after bcrypt-batch-impl.h for the same LANES (which defines the
 * interleaved batch_expand/batch_encrypt). This is batch_run from bcrypt-batch-impl.h with the C-string parsing
 * replaced by the caller's words: setup as in Openwall's BF_crypt (P = pi ^ key, S = pi), then the same rounds. */
static void JOIN(lanes_run, LANES)(unsigned n, const int32_t *keys, const int32_t *salts, unsigned cost,
                                   int32_t *out) {
    struct BF_data d[LANES];
    BF_word L[LANES], R[LANES];
    for (unsigned l = 0; l < LANES; ++l) {
        const unsigned j = l < n ? l : 0; /* idle lanes repeat lane 0 */
        for (unsigned i = 0; i < BF_N + 2; ++i) {
            d[l].expanded_key[i] = (BF_word)keys[j * 18 + i];
            d[l].ctx.P[i] = BF_init_state.P[i] ^ d[l].expanded_key[i];
        }
        for (unsigned i = 0; i < 4; ++i) d[l].binary.salt[i] = (BF_word)salts[j * 4 + i];
        memcpy(d[l].ctx.S, BF_init_state.S, sizeof(d[l].ctx.S));
    }
    JOIN(batch_expand, LANES)(d, 0);
    for (BF_word c = (BF_word)1 << cost; c; --c) {
        JOIN(batch_expand, LANES)(d, 1);
        JOIN(batch_expand, LANES)(d, 2);
    }
    for (unsigned i = 0; i < 6; i += 2) {
        for (unsigned l = 0; l < LANES; ++l) { L[l] = BF_magic_w[i]; R[l] = BF_magic_w[i + 1]; }
        for (unsigned j = 0; j < 64; ++j) JOIN(batch_encrypt, LANES)(d, L, R);
        for (unsigned l = 0; l < n; ++l) {
            out[l * 6 + i] = (int32_t)L[l];
            out[l * 6 + i + 1] = (int32_t)R[l];
        }
    }
    wipe(d, sizeof(d));
    wipe(L, sizeof(L));
    wipe(R, sizeof(R));
}
