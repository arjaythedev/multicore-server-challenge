/* Prepared HMAC primitive adapted from our twelve-dollar-server-challenge
   PR #143 db.c. Each worker owns its OpenSSL state; no JWT verification,
   token, password or database result is cached. Goose validates every claim. */
#include "json_fast.h"
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    EVP_MAC *algorithm;
    EVP_MAC_CTX *context;
    uint8_t *key;
    size_t key_length;
} AuthHmac;

static pthread_once_t auth_once = PTHREAD_ONCE_INIT;
static pthread_key_t auth_key;
static int auth_key_ready;
static _Thread_local AuthHmac *auth_local;

static void clear_key(AuthHmac *state) {
    EVP_MAC_CTX_free(state->context);
    state->context = NULL;
    OPENSSL_clear_free(state->key, state->key_length);
    state->key = NULL;
    state->key_length = 0;
}

static void destroy_state(void *value) {
    AuthHmac *state = value;
    if (!state) return;
    if (auth_local == state) auth_local = NULL;
    clear_key(state);
    EVP_MAC_free(state->algorithm);
    free(state);
}

static void make_auth_key(void) {
    auth_key_ready = pthread_key_create(&auth_key, destroy_state) == 0;
}

static AuthHmac *thread_state(void) {
    if (auth_local) return auth_local;
    if (pthread_once(&auth_once, make_auth_key) != 0 || !auth_key_ready) return NULL;
    AuthHmac *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->algorithm = EVP_MAC_fetch(NULL, "HMAC", NULL);
    if (!state->algorithm || pthread_setspecific(auth_key, state) != 0) {
        destroy_state(state);
        return NULL;
    }
    auth_local = state;
    return state;
}

int32_t native_hmac_sha256(bytes secret, bytes message, mutable_bytes digest) {
    if (secret.len < 0 || secret.len > 1048576 || message.len < 0 ||
        digest.len != 32 || !digest.data ||
        (secret.len && !secret.data) || (message.len && !message.data)) return 0;
    AuthHmac *state = thread_state();
    if (!state) return 0;
    size_t key_length = (size_t)secret.len;
    if (!state->context || state->key_length != key_length ||
        (key_length && CRYPTO_memcmp(state->key, secret.data, key_length) != 0)) {
        /* Replace transactionally: an allocation/setup failure cannot relabel
           the previous context with another secret. A non-NULL empty key is valid. */
        uint8_t *key = OPENSSL_malloc(key_length ? key_length : 1);
        EVP_MAC_CTX *context = EVP_MAC_CTX_new(state->algorithm);
        if (!key || !context) {
            OPENSSL_clear_free(key, key_length);
            EVP_MAC_CTX_free(context);
            return 0;
        }
        if (key_length) memcpy(key, secret.data, key_length);
        OSSL_PARAM params[] = {
            OSSL_PARAM_construct_utf8_string(OSSL_MAC_PARAM_DIGEST, "SHA256", 0),
            OSSL_PARAM_construct_end()
        };
        if (!EVP_MAC_init(context, key, key_length, params)) {
            OPENSSL_clear_free(key, key_length);
            EVP_MAC_CTX_free(context);
            return 0;
        }
        clear_key(state);
        state->context = context;
        state->key = key;
        state->key_length = key_length;
    } else if (!EVP_MAC_init(state->context, NULL, 0, NULL)) {
        clear_key(state);
        return 0;
    }
    /* The secret's keyed state is reused, but the complete message is hashed
       afresh on every call, including repeated tokens. */
    size_t length = 0;
    if (!EVP_MAC_update(state->context, message.data, (size_t)message.len) ||
        !EVP_MAC_final(state->context, digest.data, &length, 32) || length != 32) {
        OPENSSL_cleanse(digest.data, 32);
        clear_key(state);
        return 0;
    }
    return 1;
}
