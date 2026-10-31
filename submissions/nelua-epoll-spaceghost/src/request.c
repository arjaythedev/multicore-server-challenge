#define _GNU_SOURCE
#include "native.h"
#include "bcrypt.h"
#include <ctype.h>
#include <crypt.h>
#include <inttypes.h>
#include <limits.h>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/rand.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define NC_HEADER_LIMIT (32U * 1024U)
#define NC_BODY_LIMIT (1024U * 1024U)
#define NC_OUTPUT_LIMIT (16U * 1024U * 1024U)
#define NC_JSON_NODES 65536U
#define NC_JSON_DEPTH 64U

typedef struct nc_chunk {
    struct nc_chunk *next;
    size_t used, size;
    max_align_t alignment;
    unsigned char bytes[];
} nc_chunk;

struct nc_buffer { char *data; size_t length, capacity; bool failed; };
struct nc_json {
    int kind;
    char *name;
    char *text;
    struct nc_json *child, *next;
    int count;
};
typedef struct nc_pair { char *name, *value; struct nc_pair *next; } nc_pair;
struct nc_request {
    nc_chunk *chunks;
    char *method, **segments, *authorization;
    int segment_count, status;
    bool keepalive, authorization_present, body_parsed;
    char *body;
    size_t body_length;
    nc_json *json;
    nc_pair *query;
    nc_buffer output;
};

typedef struct nc_parser {
    nc_request *request;
    const unsigned char *at, *end;
    unsigned nodes;
    bool failed;
} nc_parser;

static void *
nc_alloc(nc_request *request, size_t length)
{
    nc_chunk *chunk = request->chunks;
    size_t align = _Alignof(max_align_t);
    size_t padded;
    if (length > SIZE_MAX - align) return NULL;
    padded = (length + align - 1) & ~(align - 1);
    if (!chunk || chunk->size - chunk->used < padded) {
        size_t size = padded > 4096 ? padded : 4096;
        chunk = malloc(sizeof(*chunk) + size);
        if (!chunk) return NULL;
        chunk->next = request->chunks;
        chunk->used = 0;
        chunk->size = size;
        request->chunks = chunk;
    }
    void *result = chunk->bytes + chunk->used;
    chunk->used += padded;
    return result;
}

static char *
nc_copy(nc_request *request, const char *value, size_t length)
{
    char *copy = nc_alloc(request, length + 1);
    if (!copy) return NULL;
    memcpy(copy, value, length);
    copy[length] = 0;
    return copy;
}

static const char *
nc_crlf(const char *start, const char *end)
{
    const char *newline = memchr(start, '\n', (size_t)(end - start));
    return newline && newline > start && newline[-1] == '\r' ? newline - 1 : NULL;
}

static bool
nc_token_char(unsigned char value)
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
           (value >= '0' && value <= '9') || (value && strchr("!#$%&'*+-.^_`|~", value) != NULL);
}

static bool
nc_header_name(const char *name, size_t length, const char *expected)
{
    return strlen(expected) == length && strncasecmp(name, expected, length) == 0;
}

/* Exact framing, with no in-place modification of a partial receive buffer. */
ssize_t
nc_request_size(const char *data, size_t length)
{
    size_t header_length = 0, body_length = 0;
    bool has_length = false;
    const char *end;
    const char *line = data;
    const char *line_end;
    if (!data || length == 0) return 0;
    end = data + length;
    for (size_t i = 0; i + 3 < length && i < NC_HEADER_LIMIT; ++i) {
        if (data[i] == '\r' && data[i+1] == '\n' && data[i+2] == '\r' && data[i+3] == '\n') {
            header_length = i + 4;
            break;
        }
    }
    if (!header_length) return length >= NC_HEADER_LIMIT ? -2 : 0;
    if (header_length > NC_HEADER_LIMIT) return -2;
    end = data + header_length;
    line_end = nc_crlf(line, end);
    if (!line_end || line_end == line) return -1;
    for (const char *p = line; p < line_end; ++p)
        if ((unsigned char)*p < 32 || (unsigned char)*p == 127) return -1;
    line = line_end + 2;
    while (line < end - 2) {
        const char *colon;
        const char *value;
        const char *value_end;
        line_end = nc_crlf(line, end);
        if (!line_end || line_end == line) return -1;
        colon = memchr(line, ':', (size_t)(line_end - line));
        if (!colon || colon == line) return -1;
        for (const char *p = line; p < colon; ++p)
            if (!nc_token_char((unsigned char)*p)) return -1;
        value = colon + 1;
        while (value < line_end && (*value == ' ' || *value == '\t')) ++value;
        value_end = line_end;
        while (value_end > value && (value_end[-1] == ' ' || value_end[-1] == '\t')) --value_end;
        for (const char *p = value; p < value_end; ++p)
            if (((unsigned char)*p < 32 && *p != '\t') || (unsigned char)*p == 127) return -1;
        if (nc_header_name(line, (size_t)(colon - line), "Transfer-Encoding")) return -1;
        if (nc_header_name(line, (size_t)(colon - line), "Content-Length")) {
            size_t parsed = 0;
            if (value == value_end) return -1;
            for (const char *p = value; p < value_end; ++p) {
                if (*p < '0' || *p > '9') return -1;
                if (parsed > NC_BODY_LIMIT / 10) return -2;
                parsed = parsed * 10 + (unsigned)(*p - '0');
                if (parsed > NC_BODY_LIMIT) return -2;
            }
            if (has_length && parsed != body_length) return -1;
            has_length = true;
            body_length = parsed;
        }
        line = line_end + 2;
    }
    return length < header_length + body_length ? 0 : (ssize_t)(header_length + body_length);
}

