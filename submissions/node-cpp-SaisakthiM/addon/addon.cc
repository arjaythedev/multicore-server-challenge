// Node-API glue (raw node_api.h, no npm dependency). Everything runs on Node's own libuv loop:
//   exec(lane, id, spec)         queue a pipelined Postgres request; result -> onPg(id, status, buf, sqlstate)
//   bcryptHash(id, pw)           bcrypt cost 10 on a native thread; result -> onBcrypt(id, ok, hash)
//   bcryptVerify(id, pw, hash)   same, verifying against a stored hash
//   jwtVerify(token) -> userId | 0,   jwtSign(userId) -> token
#include <node_api.h>
#include <uv.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "bcrypt_pool.h"
#include "jwt.h"
#include "pg_lane.h"

namespace {

napi_env g_env = nullptr;
napi_ref g_on_pg = nullptr;
napi_ref g_on_bcrypt = nullptr;
Pg* g_pg = nullptr;
BcryptPool* g_bc = nullptr;
std::string g_secret;

napi_value throw_err(napi_env env, const char* msg) {
  napi_throw_error(env, nullptr, msg);
  return nullptr;
}

bool get_string(napi_env env, napi_value v, std::string& out) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return false;
  out.resize(len);
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied) != napi_ok) return false;
  out.resize(copied);
  return true;
}

bool get_u32(napi_env env, napi_value v, uint32_t& out) { return napi_get_value_uint32(env, v, &out) == napi_ok; }

void call_js(napi_env env, napi_ref fn_ref, size_t argc, napi_value* argv) {
  napi_value fn, global, result;
  if (napi_get_reference_value(env, fn_ref, &fn) != napi_ok || fn == nullptr) return;
  napi_get_global(env, &global);
  const napi_status s = napi_make_callback(env, nullptr, global, fn, argc, argv, &result);
  if (s == napi_pending_exception) {
    napi_value ex;
    if (napi_get_and_clear_last_exception(env, &ex) == napi_ok) napi_fatal_exception(env, ex);
  }
}

// ---- results coming back from the C++ layers; always called on the event-loop thread ----

void on_pg_result(void*, PgResult& r) {
  napi_env env = g_env;
  napi_handle_scope scope;
  if (napi_open_handle_scope(env, &scope) != napi_ok) return;
  napi_value argv[4];
  napi_create_uint32(env, r.id, &argv[0]);
  napi_create_int32(env, r.status, &argv[1]);
  if (r.status == 1) {
    napi_get_null(env, &argv[2]);
  } else {
    void* unused = nullptr;
    napi_create_buffer_copy(env, r.data.size(), r.data.data(), &unused, &argv[2]);
  }
  napi_create_string_utf8(env, r.sqlstate.c_str(), r.sqlstate.size(), &argv[3]);
  call_js(env, g_on_pg, 4, argv);
  napi_close_handle_scope(env, scope);
}

void on_bcrypt_done(void*, BcryptJob* j) {
  napi_env env = g_env;
  napi_handle_scope scope;
  if (napi_open_handle_scope(env, &scope) != napi_ok) return;
  napi_value argv[3];
  napi_create_uint32(env, j->id, &argv[0]);
  napi_get_boolean(env, j->ok, &argv[1]);
  napi_create_string_utf8(env, j->hash.c_str(), j->hash.size(), &argv[2]);
  call_js(env, g_on_bcrypt, 3, argv);
  napi_close_handle_scope(env, scope);
}

// ---- exported functions ----

napi_value DoInit(napi_env env, napi_callback_info info) {
  if (g_pg != nullptr) return throw_err(env, "init() called twice");
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
    return throw_err(env, "init(options) expects an object");
  }
  napi_value o = argv[0];
  napi_value v;

  std::string url, sslmode = "disable";
  if (napi_get_named_property(env, o, "url", &v) != napi_ok || !get_string(env, v, url)) {
    return throw_err(env, "options.url must be a string");
  }
  if (napi_get_named_property(env, o, "secret", &v) != napi_ok || !get_string(env, v, g_secret)) {
    return throw_err(env, "options.secret must be a string");
  }
  {
    napi_valuetype t;
    if (napi_get_named_property(env, o, "sslmode", &v) == napi_ok && napi_typeof(env, v, &t) == napi_ok &&
        t == napi_string) {
      get_string(env, v, sslmode);
    }
  }
  uint32_t read_conns = 4, write_conns = 2, bcrypt_threads = 2;
  if (napi_get_named_property(env, o, "readConns", &v) == napi_ok) get_u32(env, v, read_conns);
  if (napi_get_named_property(env, o, "writeConns", &v) == napi_ok) get_u32(env, v, write_conns);
  if (napi_get_named_property(env, o, "bcryptThreads", &v) == napi_ok) get_u32(env, v, bcrypt_threads);

  std::vector<std::string> sql;
  {
    napi_value arr;
    uint32_t n = 0;
    if (napi_get_named_property(env, o, "sql", &arr) != napi_ok || napi_get_array_length(env, arr, &n) != napi_ok) {
      return throw_err(env, "options.sql must be an array of strings");
    }
    for (uint32_t i = 0; i < n; ++i) {
      napi_value e;
      std::string s;
      if (napi_get_element(env, arr, i, &e) != napi_ok || !get_string(env, e, s)) {
        return throw_err(env, "options.sql must be an array of strings");
      }
      sql.push_back(std::move(s));
    }
  }
  if (napi_get_named_property(env, o, "onPg", &v) != napi_ok || napi_create_reference(env, v, 1, &g_on_pg) != napi_ok) {
    return throw_err(env, "options.onPg must be a function");
  }
  if (napi_get_named_property(env, o, "onBcrypt", &v) != napi_ok ||
      napi_create_reference(env, v, 1, &g_on_bcrypt) != napi_ok) {
    return throw_err(env, "options.onBcrypt must be a function");
  }

  uv_loop_t* loop = nullptr;
  if (napi_get_uv_event_loop(env, &loop) != napi_ok || loop == nullptr) return throw_err(env, "no uv loop");
  g_env = env;
  g_bc = new BcryptPool(loop, int(bcrypt_threads), on_bcrypt_done, nullptr);
  g_pg = new Pg(loop, std::move(url), std::move(sql), int(read_conns), int(write_conns), std::move(sslmode),
                on_pg_result, nullptr);
  return nullptr;
}

