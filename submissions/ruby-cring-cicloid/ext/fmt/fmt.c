// Document pieces in C for planner.rb: JSON string escaping and timestamp formatting done once, in one call
// per article or comment, instead of a Ruby string per field.
//
//   Fmt.article(slug, title, description, body_or_nil, tag_names_json, created, updated, favorites,
//               username, bio, image) -> [head, body_part_or_nil, tail, middle]
//     head..tail end at "favorited": and middle ends at "following": (planner.rb splices the flags in)
//   Fmt.comment(id, created, updated, body, username, bio, image) -> text up to "following":
//   Fmt.str(value_or_nil) -> JSON string or null
//   Fmt.time(pg_timestamp) -> "2024-09-15T14:22:31.123Z"
// Timestamps are Postgres text with TimeZone UTC ("2024-09-15 14:22:31.123456+00", fraction optional);
// milliseconds are truncated, as SPEC.md asks.
#include <ruby.h>
#include <ruby/encoding.h>
#include <string.h>

typedef struct {
  char *p;
  long len, cap;
} buf_t;

static void grow(buf_t *b, long need) {
  if (b->len + need <= b->cap) return;
  long cap = b->cap ? b->cap : 256;
  while (cap < b->len + need) cap *= 2;
  REALLOC_N(b->p, char, cap);
  b->cap = cap;
}

static void put(buf_t *b, const char *s, long n) {
  grow(b, n);
  memcpy(b->p + b->len, s, n);
  b->len += n;
}

#define PUTS(b, lit) put((b), (lit), (long)sizeof(lit) - 1)

static const char HEX[] = "0123456789abcdef";

// A JSON string (valid UTF-8 in, as Postgres text is), or null for nil.
static void put_str(buf_t *b, VALUE v) {
  if (NIL_P(v)) {
    PUTS(b, "null");
    return;
  }
  StringValue(v);
  const unsigned char *s = (const unsigned char *)RSTRING_PTR(v);
  long n = RSTRING_LEN(v);
  grow(b, n * 6 + 2);
  char *o = b->p + b->len;
  *o++ = '"';
  for (long i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c >= 0x20 && c != '"' && c != '\\') {
      *o++ = (char)c;
      continue;
    }
    *o++ = '\\';
    switch (c) {
    case '"': *o++ = '"'; break;
    case '\\': *o++ = '\\'; break;
    case '\n': *o++ = 'n'; break;
    case '\r': *o++ = 'r'; break;
    case '\t': *o++ = 't'; break;
    case '\b': *o++ = 'b'; break;
    case '\f': *o++ = 'f'; break;
    default:
      *o++ = 'u'; *o++ = '0'; *o++ = '0';
      *o++ = HEX[c >> 4]; *o++ = HEX[c & 15];
    }
  }
  *o++ = '"';
  b->len = o - b->p;
}

// "2024-09-15 14:22:31[.ffffff]+00" -> 2024-09-15T14:22:31.fffZ (no quotes)
static void put_time(buf_t *b, VALUE v) {
  StringValue(v);
  const char *s = RSTRING_PTR(v);
  long n = RSTRING_LEN(v);
  if (n < 19) rb_raise(rb_eArgError, "timestamp too short");
  grow(b, 24);
  char *o = b->p + b->len;
  memcpy(o, s, 10);
  o[10] = 'T';
  memcpy(o + 11, s + 11, 8);
  o[19] = '.';
  char frac[3] = {'0', '0', '0'};
  if (n > 20 && s[19] == '.')
    for (int i = 0; i < 3 && 20 + i < n && s[20 + i] >= '0' && s[20 + i] <= '9'; i++) frac[i] = s[20 + i];
  memcpy(o + 20, frac, 3);
  o[23] = 'Z';
  b->len += 24;
}

static VALUE take(buf_t *b) {
  VALUE s = rb_utf8_str_new(b->p, b->len);
  b->len = 0;
  return s;
}

static VALUE fmt_article(VALUE self, VALUE slug, VALUE title, VALUE description, VALUE body, VALUE tags,
                         VALUE created, VALUE updated, VALUE favorites, VALUE username, VALUE bio, VALUE image) {
  buf_t b = {0};
  VALUE out = rb_ary_new_capa(4);
  PUTS(&b, "{\"slug\":"); put_str(&b, slug);
  PUTS(&b, ",\"title\":"); put_str(&b, title);
  PUTS(&b, ",\"description\":"); put_str(&b, description);
  rb_ary_push(out, take(&b));
  if (NIL_P(body)) {
    rb_ary_push(out, Qnil);
  } else {
    PUTS(&b, ",\"body\":"); put_str(&b, body);
    rb_ary_push(out, take(&b));
  }
  StringValue(tags);
  PUTS(&b, ",\"tagList\":"); put(&b, RSTRING_PTR(tags), RSTRING_LEN(tags));
  PUTS(&b, ",\"createdAt\":\""); put_time(&b, created);
  PUTS(&b, "\",\"updatedAt\":\""); put_time(&b, updated);
  PUTS(&b, "\",\"favorited\":");
  rb_ary_push(out, take(&b));
  StringValue(favorites);
  PUTS(&b, ",\"favoritesCount\":"); put(&b, RSTRING_PTR(favorites), RSTRING_LEN(favorites));
  PUTS(&b, ",\"author\":{\"username\":"); put_str(&b, username);
  PUTS(&b, ",\"bio\":"); put_str(&b, bio);
  PUTS(&b, ",\"image\":"); put_str(&b, image);
  PUTS(&b, ",\"following\":");
  rb_ary_push(out, take(&b));
  xfree(b.p);
  return out;
}

static VALUE fmt_comment(VALUE self, VALUE id, VALUE created, VALUE updated, VALUE body, VALUE username, VALUE bio,
                         VALUE image) {
  buf_t b = {0};
  StringValue(id);
  PUTS(&b, "{\"id\":"); put(&b, RSTRING_PTR(id), RSTRING_LEN(id));
  PUTS(&b, ",\"createdAt\":\""); put_time(&b, created);
  PUTS(&b, "\",\"updatedAt\":\""); put_time(&b, updated);
  PUTS(&b, "\",\"body\":"); put_str(&b, body);
  PUTS(&b, ",\"author\":{\"username\":"); put_str(&b, username);
  PUTS(&b, ",\"bio\":"); put_str(&b, bio);
  PUTS(&b, ",\"image\":"); put_str(&b, image);
  PUTS(&b, ",\"following\":");
  VALUE s = take(&b);
  xfree(b.p);
  return s;
}

static VALUE fmt_str(VALUE self, VALUE v) {
  buf_t b = {0};
  put_str(&b, v);
  VALUE s = take(&b);
  xfree(b.p);
  return s;
}

static VALUE fmt_time(VALUE self, VALUE v) {
  buf_t b = {0};
  put_time(&b, v);
  VALUE s = take(&b);
  xfree(b.p);
  return s;
}

void Init_fmt(void) {
  VALUE module = rb_define_module("Fmt");
  rb_define_singleton_method(module, "article", fmt_article, 11);
  rb_define_singleton_method(module, "comment", fmt_comment, 7);
  rb_define_singleton_method(module, "str", fmt_str, 1);
  rb_define_singleton_method(module, "time", fmt_time, 1);
}