static int
nc_hex(unsigned char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

static char *
nc_url_decode(nc_request *request, const char *value, size_t length, bool plus)
{
    char *result = nc_alloc(request, length + 1);
    size_t used = 0;
    if (!result) return NULL;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)value[i];
        if (c == '%') {
            int high, low;
            if (i + 2 >= length || (high = nc_hex((unsigned char)value[i+1])) < 0 ||
                (low = nc_hex((unsigned char)value[i+2])) < 0) return NULL;
            c = (unsigned char)((high << 4) | low);
            i += 2;
        } else if (c == '+' && plus) c = ' ';
        if (!c) return NULL;
        result[used++] = (char)c;
    }
    result[used] = 0;
    return result;
}

static bool
nc_connection_token(const char *value, size_t length, const char *token)
{
    size_t n = strlen(token);
    const char *end = value + length;
    while (value < end) {
        const char *comma = memchr(value, ',', (size_t)(end-value));
        const char *part_end = comma ? comma : end;
        while (value < part_end && (*value == ' ' || *value == '\t')) ++value;
        while (part_end > value && (part_end[-1] == ' ' || part_end[-1] == '\t')) --part_end;
        if ((size_t)(part_end-value) == n && strncasecmp(value, token, n) == 0) return true;
        value = comma ? comma + 1 : end;
    }
    return false;
}

nc_request *
nc_request_create(const char *data, size_t length)
{
    ssize_t framed = nc_request_size(data, length);
    nc_request *request;
    const char *end = data + length;
    const char *line_end, *space, *target, *target_end, *version, *line;
    const char *query, *path_end, *part;
    size_t max_segments = 1;
    if (framed <= 0 || (size_t)framed != length) return NULL;
    request = calloc(1, sizeof(*request));
    if (!request) return NULL;
    request->status = 500;
    line_end = nc_crlf(data, end);
    space = memchr(data, ' ', (size_t)(line_end-data));
    if (!space || space == data) goto invalid;
    for (const char *p = data; p < space; ++p)
        if (!nc_token_char((unsigned char)*p)) goto invalid;
    request->method = nc_copy(request, data, (size_t)(space-data));
    target = space + 1;
    space = memchr(target, ' ', (size_t)(line_end-target));
    if (!space || space == target || *target != '/') goto invalid;
    target_end = space;
    version = space + 1;
    if (line_end-version != 8) goto invalid;
    if (memcmp(version, "HTTP/1.1", 8) == 0) request->keepalive = true;
    else if (memcmp(version, "HTTP/1.0", 8) != 0) goto invalid;
    query = memchr(target, '?', (size_t)(target_end-target));
    path_end = query ? query : target_end;
    for (const char *p = target; p < path_end; ++p) if (*p == '/') ++max_segments;
    request->segments = nc_alloc(request, max_segments * sizeof(char *));
    if (!request->method || !request->segments) goto invalid;
    part = target + 1;
    while (part < path_end) {
        const char *slash = memchr(part, '/', (size_t)(path_end-part));
        const char *stop = slash ? slash : path_end;
        char *decoded = nc_url_decode(request, part, (size_t)(stop-part), false);
        if (!decoded) goto invalid;
        request->segments[request->segment_count++] = decoded;
        part = slash ? slash + 1 : path_end;
        if (slash && part == path_end) {
            request->segments[request->segment_count++] = nc_copy(request, "", 0);
            if (!request->segments[request->segment_count-1]) goto invalid;
        }
    }
    if (query) {
        nc_pair **tail = &request->query;
        part = query + 1;
        while (part < target_end) {
            const char *amp = memchr(part, '&', (size_t)(target_end-part));
            const char *stop = amp ? amp : target_end;
            const char *equal = memchr(part, '=', (size_t)(stop-part));
            nc_pair *pair = nc_alloc(request, sizeof(*pair));
            if (!pair) goto invalid;
            pair->next = NULL;
            pair->name = nc_url_decode(request, part, (size_t)((equal ? equal : stop)-part), true);
            pair->value = nc_url_decode(request, equal ? equal+1 : stop,
                                        equal ? (size_t)(stop-equal-1) : 0, true);
            if (!pair->name || !pair->value) goto invalid;
            *tail = pair; tail = &pair->next;
            part = amp ? amp+1 : target_end;
        }
    }
    line = line_end + 2;
    while (line < end) {
        const char *colon, *value, *value_end;
        line_end = nc_crlf(line, end);
        if (!line_end) goto invalid;
        if (line_end == line) {
            request->body_length = (size_t)(end - line_end - 2);
            request->body = nc_copy(request, line_end + 2, request->body_length);
            if (!request->body) goto invalid;
            return request;
        }
        colon = memchr(line, ':', (size_t)(line_end-line));
        if (!colon) goto invalid;
        value = colon + 1;
        while (value < line_end && (*value == ' ' || *value == '\t')) ++value;
        value_end = line_end;
        while (value_end > value && (value_end[-1] == ' ' || value_end[-1] == '\t')) --value_end;
        if (nc_header_name(line, (size_t)(colon-line), "Authorization")) {
            if (request->authorization_present) goto invalid;
            request->authorization_present = true;
            request->authorization = nc_copy(request, value, (size_t)(value_end-value));
            if (!request->authorization) goto invalid;
        }
        if (nc_header_name(line, (size_t)(colon-line), "Connection")) {
            if (nc_connection_token(value, (size_t)(value_end-value), "close")) request->keepalive = false;
            else if (nc_connection_token(value, (size_t)(value_end-value), "keep-alive")) request->keepalive = true;
        }
        line = line_end + 2;
    }
invalid:
    nc_request_free(request);
    return NULL;
}