// exec(lane, id, spec): spec = [stmtIdx, nParams, p1..pn, stmtIdx, nParams, p1..pn, ...]; a param is a string or null
napi_value Exec(napi_env env, napi_callback_info info) {
  if (g_pg == nullptr) return throw_err(env, "not initialised");
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 3) {
    return throw_err(env, "exec(lane, id, spec)");
  }
  uint32_t lane = 0, id = 0, n = 0;
  if (!get_u32(env, argv[0], lane) || lane > 1 || !get_u32(env, argv[1], id) ||
      napi_get_array_length(env, argv[2], &n) != napi_ok) {
    return throw_err(env, "exec: bad arguments");
  }
  PgRequest req;
  req.id = id;
  uint32_t i = 0;
  napi_value e;
  while (i < n) {
    uint32_t idx = 0, np = 0;
    if (napi_get_element(env, argv[2], i++, &e) != napi_ok || !get_u32(env, e, idx) || i >= n ||
        napi_get_element(env, argv[2], i++, &e) != napi_ok || !get_u32(env, e, np) || np > 32 || i + np > n) {
      return throw_err(env, "exec: malformed spec");
    }
    PgStmtCall sc;
    sc.idx = int(idx);
    sc.params.resize(np);
    for (uint32_t k = 0; k < np; ++k) {
      napi_valuetype t;
      if (napi_get_element(env, argv[2], i++, &e) != napi_ok || napi_typeof(env, e, &t) != napi_ok) {
        return throw_err(env, "exec: malformed spec");
      }
      if (t == napi_string) {
        if (!get_string(env, e, sc.params[k].s)) return throw_err(env, "exec: bad string parameter");
      } else {
        sc.params[k].null = true;
      }
    }
    req.stmts.push_back(std::move(sc));
  }
  g_pg->submit(int(lane), std::move(req));
  return nullptr;
}

napi_value BcryptHash(napi_env env, napi_callback_info info) {
  if (g_bc == nullptr) return throw_err(env, "not initialised");
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  BcryptJob* j = new BcryptJob;
  if (argc < 2 || !get_u32(env, argv[0], j->id) || !get_string(env, argv[1], j->password)) {
    delete j;
    return throw_err(env, "bcryptHash(id, password)");
  }
  if (!g_bc->submit(j)) {
    delete j;
    return throw_err(env, "bcrypt queue full");
  }
  return nullptr;
}

napi_value BcryptVerify(napi_env env, napi_callback_info info) {
  if (g_bc == nullptr) return throw_err(env, "not initialised");
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  BcryptJob* j = new BcryptJob;
  j->verify = true;
  if (argc < 3 || !get_u32(env, argv[0], j->id) || !get_string(env, argv[1], j->password) ||
      !get_string(env, argv[2], j->hash)) {
    delete j;
    return throw_err(env, "bcryptVerify(id, password, hash)");
  }
  if (!g_bc->submit(j)) {
    delete j;
    return throw_err(env, "bcrypt queue full");
  }
  return nullptr;
}

napi_value JwtVerify(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  char buf[1100];
  size_t len = 0;
  int64_t id = 0;
  if (argc >= 1 && napi_get_value_string_utf8(env, argv[0], buf, sizeof buf, &len) == napi_ok && len <= 1024) {
    id = jwt::verify(g_secret, buf, len);
  }
  napi_value out;
  napi_create_double(env, static_cast<double>(id), &out);
  return out;
}

napi_value JwtSign(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int64_t id = 0;
  if (argc < 1 || napi_get_value_int64(env, argv[0], &id) != napi_ok) return throw_err(env, "jwtSign(userId)");
  const std::string t = jwt::sign(g_secret, id);
  napi_value out;
  napi_create_string_utf8(env, t.c_str(), t.size(), &out);
  return out;
}

}  // namespace

extern "C" NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports) {
  const napi_property_descriptor props[] = {
      {"init", nullptr, DoInit, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"exec", nullptr, Exec, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"bcryptHash", nullptr, BcryptHash, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"bcryptVerify", nullptr, BcryptVerify, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"jwtVerify", nullptr, JwtVerify, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"jwtSign", nullptr, JwtSign, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof props / sizeof props[0], props);
  return exports;
}
