#include "api/api.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "api/handlers.h"
#include "api/render.h"
#include "config.h"
#include "crypto/bcrypt.h"
#include "crypto/jwt.h"
#include "crypto/offload.h"
#include "util.h"

/* register/login/update hash+verify off the loop (bcrypt cost 10 = tens of ms
 * CPU); resumes on the owning worker */

typedef struct register_state {
    api_request *r;
    const char *username;
    const char *email;
    const char *password;
    char *hash;
    bool hashed;
} register_state;

typedef struct login_state {
    api_request *r;
    const char *email;
    const char *password;
    char *hash;
    long long user_id;
    const char *username;
    const char *profile_email;
    const char *bio;
    const char *image;
    bool bio_null;
    bool image_null;
    bool verified;
} login_state;

typedef struct update_state {
    api_request *r;
    const char *email;
    const char *username;
    const char *password;
    const char *bio;
    const char *image;
    char *hash;
    bool hashed;
} update_state;

static const char *mint_token(api_request *r, long long user_id) {
    buf token;
    buf_init(&token);
    bool ok = jwt_mint(&token, user_id, r->worker->jwt_secret, time(NULL));
    const char *result = NULL;
    if (ok) result = req_strn(r, token.data, token.len);
    buf_free(&token);
    return result;
}

static void respond_user(api_request *r, const pg_result *res,
                         long long mint_user_id) {
    const char *token = r->viewer > 0
                            ? r->rq->auth_token
                            : mint_token(r, mint_user_id);
    if (!token) {
        req_fail(r, 500, "crypto unavailable");
        return;
    }
    user_view view;
    user_view_load(&view, res, 0);
    buf_clear(&r->out);
    render_user(&r->out, &view, token);
    req_respond(r, 200);
}

static void register_inserted(void *ctx, pg_status status,
                              const pg_result *res) {
    register_state *state = ctx;
    api_request *r = state->r;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        long long id = strtoll(pg_result_value(res, 0, 0), NULL, 10);
        const char *token = mint_token(r, id);
        if (!token) {
            req_fail(r, 500, "crypto unavailable");
            return;
        }
        user_view view;
        user_view_load(&view, res, 0);
        buf_clear(&r->out);
        render_user(&r->out, &view, token);
        req_respond(r, 201);
        return;
    }
    if (status == PG_ROWS) {
        req_fail(r, 422, "username or email already taken");
        return;
    }
    if (status == PG_ERROR &&
        strcmp(pg_result_sqlstate(res), "23505") == 0) {
        req_fail(r, 422, "username or email already taken");
        return;
    }
    req_db_fail(r);
}

static void register_hashed(void *arg) {
    register_state *state = arg;
    api_request *r = state->r;
    if (!req_release(r) || r->dead) return;
    if (!state->hashed) {
        req_fail(r, 500, "crypto unavailable");
        return;
    }

    const char *params[3] = { state->username, state->email, state->hash };
    api_pg_write(r, PG_STMT_USERS_INSERT, 3, params, state,
              register_inserted);
}

static void register_hash(void *arg) {
    register_state *state = arg;
    state->hashed =
        bcrypt_hash(state->hash, BCRYPT_HASH_MAX, state->password);
}

void handle_users_register(api_request *r) {
    const json_node *user = body_object(r, "user");
    if (!user) {
        req_fail(r, 422, "user object required");
        return;
    }

    const char *username;
    const char *email;
    const char *password;
    if (body_string(user, "username", &username) != FIELD_OK ||
        body_string(user, "email", &email) != FIELD_OK ||
        body_string(user, "password", &password) != FIELD_OK) {
        req_fail(r, 422, "username, email and password are required");
        return;
    }
    if (strlen(password) > BCRYPT_PASSWORD_MAX) {
        req_fail(r, 422, "password is too long");
        return;
    }

    register_state *state = req_calloc(r, sizeof *state);
    state->r = r;
    state->username = username;
    state->email = email;
    state->password = password;
    state->hash = req_alloc(r, BCRYPT_HASH_MAX);

    req_hold(r);
    crypto_submit(r->worker->id, register_hash, register_hashed, state);
}

static void login_verified(void *arg) {
    login_state *state = arg;
    api_request *r = state->r;
    if (!req_release(r) || r->dead) return;

    if (!state->verified) {
        req_fail(r, 401, "Unauthorized");
        return;
    }
    /* the email read already carried the whole user row; render from the arena
     * copies instead of reading it again */
    const char *token = mint_token(r, state->user_id);
    if (!token) {
        req_fail(r, 500, "crypto unavailable");
        return;
    }
    user_view view;
    memset(&view, 0, sizeof view);
    view.username = state->username;
    view.email = state->profile_email;
    view.bio = state->bio;
    view.image = state->image;
    view.bio_null = state->bio_null;
    view.image_null = state->image_null;
    buf_clear(&r->out);
    render_user(&r->out, &view, token);
    req_respond(r, 200);
}