void
nc_request_free(nc_request *request)
{
    if (!request) return;
    while (request->chunks) {
        nc_chunk *next = request->chunks->next;
        free(request->chunks);
        request->chunks = next;
    }
    free(request->output.data);
    free(request);
}

const char *nc_method(nc_request *r) { return r->method; }
const char *nc_segment(nc_request *r, int n) { return n >= 0 && n < r->segment_count ? r->segments[n] : NULL; }
int nc_segments(nc_request *r) { return r->segment_count; }
bool nc_keepalive(nc_request *r) { return r->keepalive; }
bool nc_eq(const char *a, const char *b) { return a && b && strcmp(a,b) == 0; }
size_t nc_length(const char *value) { return value ? strlen(value) : 0; }
const char *nc_query(nc_request *r, const char *name)
{
    for (nc_pair *pair = r->query; pair; pair = pair->next)
        if (strcmp(pair->name, name) == 0) return pair->value;
    return NULL;
}

int64_t
nc_parse_uint(const char *value)
{
    uint64_t result = 0;
    if (!value || !*value) return -1;
    for (; *value; ++value) {
        unsigned digit = (unsigned char)*value - '0';
        if (digit > 9 || result > ((uint64_t)INT64_MAX - digit) / 10) return -1;
        result = result * 10 + digit;
    }
    return (int64_t)result;
}

char *
nc_decimal(nc_request *request, int64_t value)
{
    char number[32];
    int length = snprintf(number, sizeof(number), "%" PRId64, value);
    return length > 0 ? nc_copy(request, number, (size_t)length) : NULL;
}

static void
nc_skip_space(nc_parser *parser)
{
    while (parser->at < parser->end && (*parser->at == ' ' || *parser->at == '\t' ||
           *parser->at == '\r' || *parser->at == '\n')) ++parser->at;
}

static bool
nc_utf8_sequence(const unsigned char **at, const unsigned char *end)
{
    const unsigned char *p = *at;
    unsigned lead = *p++, count, minimum, code;
    if (lead < 128) { *at = p; return true; }
    if (lead >= 0xc2 && lead <= 0xdf) { count=1; minimum=0x80; code=lead&31; }
    else if (lead >= 0xe0 && lead <= 0xef) { count=2; minimum=0x800; code=lead&15; }
    else if (lead >= 0xf0 && lead <= 0xf4) { count=3; minimum=0x10000; code=lead&7; }
    else return false;
    if ((size_t)(end-p) < count) return false;
    while (count--) {
        if ((*p & 0xc0) != 0x80) return false;
        code = (code << 6) | (*p++ & 63);
    }
    if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return false;
    *at = p;
    return true;
}

