// A small strict JSON reader (enough to validate a body and pull named fields out of it) and the
// writers used to build responses.
#include "app.h"

enum { J_STR = 1, J_NUM, J_NULL, J_BOOL, J_OBJ, J_ARR };
typedef struct {
  int t;
  const char *p;  // J_STR: inside the quotes; J_OBJ/J_ARR: the whole value
  int n;
  bool esc;       // J_STR has escapes
} jv_t;

static const char *ws(const char *p, const char *e) {
  while (p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
  return p;
}

static int hexv(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static const char *pstring(const char *p, const char *e, jv_t *v) {
  // p at the opening quote
  p++;
  v->t = J_STR;
  v->p = p;
  v->esc = false;
  while (p < e) {
    unsigned char c = *p;
    if (c == '"') {
      v->n = p - v->p;
      return p + 1;
    }
    if (c < 0x20) return NULL;
    if (c == '\\') {
      v->esc = true;
      if (++p >= e) return NULL;
      switch (*p) {
        case '"': case '\\': case '/': case 'b': case 'f': case 'n': case 'r': case 't':
          p++;
          break;
        case 'u':
          if (e - p < 5) return NULL;
          for (int i = 1; i <= 4; i++)
            if (hexv((unsigned char)p[i]) < 0) return NULL;
          p += 5;
          break;
        default:
          return NULL;
      }
      continue;
    }
    p++;
  }
  return NULL;
}

static const char *pnumber(const char *p, const char *e, jv_t *v) {
  const char *s = p;
  if (p < e && *p == '-') p++;
  if (p >= e) return NULL;
  if (*p == '0') p++;
  else if (*p >= '1' && *p <= '9') while (p < e && *p >= '0' && *p <= '9') p++;
  else return NULL;
  if (p < e && *p == '.') {
    p++;
    if (p >= e || *p < '0' || *p > '9') return NULL;
    while (p < e && *p >= '0' && *p <= '9') p++;
  }
  if (p < e && (*p == 'e' || *p == 'E')) {
    p++;
    if (p < e && (*p == '+' || *p == '-')) p++;
    if (p >= e || *p < '0' || *p > '9') return NULL;
    while (p < e && *p >= '0' && *p <= '9') p++;
  }
  v->t = J_NUM;
  v->p = s;
  v->n = p - s;
  return p;
}

static const char *pvalue(const char *p, const char *e, jv_t *v, int depth);

static const char *pobject(const char *p, const char *e, int depth, const char *const *keys, int nkeys,
                           jv_t *out) {
  // p at '{'
  p = ws(p + 1, e);
  if (p < e && *p == '}') return p + 1;
  for (;;) {
    if (p >= e || *p != '"') return NULL;
    jv_t k, v;
    p = pstring(p, e, &k);
    if (!p) return NULL;
    p = ws(p, e);
    if (p >= e || *p != ':') return NULL;
    p = ws(p + 1, e);
    p = pvalue(p, e, &v, depth + 1);
    if (!p) return NULL;
    if (!k.esc)
      for (int i = 0; i < nkeys; i++)
        if ((int)strlen(keys[i]) == k.n && memcmp(keys[i], k.p, k.n) == 0) out[i] = v;
    p = ws(p, e);
    if (p < e && *p == ',') {
      p = ws(p + 1, e);
      continue;
    }
    if (p < e && *p == '}') return p + 1;
    return NULL;
  }
}

static const char *parray(const char *p, const char *e, int depth, jv_t *items, int maxitems, int *nitems) {
  p = ws(p + 1, e);
  int n = 0;
  if (p < e && *p == ']') {
    *nitems = 0;
    return p + 1;
  }
  for (;;) {
    jv_t v;
    p = pvalue(p, e, &v, depth + 1);
    if (!p) return NULL;
    if (items) {
      if (n >= maxitems) return NULL;
      items[n] = v;
    }
    n++;
    p = ws(p, e);
    if (p < e && *p == ',') {
      p = ws(p + 1, e);
      continue;
    }
    if (p < e && *p == ']') {
      *nitems = n;
      return p + 1;
    }
    return NULL;
  }
}

static const char *pvalue(const char *p, const char *e, jv_t *v, int depth) {
  if (p >= e || depth > 64) return NULL;
  const char *s = p;
  switch (*p) {
    case '"':
      return pstring(p, e, v);
    case '{':
      p = pobject(p, e, depth, NULL, 0, NULL);
      v->t = J_OBJ;
      break;
    case '[': {
      int n;
      p = parray(p, e, depth, NULL, 0, &n);
      v->t = J_ARR;
      break;
    }
    case 't':
      if (e - p >= 4 && !memcmp(p, "true", 4)) { v->t = J_BOOL; p += 4; break; }
      return NULL;
    case 'f':
      if (e - p >= 5 && !memcmp(p, "false", 5)) { v->t = J_BOOL; p += 5; break; }
      return NULL;
    case 'n':
      if (e - p >= 4 && !memcmp(p, "null", 4)) { v->t = J_NULL; p += 4; break; }
      return NULL;
    default:
      return pnumber(p, e, v);
  }
  if (!p) return NULL;
  v->p = s;
  v->n = p - s;
  return p;
}

static void put_utf8(char **d, unsigned cp) {
  char *o = *d;
  if (cp < 0x80) *o++ = cp;
  else if (cp < 0x800) { *o++ = 0xC0 | cp >> 6; *o++ = 0x80 | (cp & 63); }
  else if (cp < 0x10000) { *o++ = 0xE0 | cp >> 12; *o++ = 0x80 | (cp >> 6 & 63); *o++ = 0x80 | (cp & 63); }
  else { *o++ = 0xF0 | cp >> 18; *o++ = 0x80 | (cp >> 12 & 63); *o++ = 0x80 | (cp >> 6 & 63); *o++ = 0x80 | (cp & 63); }
  *d = o;
}

static unsigned hex4(const char *p) {
  return hexv((unsigned char)p[0]) << 12 | hexv((unsigned char)p[1]) << 8 | hexv((unsigned char)p[2]) << 4 |
         hexv((unsigned char)p[3]);
}

// Decode a validated string value into d (NUL-terminated); returns its length.
static int unescape(const jv_t *v, char *d) {
  char *o = d;
  if (!v->esc) {
    memcpy(o, v->p, v->n);
    o += v->n;
  } else {
    const char *p = v->p, *e = v->p + v->n;
    while (p < e) {
      if (*p != '\\') {
        *o++ = *p++;
        continue;
      }
      p++;
      switch (*p++) {
        case '"': *o++ = '"'; break;
        case '\\': *o++ = '\\'; break;
        case '/': *o++ = '/'; break;
        case 'b': *o++ = '\b'; break;
        case 'f': *o++ = '\f'; break;
        case 'n': *o++ = '\n'; break;
        case 'r': *o++ = '\r'; break;
        case 't': *o++ = '\t'; break;
        default: {  // u
          unsigned cp = hex4(p);
          p += 4;
          if (cp >= 0xD800 && cp < 0xDC00) {
            if (e - p >= 6 && p[0] == '\\' && p[1] == 'u') {
              unsigned lo = hex4(p + 2);
              if (lo >= 0xDC00 && lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                p += 6;
              } else {
                cp = 0xFFFD;
              }
            } else {
              cp = 0xFFFD;
            }
          } else if (cp >= 0xDC00 && cp < 0xE000) {
            cp = 0xFFFD;
          }
          put_utf8(&o, cp);
        }
      }
    }
  }
  *o = 0;
  return o - d;
}

bool json_wrapper(const char *body, size_t len, const char *wrap, const char *const *keys, int nkeys,
                  str_t *out, char **sb, const char *arr_key, char **arr, bool *arr_bad) {
  const char *e = body + len;
  const char *p = ws(body, e);
  if (p >= e || *p != '{') return false;
  jv_t top = {0};
  const char *end = pobject(p, e, 0, &wrap, 1, &top);
  if (!end || ws(end, e) != e) return false;
  if (top.t != J_OBJ) return false;
  jv_t f[MAXF + 1];
  memset(f, 0, sizeof f);
  const char *k2[MAXF + 1] = {0};
  for (int i = 0; i < nkeys; i++) k2[i] = keys[i];
  int na = nkeys;
  if (arr_key) k2[na++] = arr_key;
  pobject(top.p, top.p + top.n, 1, k2, na, f);
  char *d = malloc(len + 2 * (MAXF + 1) + 16);
  *sb = d;
  for (int i = 0; i < nkeys; i++) {
    if (f[i].t == 0 || f[i].t == J_NULL) {
      out[i] = (str_t){NULL, JSON_NULL};
    } else if (f[i].t != J_STR) {
      out[i] = (str_t){NULL, JSON_BAD};
    } else {
      int n = unescape(&f[i], d);
      out[i] = (str_t){d, n};
      d += n + 1;
    }
  }
  if (arr_key) {
    *arr = NULL;
    *arr_bad = false;
    jv_t *a = &f[nkeys];
    if (a->t == J_ARR) {
      int n;
      parray(a->p, a->p + a->n, 1, NULL, 0, &n);
      jv_t *items = malloc(sizeof(jv_t) * (n ? n : 1));
      parray(a->p, a->p + a->n, 1, items, n, &n);
      if (n > 0) {
        // text[] literal: {"a","b"} with \ and " escaped; worst case 2x + quotes
        size_t cap = 3;
        for (int i = 0; i < n; i++) cap += 2 * items[i].n + 4;
        char *lit = malloc(cap + 8);
        char *tmp = malloc(a->n + 8);
        char *o = lit;
        *o++ = '{';
        for (int i = 0; i < n && !*arr_bad; i++) {
          if (items[i].t != J_STR) {
            *arr_bad = true;
            break;
          }
          int m = unescape(&items[i], tmp);
          if (m == 0) {
            *arr_bad = true;
            break;
          }
          if (i) *o++ = ',';
          *o++ = '"';
          for (int k = 0; k < m; k++) {
            if (tmp[k] == '"' || tmp[k] == '\\') *o++ = '\\';
            *o++ = tmp[k];
          }
          *o++ = '"';
        }
        *o++ = '}';
        *o = 0;
        free(tmp);
        if (*arr_bad) free(lit);
        else *arr = lit;
      }
      free(items);
    } else if (a->t != 0 && a->t != J_NULL) {
      *arr_bad = true;
    }
  }
  return true;
}

// Find a member of a flat JSON object (for JWT headers and claims). Returns false if s is not a valid
// object. *t is 0 when the key is absent.
bool json_get(const char *s, size_t n, const char *key, int *t, const char **vp, int *vn, char *dec, int decmax) {
  const char *e = s + n;
  const char *p = ws(s, e);
  if (p >= e || *p != '{') return false;
  jv_t v = {0};
  const char *end = pobject(p, e, 0, &key, 1, &v);
  if (!end || ws(end, e) != e) return false;
  *t = v.t;
  if (v.t == J_STR) {
    if (v.n >= decmax) {
      *t = -1;  // too long to matter: treat as invalid
      return true;
    }
    *vn = unescape(&v, dec);
    *vp = dec;
  } else {
    *vp = v.p;
    *vn = v.n;
  }
  return true;
}

void json_str(buf_t *b, const char *s, size_t n) {
  static const char hex[] = "0123456789abcdef";
  char *o = buf_room(b, n * 6 + 2);
  *o++ = '"';
  for (size_t i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c >= 0x20 && c != '"' && c != '\\') {
      *o++ = c;
    } else if (c == '"' || c == '\\') {
      *o++ = '\\';
      *o++ = c;
    } else if (c == '\n') {
      *o++ = '\\';
      *o++ = 'n';
    } else if (c == '\r') {
      *o++ = '\\';
      *o++ = 'r';
    } else if (c == '\t') {
      *o++ = '\\';
      *o++ = 't';
    } else {
      memcpy(o, "\\u00", 4);
      o[4] = hex[c >> 4];
      o[5] = hex[c & 15];
      o += 6;
    }
  }
  *o++ = '"';
  b->len = o - b->p;
}

void json_nstr(buf_t *b, const char *s, size_t n, bool isnull) {
  if (isnull) buf_lit(b, "null");
  else json_str(b, s, n);
}

// Postgres timestamptz (microseconds since 2000-01-01 UTC) -> "YYYY-MM-DDTHH:MM:SS.mmmZ" (truncated)
void json_ts(buf_t *b, int64_t pg_us) {
  int64_t ms = pg_us >= 0 ? pg_us / 1000 : -((-pg_us + 999) / 1000);
  ms += 946684800000LL;
  int64_t secs = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000);
  int msr = (int)(ms - secs * 1000);
  int64_t days = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
  int sod = (int)(secs - days * 86400);
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp < 10 ? mp + 3 : mp - 9;
  y += (m <= 2);
  char *o = buf_room(b, 26);
  int yy = (int)y;
  o[0] = '"';
  o[1] = '0' + yy / 1000 % 10;
  o[2] = '0' + yy / 100 % 10;
  o[3] = '0' + yy / 10 % 10;
  o[4] = '0' + yy % 10;
  o[5] = '-';
  o[6] = '0' + m / 10;
  o[7] = '0' + m % 10;
  o[8] = '-';
  o[9] = '0' + d / 10;
  o[10] = '0' + d % 10;
  o[11] = 'T';
  int hh = sod / 3600, mi = sod / 60 % 60, ss = sod % 60;
  o[12] = '0' + hh / 10;
  o[13] = '0' + hh % 10;
  o[14] = ':';
  o[15] = '0' + mi / 10;
  o[16] = '0' + mi % 10;
  o[17] = ':';
  o[18] = '0' + ss / 10;
  o[19] = '0' + ss % 10;
  o[20] = '.';
  o[21] = '0' + msr / 100;
  o[22] = '0' + msr / 10 % 10;
  o[23] = '0' + msr % 10;
  o[24] = 'Z';
  o[25] = '"';
  b->len += 26;
}