static void login_verify(void *arg) {
    login_state *state = arg;
    state->verified =
        bcrypt_verify(state->password, state->hash) == BCRYPT_MATCH;
}

static void login_row(void *ctx, pg_status status, const pg_result *res) {
    login_state *state = ctx;
    api_request *r = state->r;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        /* hash only valid until this callback returns; the worker thread runs
         * later, so hand it an arena copy */
        state->hash = req_str(r, pg_result_value(res, 0, 5));
        state->user_id = strtoll(pg_result_value(res, 0, 0), NULL, 10);
        state->username = req_str(r, pg_result_value(res, 0, 1));
        state->profile_email = req_str(r, pg_result_value(res, 0, 2));
        state->bio_null = pg_result_is_null(res, 0, 3);
        state->bio = state->bio_null ? NULL
                                     : req_str(r, pg_result_value(res, 0, 3));
        state->image_null = pg_result_is_null(res, 0, 4);
        state->image =
            state->image_null ? NULL : req_str(r, pg_result_value(res, 0, 4));
        req_hold(r);
        crypto_submit(r->worker->id, login_verify, login_verified, state);
        return;
    }
    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }
    req_fail(r, 401, "Unauthorized");
}

void handle_users_login(api_request *r) {
    const json_node *user = body_object(r, "user");
    if (!user) {
        req_fail(r, 422, "user object required");
        return;
    }

    const char *email;
    const char *password;
    if (body_string(user, "email", &email) != FIELD_OK ||
        body_string(user, "password", &password) != FIELD_OK) {
        req_fail(r, 422, "email and password are required");
        return;
    }

    login_state *state = req_calloc(r, sizeof *state);
    state->r = r;
    state->email = email;
    state->password = password;

    const pg_read read = { .key = email };
    api_pg_read(r, PG_READ_USER_EMAIL, &read, state, login_row);
}

static void user_loaded(void *ctx, pg_status status, const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        respond_user(r, res, 0);
        return;
    }
    if (status == PG_ERROR &&
        strcmp(pg_result_sqlstate(res), "23505") == 0) {
        req_fail(r, 422, "username or email already taken");
        return;
    }
    if (status == PG_ROWS) {
        /* both statements key on the viewer id: zero rows = deleted user */
        req_fail(r, 401, "Unauthorized");
        return;
    }
    req_db_fail(r);
}

void handle_user_get(api_request *r) {
    const pg_read read = { .viewer = r->viewer };
    api_pg_read(r, PG_READ_USER_ID, &read, r, user_loaded);
}

static void update_hashed(void *arg) {
    update_state *state = arg;
    api_request *r = state->r;
    if (!req_release(r) || r->dead) return;
    if (!state->hashed) {
        req_fail(r, 500, "crypto unavailable");
        return;
    }

    const char *params[6] = { req_ll(r, r->viewer), state->email,
                              state->username, state->hash, state->bio,
                              state->image };
    api_pg_write(r, PG_STMT_USERS_UPDATE, 6, params, r, user_loaded);
}

static void update_hash(void *arg) {
    update_state *state = arg;
    state->hashed =
        bcrypt_hash(state->hash, BCRYPT_HASH_MAX, state->password);
}

void handle_user_update(api_request *r) {
    const json_node *user = body_object(r, "user");
    if (!user) {
        req_fail(r, 422, "user object required");
        return;
    }

    const char *email = NULL;
    const char *username = NULL;
    const char *password = NULL;
    const char *bio = NULL;
    const char *image = NULL;
    field_result has_email = body_string(user, "email", &email);
    field_result has_username = body_string(user, "username", &username);
    field_result has_password = body_string(user, "password", &password);
    field_result has_bio = body_string_allow_empty(user, "bio", &bio);
    field_result has_image = body_string_allow_empty(user, "image", &image);

    if (has_email == FIELD_INVALID || has_username == FIELD_INVALID ||
        has_password == FIELD_INVALID || has_bio == FIELD_INVALID ||
        has_image == FIELD_INVALID) {
        req_fail(r, 422, "invalid fields");
        return;
    }
    if (has_password == FIELD_OK && strlen(password) > BCRYPT_PASSWORD_MAX) {
        req_fail(r, 422, "password is too long");
        return;
    }

    update_state *state = req_calloc(r, sizeof *state);
    state->r = r;
    state->email = has_email == FIELD_OK ? email : NULL;
    state->username = has_username == FIELD_OK ? username : NULL;
    state->bio = has_bio == FIELD_OK ? bio : NULL;
    state->image = has_image == FIELD_OK ? image : NULL;

    if (has_password == FIELD_OK) {
        state->password = password;
        state->hash = req_alloc(r, BCRYPT_HASH_MAX);
        req_hold(r);
        crypto_submit(r->worker->id, update_hash, update_hashed, state);
        return;
    }

    const char *params[6] = { req_ll(r, r->viewer), state->email,
                              state->username, NULL, state->bio,
                              state->image };
    api_pg_write(r, PG_STMT_USERS_UPDATE, 6, params, r, user_loaded);
}