static bool
nc_unicode4(const unsigned char **at, const unsigned char *end, unsigned *code)
{
    unsigned value=0;
    if (end-*at < 4) return false;
    for (int i=0; i<4; ++i) {
        int digit = nc_hex(*(*at)++);
        if (digit < 0) return false;
        value = (value << 4) | (unsigned)digit;
    }
    *code = value;
    return true;
}

static char *
nc_parse_string(nc_parser *parser)
{
    const unsigned char *start, *scan;
    char *out;
    size_t used=0;
    if (parser->at == parser->end || *parser->at++ != '"') return NULL;
    start=parser->at; scan=start;
    while (scan < parser->end && *scan != '"') {
        if (*scan < 32) return NULL;
        if (*scan == '\\') {
            ++scan;
            if (scan == parser->end) return NULL;
            ++scan;
        } else ++scan;
    }
    if (scan == parser->end) return NULL;
    out=nc_alloc(parser->request,(size_t)(scan-start)+1);
    if (!out) return NULL;
    while (parser->at < scan) {
        unsigned char c=*parser->at++;
        if (c == '\\') {
            unsigned code;
            if (parser->at == scan) return NULL;
            c=*parser->at++;
            switch (c) {
            case '"': case '\\': case '/': out[used++]=(char)c; break;
            case 'b': out[used++]='\b'; break;
            case 'f': out[used++]='\f'; break;
            case 'n': out[used++]='\n'; break;
            case 'r': out[used++]='\r'; break;
            case 't': out[used++]='\t'; break;
            case 'u':
                if (!nc_unicode4(&parser->at,scan,&code)) return NULL;
                if (code >= 0xd800 && code <= 0xdbff) {
                    unsigned low;
                    if (scan-parser->at < 6 || parser->at[0] != '\\' || parser->at[1] != 'u') return NULL;
                    parser->at += 2;
                    if (!nc_unicode4(&parser->at,scan,&low) || low < 0xdc00 || low > 0xdfff) return NULL;
                    code=0x10000 + ((code-0xd800)<<10) + low-0xdc00;
                } else if (code >= 0xdc00 && code <= 0xdfff) return NULL;
                if (code == 0) return NULL; /* NUL cannot cross a C-string/PG-text boundary. */
                if (code < 0x80) out[used++]=(char)code;
                else if (code < 0x800) {
                    out[used++]=(char)(0xc0|(code>>6)); out[used++]=(char)(0x80|(code&63));
                } else if (code < 0x10000) {
                    out[used++]=(char)(0xe0|(code>>12)); out[used++]=(char)(0x80|((code>>6)&63)); out[used++]=(char)(0x80|(code&63));
                } else {
                    out[used++]=(char)(0xf0|(code>>18)); out[used++]=(char)(0x80|((code>>12)&63));
                    out[used++]=(char)(0x80|((code>>6)&63)); out[used++]=(char)(0x80|(code&63));
                }
                break;
            default: return NULL;
            }
        } else if (c < 128) out[used++]=(char)c;
        else {
            const unsigned char *at=parser->at-1;
            parser->at=at;
            if (!nc_utf8_sequence(&parser->at,scan)) return NULL;
            memcpy(out+used,at,(size_t)(parser->at-at)); used+=(size_t)(parser->at-at);
        }
    }
    parser->at=scan+1;
    out[used]=0;
    return out;
}

static nc_json *nc_parse_value(nc_parser *parser, unsigned depth);

static nc_json *
nc_parse_value(nc_parser *parser, unsigned depth)
{
    nc_json *node;
    if (depth > NC_JSON_DEPTH || ++parser->nodes > NC_JSON_NODES) goto invalid;
    nc_skip_space(parser);
    if (parser->at == parser->end) goto invalid;
    node=nc_alloc(parser->request,sizeof(*node));
    if (!node) goto invalid;
    memset(node,0,sizeof(*node));
    if (*parser->at == '{' || *parser->at == '[') {
        bool object=*parser->at++ == '{';
        unsigned char close=object ? '}' : ']';
        nc_json **tail=&node->child;
        node->kind=object ? 1 : 2;
        nc_skip_space(parser);
        if (parser->at < parser->end && *parser->at == close) { ++parser->at; return node; }
        for (;;) {
            char *name=NULL;
            nc_json *child;
            if (object) {
                nc_skip_space(parser);
                name=nc_parse_string(parser);
                if (!name) goto invalid;
                nc_skip_space(parser);
                if (parser->at == parser->end || *parser->at++ != ':') goto invalid;
            }
            child=nc_parse_value(parser,depth+1);
            if (!child) goto invalid;
            child->name=name;
            *tail=child; tail=&child->next; ++node->count;
            nc_skip_space(parser);
            if (parser->at == parser->end) goto invalid;
            if (*parser->at == close) { ++parser->at; return node; }
            if (*parser->at++ != ',') goto invalid;
        }
    }
    if (*parser->at == '"') {
        node->kind=3;
        node->text=nc_parse_string(parser);
        if (!node->text) goto invalid;
        return node;
    }
    if ((size_t)(parser->end-parser->at) >= 4 && memcmp(parser->at,"null",4) == 0) {
        parser->at+=4;
        return node;
    }
    node->kind=4;
    if ((size_t)(parser->end-parser->at) >= 4 && memcmp(parser->at,"true",4) == 0) {
        parser->at+=4; node->text="true"; return node;
    }
    if ((size_t)(parser->end-parser->at) >= 5 && memcmp(parser->at,"false",5) == 0) {
        parser->at+=5; node->text="false"; return node;
    }
    {
        const unsigned char *start=parser->at;
        if (*parser->at == '-') ++parser->at;
        if (parser->at == parser->end) goto invalid;
        if (*parser->at == '0') ++parser->at;
        else {
            if (*parser->at < '1' || *parser->at > '9') goto invalid;
            do { ++parser->at; } while (parser->at < parser->end && *parser->at >= '0' && *parser->at <= '9');
        }
        if (parser->at < parser->end && *parser->at == '.') {
            ++parser->at;
            if (parser->at == parser->end || *parser->at < '0' || *parser->at > '9') goto invalid;
            do { ++parser->at; } while (parser->at < parser->end && *parser->at >= '0' && *parser->at <= '9');
        }
        if (parser->at < parser->end && (*parser->at == 'e' || *parser->at == 'E')) {
            ++parser->at;
            if (parser->at < parser->end && (*parser->at == '+' || *parser->at == '-')) ++parser->at;
            if (parser->at == parser->end || *parser->at < '0' || *parser->at > '9') goto invalid;
            do { ++parser->at; } while (parser->at < parser->end && *parser->at >= '0' && *parser->at <= '9');
        }
        node->text=nc_copy(parser->request,(const char *)start,(size_t)(parser->at-start));
        if (!node->text) goto invalid;
    }
    return node;
invalid:
    parser->failed=true;
    return NULL;
}

static nc_json *
nc_parse_json(nc_request *request, const char *data, size_t length)
{
    nc_parser parser={request,(const unsigned char *)data,(const unsigned char *)data+length,0,false};
    nc_json *node=nc_parse_value(&parser,0);
    nc_skip_space(&parser);
    return !parser.failed && parser.at == parser.end ? node : NULL;
}

nc_json *
nc_field(nc_json *object, const char *name)
{
    nc_json *found=NULL;
    if (!object || object->kind != 1) return NULL;
    for (nc_json *child=object->child; child; child=child->next)
        if (child->name && strcmp(child->name,name) == 0) found=child;
    return found;
}

nc_json *
nc_body(nc_request *request, const char *wrapper)
{
    nc_json *value;
    if (!request->body_parsed) {
        request->json=nc_parse_json(request,request->body,request->body_length);
        request->body_parsed=true;
    }
    value=nc_field(request->json,wrapper);
    return value && value->kind == 1 ? value : NULL;
}
int nc_kind(nc_json *value) { return value ? value->kind : 0; }
const char *nc_string(nc_json *value) { return value && value->kind == 3 ? value->text : NULL; }
int nc_array_length(nc_json *value) { return value && value->kind == 2 ? value->count : 0; }
nc_json *nc_array_item(nc_json *value, int index)
{
    if (!value || value->kind != 2 || index < 0) return NULL;
    value=value->child;
    while (value && index--) value=value->next;
    return value;
}

void
nc_write_n(nc_buffer *buffer, const char *value, size_t length)
{
    size_t needed, capacity;
    char *data;
    if (buffer->failed) return;
    if (length > NC_OUTPUT_LIMIT || buffer->length > NC_OUTPUT_LIMIT-length || (!value && length)) {
        buffer->failed=true; return;
    }
    needed=buffer->length+length+1;
    if (needed > buffer->capacity) {
        capacity=buffer->capacity ? buffer->capacity : 512;
        while (capacity < needed) capacity*=2;
        data=realloc(buffer->data,capacity);
        if (!data) { buffer->failed=true; return; }
        buffer->data=data; buffer->capacity=capacity;
    }
    if (length) memcpy(buffer->data+buffer->length,value,length);
    buffer->length+=length;
    buffer->data[buffer->length]=0;
}
void nc_write(nc_buffer *buffer, const char *value) { if (value) nc_write_n(buffer,value,strlen(value)); }
void nc_putc(nc_buffer *buffer, char value) { nc_write_n(buffer,&value,1); }
nc_buffer *nc_begin(nc_request *request, int status)
{
    request->status=status;
    request->output.length=0;
    request->output.failed=false;
    return &request->output;
}
void nc_error(nc_request *request, int status)
{
    nc_write(nc_begin(request,status),"{\"errors\":{\"body\":[\"request failed\"]}}");
}
int nc_status(nc_request *request) { return request->output.failed ? 500 : request->status; }
const char *nc_response_data(nc_request *request, size_t *length)
{
    static const char failure[]="{\"errors\":{\"body\":[\"internal error\"]}}";
    if (request->output.failed) { *length=sizeof(failure)-1; return failure; }
    *length=request->output.length;
    return request->output.data ? request->output.data : "";
}

char *
nc_tag_array(nc_request *request, nc_json *array)
{
    nc_buffer buffer={0};
    char *result;
    if (!array || array->kind != 2) return NULL;
    nc_putc(&buffer,'{');
    for (nc_json *item=array->child; item; item=item->next) {
        if (item->kind != 3) { free(buffer.data); return NULL; }
        if (item != array->child) nc_putc(&buffer,',');
        nc_putc(&buffer,'"');
        for (const char *p=item->text; *p; ++p) {
            if (*p == '\\' || *p == '"') nc_putc(&buffer,'\\');
            nc_putc(&buffer,*p);
        }
        nc_putc(&buffer,'"');
    }
    nc_putc(&buffer,'}');
    result=buffer.failed ? NULL : nc_copy(request,buffer.data,buffer.length);
    free(buffer.data);
    return result;
}

char *
nc_text_vector(nc_request *request, const char *const *values, int count)
{
    nc_buffer buffer={0};
    char *result;
    if (count < 0 || (count && !values)) return NULL;
    nc_putc(&buffer,'{');
    for (int i=0; i<count; ++i) {
        if (i) nc_putc(&buffer,',');
        if (!values[i]) { nc_write(&buffer,"NULL"); continue; }
        nc_putc(&buffer,'"');
        for (const char *p=values[i]; *p; ++p) {
            if (*p == '\\' || *p == '"') nc_putc(&buffer,'\\');
            nc_putc(&buffer,*p);
        }
        nc_putc(&buffer,'"');
    }
    nc_putc(&buffer,'}');
    result=buffer.failed ? NULL : nc_copy(request,buffer.data,buffer.length);
    free(buffer.data);
    return result;
}

char *
nc_int_vector(nc_request *request, const int64_t *values, int count)
{
    nc_buffer buffer={0};
    char *result;
    if (count < 0 || (count && !values)) return NULL;
    nc_putc(&buffer,'{');
    for (int i=0; i<count; ++i) {
        char number[32];
        int length;
        if (i) nc_putc(&buffer,',');
        length=snprintf(number,sizeof(number),"%" PRId64,values[i]);
        nc_write_n(&buffer,number,(size_t)length);
    }
    nc_putc(&buffer,'}');
    result=buffer.failed ? NULL : nc_copy(request,buffer.data,buffer.length);
    free(buffer.data);
    return result;
}

static const char nc_base64_alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static int
nc_base64_digit(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return c-'A';
    if (c >= 'a' && c <= 'z') return c-'a'+26;
    if (c >= '0' && c <= '9') return c-'0'+52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

static char *
nc_base64_encode(nc_request *request, const unsigned char *data, size_t length)
{
    size_t used=0;
    char *result=nc_alloc(request,((length+2)/3)*4+1);
    if (!result) return NULL;
    for (size_t i=0; i<length; i+=3) {
        unsigned value=(unsigned)data[i]<<16;
        if (i+1 < length) value|=(unsigned)data[i+1]<<8;
        if (i+2 < length) value|=data[i+2];
        result[used++]=nc_base64_alphabet[value>>18];
        result[used++]=nc_base64_alphabet[(value>>12)&63];
        if (i+1 < length) result[used++]=nc_base64_alphabet[(value>>6)&63];
        if (i+2 < length) result[used++]=nc_base64_alphabet[value&63];
    }
    result[used]=0;
    return result;
}

static unsigned char *
nc_base64_decode(nc_request *request, const char *data, size_t length, size_t *decoded)
{
    uint32_t bits=0;
    unsigned available=0;
    size_t used=0;
    unsigned char *result;
    if (!length || length > NC_HEADER_LIMIT || length%4 == 1) return NULL;
    result=nc_alloc(request,length*3/4+1);
    if (!result) return NULL;
    for (size_t i=0; i<length; ++i) {
        int digit=nc_base64_digit((unsigned char)data[i]);
        if (digit < 0) return NULL;
        bits=(bits<<6)|(unsigned)digit;
        available+=6;
        if (available >= 8) { available-=8; result[used++]=(unsigned char)(bits>>available); }
    }
    if (available && (bits & ((1U<<available)-1))) return NULL;
    result[used]=0; *decoded=used;
    return result;
}

const char *
nc_token(nc_request *request)
{
    return request->authorization && strncmp(request->authorization,"Token ",6) == 0 ? request->authorization+6 : NULL;
}

typedef struct nc_hmac_state {
    EVP_MAC_CTX *context;
    unsigned char *secret;
    size_t secret_length;
} nc_hmac_state;

static pthread_once_t nc_hmac_once=PTHREAD_ONCE_INIT;
static pthread_key_t nc_hmac_key;
static bool nc_hmac_key_ready;

static void
nc_hmac_clear(nc_hmac_state *state)
{
    EVP_MAC_CTX_free(state->context);
    OPENSSL_clear_free(state->secret,state->secret_length);
    state->context=NULL; state->secret=NULL; state->secret_length=0;
}

static void
nc_hmac_free(void *pointer)
{
    nc_hmac_state *state=pointer;
    nc_hmac_clear(state);
    free(state);
}

static void
nc_hmac_key_create(void)
{
    nc_hmac_key_ready=pthread_key_create(&nc_hmac_key,nc_hmac_free)==0;
}

/* Only configuration key material/context survives calls: each message is hashed afresh.
 * One context per worker avoids shared mutable crypto state and per-request
 * provider/context allocation. A changed environment secret replaces the key. */
static bool
nc_hmac_sha256(const char *secret,size_t secret_length,const unsigned char *data,
               size_t length,unsigned char *digest,unsigned *digest_length)
{
    if (pthread_once(&nc_hmac_once,nc_hmac_key_create)!=0 || !nc_hmac_key_ready)
        return false;
    nc_hmac_state *state=pthread_getspecific(nc_hmac_key);
    if (!state) {
        state=calloc(1,sizeof(*state));
        if (!state) return false;
        if (pthread_setspecific(nc_hmac_key,state)!=0) { free(state); return false; }
    }
    if (!state->context) {
        EVP_MAC *algorithm=EVP_MAC_fetch(NULL,"HMAC",NULL);
        if (!algorithm) return false;
        state->context=EVP_MAC_CTX_new(algorithm);
        EVP_MAC_free(algorithm);
        if (!state->context) return false;
    }
    if (secret_length!=state->secret_length || !state->secret ||
        memcmp(secret,state->secret,secret_length)!=0) {
        unsigned char *saved=OPENSSL_memdup(secret,secret_length);
        if (!saved) return false;
        char digest_name[]="SHA256";
        OSSL_PARAM parameters[]={
            OSSL_PARAM_utf8_string(OSSL_MAC_PARAM_DIGEST,digest_name,0),
            OSSL_PARAM_END
        };
        if (!EVP_MAC_init(state->context,(const unsigned char *)secret,secret_length,parameters)) {
            OPENSSL_clear_free(saved,secret_length); goto failed;
        }
        OPENSSL_clear_free(state->secret,state->secret_length);
        state->secret=saved; state->secret_length=secret_length;
    } else if (!EVP_MAC_init(state->context,NULL,0,NULL)) goto failed;
    size_t size=0;
    if (!EVP_MAC_update(state->context,data,length) ||
        !EVP_MAC_final(state->context,digest,&size,32) || size!=32) goto failed;
    *digest_length=(unsigned)size;
    return true;
failed:
    nc_hmac_clear(state);
    return false;
}

int64_t
nc_auth(nc_request *request)
{
    const char *token, *first, *second, *secret;
    size_t signature_length, header_length, payload_length;
    unsigned char digest[EVP_MAX_MD_SIZE], *signature, *header, *payload;
    unsigned digest_length=0;
    nc_json *head, *claims, *alg, *sub, *exp, *nbf;
    int64_t id, expiry, now;
    if (!request->authorization_present) return 0;
    token=nc_token(request);
    if (!token || !(first=strchr(token,'.')) || !(second=strchr(first+1,'.')) || strchr(second+1,'.')) return -1;
    secret=getenv("JWT_SECRET");
    if (!secret || !*secret || strlen(secret) > INT_MAX) return -1;
    signature=nc_base64_decode(request,second+1,strlen(second+1),&signature_length);
    if (!signature || signature_length != 32 ||
        !nc_hmac_sha256(secret,strlen(secret),(const unsigned char *)token,(size_t)(second-token),digest,&digest_length) ||
        digest_length != signature_length || CRYPTO_memcmp(signature,digest,signature_length) != 0) return -1;
    header=nc_base64_decode(request,token,(size_t)(first-token),&header_length);
    payload=nc_base64_decode(request,first+1,(size_t)(second-first-1),&payload_length);
    if (!header || !payload) return -1;
    head=nc_parse_json(request,(const char *)header,header_length);
    claims=nc_parse_json(request,(const char *)payload,payload_length);
    alg=nc_field(head,"alg"); sub=nc_field(claims,"sub"); exp=nc_field(claims,"exp"); nbf=nc_field(claims,"nbf");
    if (!nc_eq(nc_string(alg),"HS256") || !(id=nc_parse_uint(nc_string(sub))) || id < 0 ||
        !exp || exp->kind != 4 || (expiry=nc_parse_uint(exp->text)) < 0) return -1;
    now=(int64_t)time(NULL);
    if (now < 0 || expiry <= now) return -1;
    if (nbf && (nbf->kind != 4 || (expiry=nc_parse_uint(nbf->text)) < 0 || expiry > now)) return -1;
    return id;
}

char *
nc_issue_token(nc_request *request, int64_t id)
{
    static const char header[]="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
    char claims[160];
    const char *secret=getenv("JWT_SECRET");
    int64_t now=(int64_t)time(NULL);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned digest_length;
    char *payload, *message, *signature, *result;
    int length;
    size_t message_length, signature_length;
    if (id <= 0 || now < 0 || !secret || !*secret || strlen(secret) > INT_MAX) return NULL;
    length=snprintf(claims,sizeof(claims),"{\"sub\":\"%" PRId64 "\",\"iat\":%" PRId64 ",\"exp\":%" PRId64 "}",id,now,now+2592000);
    if (length < 0 || (size_t)length >= sizeof(claims)) return NULL;
    payload=nc_base64_encode(request,(const unsigned char *)claims,(size_t)length);
    if (!payload) return NULL;
    message_length=sizeof(header)-1+1+strlen(payload);
    message=nc_alloc(request,message_length+1);
    if (!message) return NULL;
    memcpy(message,header,sizeof(header)-1); message[sizeof(header)-1]='.';
    memcpy(message+sizeof(header),payload,strlen(payload)+1);
    if (!nc_hmac_sha256(secret,strlen(secret),(const unsigned char *)message,message_length,digest,&digest_length)) return NULL;
    signature=nc_base64_encode(request,digest,digest_length);
    if (!signature) return NULL;
    signature_length=strlen(signature);
    result=nc_alloc(request,message_length+signature_length+2);
    if (!result) return NULL;
    memcpy(result,message,message_length); result[message_length]='.';
    memcpy(result+message_length+1,signature,signature_length+1);
    return result;
}

char *
nc_hash(nc_request *request, const char *password)
{
    unsigned char entropy[16];
    char salt[CRYPT_GENSALT_OUTPUT_SIZE];
    char interleaved[61];
    struct crypt_data data={0};
    char *hash;
    if (!password || strnlen(password,73) > 72 || RAND_bytes(entropy,sizeof(entropy)) != 1 ||
        !crypt_gensalt_rn("$2b$",10,(const char *)entropy,sizeof(entropy),salt,sizeof(salt))) return NULL;
    if (nc_bcrypt_hash(password,salt,interleaved))
        return nc_copy(request,interleaved,60);
    hash=crypt_r(password,salt,&data);
    if (!hash || hash[0] == '*') return NULL;
    return nc_copy(request,hash,strlen(hash));
}

bool
nc_verify(const char *password, const char *hash)
{
    struct crypt_data data={0};
    char interleaved[61];
    char *actual;
    size_t length;
    if (!password || !hash || strnlen(password,73) > 72 || (length=strnlen(hash,256)) >= 256) return false;
    /* The fixed data contains bcrypt; refuse other algorithms or a changed cost. */
    if (length != 60 || hash[0] != '$' || hash[1] != '2' ||
        (hash[2] != 'a' && hash[2] != 'b' && hash[2] != 'y') || memcmp(hash+3,"$10$",4) != 0) return false;
    if (nc_bcrypt_hash(password,hash,interleaved))
        return CRYPTO_memcmp(interleaved,hash,60) == 0;
    actual=crypt_r(password,hash,&data);
    return actual && strlen(actual) == length && CRYPTO_memcmp(actual,hash,length) == 0;
}
