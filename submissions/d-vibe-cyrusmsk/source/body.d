/**
 * A tiny JSON reader for request bodies.
 *
 * The Conduit API only ever has one wrapper object with a handful of string (or
 * array) members, so instead of a general JSON tree we scan the text and hand
 * out the raw slice of each value: strings are decoded on demand by the few
 * fields that actually need it. Malformed input is rejected with the same
 * strictness the conformance suite expects (it sends `{"article": ` and other
 * broken bodies and wants a 422).
 */
module conduit.body;

import std.array : Appender, appender;

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Parses a request body and returns the raw text (including the braces) of the
/// `wrapper` member's value, which must be a JSON object. Anything else -
/// malformed JSON, no wrapper, or a non-object value - is a 422, exactly like
/// the reference implementation's strict body parsing.
bool findWrapper(const(char)[] body, const(char)[] wrapper, out const(char)[] inner) @safe
{
    auto o = JsonObject.init;
    if (!o.parseObject(body)) return false;
    Member m;
    bool found = false;
    while (o.next(m)) {
        if (m.name == wrapper) {
            if (m.value.length < 2 || m.value[0] != '{' || m.value[$ - 1] != '}') return false;
            inner = m.value;
            found = true;
            break;
        }
    }
    return found && o.ok;
}

/// Classifies a raw value as it appears in a JSON document.
enum JsonKind
{
    invalid,
    nullValue,
    text,
    number,
    boolValue,
    array,
    object
}

JsonKind kindOf(const(char)[] raw) pure nothrow @safe
{
    if (raw.length == 0) return JsonKind.invalid;
    immutable c = raw[0];
    if (c == '"') return raw.length >= 2 && raw[$ - 1] == '"' ? JsonKind.text : JsonKind.invalid;
    if (c == 't') return raw == "true" ? JsonKind.boolValue : JsonKind.invalid;
    if (c == 'f') return raw == "false" ? JsonKind.boolValue : JsonKind.invalid;
    if (c == 'n') return raw == "null" ? JsonKind.nullValue : JsonKind.invalid;
    if (c == '{') return raw.length >= 2 && raw[$ - 1] == '}' ? JsonKind.object : JsonKind.invalid;
    if (c == '[') return raw.length >= 2 && raw[$ - 1] == ']' ? JsonKind.array : JsonKind.invalid;
    return isNumber(raw) ? JsonKind.number : JsonKind.invalid;
}

/// A cursor over a flat JSON object's members.
struct Member
{
    const(char)[] key;   /// raw key text, with quotes
    const(char)[] value; /// raw value text

    /// The key without quotes.
    @property const(char)[] name() const @safe pure nothrow
    {
        return key.length >= 2 ? key[1 .. $ - 1] : null;
    }
}

/// Reads a JSON object's members one by one. `parse` returns false for anything
/// that isn't a well-formed object.
struct JsonObject
{
    private const(char)[] src_;
    private size_t pos_;
    private bool ok_ = true;

    /// Starts scanning a JSON object (the braces are part of `json`).
    bool parseObject(const(char)[] json) @safe
    {
        src_ = json;
        pos_ = skipBlankPos(json, 0);
        if (pos_ >= json.length || json[pos_] != '{') return false;
        pos_++;
        return true;
    }

    /// True when a next member is available.
    bool next(out Member m) @safe
    {
        if (!ok_) return false;
        pos_ = skipBlankPos(src_, pos_);
        if (pos_ >= src_.length) {
            ok_ = false;
            return false;
        }
        if (src_[pos_] == '}') {
            pos_++;
            // Only whitespace may follow the object.
            if (skipBlankPos(src_, pos_) != src_.length) ok_ = false;
            pos_ = src_.length;
            return false;
        }
        if (src_[pos_] != '"') {
            ok_ = false;
            return false;
        }
        size_t end;
        if (!skipString(src_, pos_, end)) {
            ok_ = false;
            return false;
        }
        m.key = src_[pos_ .. end];
        pos_ = end;

        pos_ = skipBlankPos(src_, pos_);
        if (pos_ >= src_.length || src_[pos_] != ':') {
            ok_ = false;
            return false;
        }
        pos_ = skipBlankPos(src_, pos_ + 1);

        if (!skipValue(src_, pos_, end)) {
            ok_ = false;
            return false;
        }
        m.value = src_[pos_ .. end];
        pos_ = end;

        pos_ = skipBlankPos(src_, pos_);
        if (pos_ < src_.length && src_[pos_] == ',') pos_++;
        return true;
    }

    /// True when the object was parsed without error.
    @property bool ok() const @safe pure nothrow
    {
        return ok_;
    }
}

private static size_t skipBlankPos(const(char)[] s, size_t i) pure nothrow @safe @nogc
{
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    return i;
}

/// Skips a JSON string starting at `i` (which must point at the opening quote).
private bool skipString(const(char)[] s, size_t i, out size_t end) pure nothrow @safe
{
    if (i >= s.length || s[i] != '"') return false;
    size_t j = i + 1;
    while (j < s.length) {
        immutable c = s[j];
        if (c == '\\') {
            if (++j >= s.length) return false;
        } else if (c == '"') {
            end = j + 1;
            return true;
        }
        j++;
    }
    return false;
}

/// Skips any JSON value starting at `i`.
private bool skipValue(const(char)[] s, size_t i, out size_t end) pure nothrow @safe
{
    if (i >= s.length) return false;
    immutable c = s[i];
    if (c == '"') return skipString(s, i, end);
    if (c == '{' || c == '[') {
        immutable close = c == '{' ? '}' : ']';
        size_t j = i + 1;
        while (true) {
            j = skipBlankPos(s, j);
            if (j >= s.length) return false;
            if (s[j] == close) {
                end = j + 1;
                return true;
            }
            size_t itemEnd;
            if (c == '{') {
                // a member: "key" : value
                if (s[j] != '"' || !skipString(s, j, itemEnd)) return false;
                j = skipBlankPos(s, itemEnd);
                if (j >= s.length || s[j] != ':') return false;
                if (!skipValue(s, skipBlankPos(s, j + 1), itemEnd)) return false;
            } else if (!skipValue(s, j, itemEnd)) {
                return false;
            }
            j = itemEnd;
            j = skipBlankPos(s, j);
            if (j < s.length && s[j] == ',') {
                j++;
                continue;
            }
            if (j < s.length && s[j] == close) {
                end = j + 1;
                return true;
            }
            return false;
        }
    }
    // number, true, false, null
    size_t j = i;
    while (j < s.length && s[j] != ',' && s[j] != '}' && s[j] != ']'
            && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r')
        j++;
    auto raw = s[i .. j];
    if (raw == "true" || raw == "false" || raw == "null") {
        end = j;
        return true;
    }
    // a number
    if (!isNumber(raw)) return false;
    end = j;
    return true;
}

private bool isNumber(const(char)[] raw) pure nothrow @safe
{
    size_t i = 0;
    if (i < raw.length && (raw[i] == '-' || raw[i] == '+')) i++;
    bool digits = false;
    while (i < raw.length && isDigit(raw[i])) {
        i++;
        digits = true;
    }
    if (i < raw.length && raw[i] == '.') {
        i++;
        while (i < raw.length && isDigit(raw[i])) {
            i++;
            digits = true;
        }
    }
    if (!digits) return false;
    if (i < raw.length && (raw[i] == 'e' || raw[i] == 'E')) {
        i++;
        if (i < raw.length && (raw[i] == '-' || raw[i] == '+')) i++;
        bool expDigits = false;
        while (i < raw.length && isDigit(raw[i])) {
            i++;
            expDigits = true;
        }
        if (!expDigits) return false;
    }
    return i == raw.length;
}

/// Iterates the elements of a JSON array.
struct JsonArray
{
    private const(char)[] src_;
    private size_t pos_;
    private bool ok_ = true;

    /// The text between the brackets of the `[`..`]` value, or nothing.
    this(const(char)[] arrayValue) @safe
    {
        if (arrayValue.length >= 2 && arrayValue[0] == '[' && arrayValue[$ - 1] == ']')
            src_ = arrayValue[1 .. $ - 1];
        else
            ok_ = false;
        pos_ = 0;
    }

    /// True when the array was well formed (it was checked while scanning, so
    /// this only means "the brackets were there").
    @property bool ok() const @safe pure nothrow
    {
        return ok_;
    }

    /// Hands out the raw text of the next element, or false at the end.
    bool next(out const(char)[] item) pure nothrow @safe
    {
        pos_ = skipBlankPos(src_, pos_);
        if (pos_ >= src_.length) return false;
        if (src_[pos_] == ',') {
            pos_++;
            pos_ = skipBlankPos(src_, pos_);
            if (pos_ >= src_.length) return false;
        }
        size_t end;
        if (!skipValue(src_, pos_, end)) return false;
        item = src_[pos_ .. end];
        pos_ = end;
        return true;
    }
}

/// Decodes a JSON string literal into `dst` (with quotes and escapes resolved).
/// Returns false when the literal isn't a valid string.
bool decodeString(const(char)[] raw, ref Appender!(char[]) dst) @safe
{
    if (raw.length < 2 || raw[0] != '"' || raw[$ - 1] != '"') return false;
    size_t i = 1;
    while (i < raw.length - 1) {
        immutable c = raw[i];
        if (c == '\\') {
            if (++i >= raw.length) return false;
            immutable esc = raw[i];
            switch (esc) {
                case '"': dst.put('"'); break;
                case '\\': dst.put('\\'); break;
                case '/': dst.put('/'); break;
                case 'b': dst.put('\b'); break;
                case 'f': dst.put('\f'); break;
                case 'n': dst.put('\n'); break;
                case 'r': dst.put('\r'); break;
                case 't': dst.put('\t'); break;
                case 'u': {
                    if (i + 4 >= raw.length) return false;
                    uint cp;
                    foreach (k; 0 .. 4) {
                        immutable h = hexValue(raw[i + 1 + k]);
                        if (h < 0) return false;
                        cp = cp * 16 + cast(uint) h;
                    }
                    i += 4;
                    // Surrogate pairs
                    if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 < raw.length
                            && raw[i + 1] == '\\' && raw[i + 2] == 'u') {
                        uint lo;
                        foreach (k; 0 .. 4) {
                            immutable h = hexValue(raw[i + 3 + k]);
                            if (h < 0) {
                                lo = 0;
                                break;
                            }
                            lo = lo * 16 + cast(uint) h;
                        }
                        if (lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    }
                    appendUtf8(dst, cp);
                    break;
                }
                default:
                    return false;
            }
            i++;
        } else {
            // Copy the plain run in one go.
            size_t start = i;
            while (i < raw.length - 1 && raw[i] != '\\') i++;
            dst.put(raw[start .. i]);
        }
    }
    return true;
}

private int hexValue(char c) pure nothrow @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private void appendUtf8(ref Appender!(char[]) dst, uint cp) @trusted pure nothrow
{
    if (cp < 0x80) {
        dst.put(cast(char) cp);
    } else if (cp < 0x800) {
        dst.put(cast(char)(0xC0 | (cp >> 6)));
        dst.put(cast(char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        dst.put(cast(char)(0xE0 | (cp >> 12)));
        dst.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        dst.put(cast(char)(0x80 | (cp & 0x3F)));
    } else {
        dst.put(cast(char)(0xF0 | (cp >> 18)));
        dst.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        dst.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        dst.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

@safe unittest
{
    // ---- object parsing ----
    const(char)[] inner;
    assert(findWrapper(`{"user": {"username": "a", "email": "b"}}`, "user", inner));
    assert(inner == `{"username": "a", "email": "b"}`, inner);
    assert(findWrapper(`{"user":{}}`, "user", inner));
    assert(!findWrapper(`{"user": {"username": "a",`, "user", inner));
    assert(!findWrapper(`{"user": }`, "user", inner));
    assert(!findWrapper(`{"article": `, "article", inner));
    assert(!findWrapper(``, "user", inner));
    assert(!findWrapper(`{"user": "a"}`, "user", inner));
    assert(!findWrapper(`{"user": 5}`, "user", inner));
    assert(!findWrapper(`{"user": null}`, "user", inner));

    // ---- member access ----
    assert(findWrapper(`{"user":{"username":"a","bio":null,"image":""}}`, "user", inner));
    auto obj = JsonObject.init;
    assert(obj.parseObject(inner));
    Member m;
    const(char)[] username, bio, image, missing;
    while (obj.next(m)) {
        switch (m.name) {
            case "username": username = m.value; break;
            case "bio": bio = m.value; break;
            case "image": image = m.value; break;
            default: missing = m.value; break;
        }
    }
    assert(obj.ok);
    assert(username == `"a"`);
    assert(bio == `null`);
    assert(image == `""`);
    assert(missing.length == 0);

    // ---- arrays ----
    assert(findWrapper(`{"article":{"title":"t","tagList":["a","b"]}}`, "article", inner));
    auto arr = JsonArray(m_value(inner, "tagList"));
    assert(arr.ok);
    const(char)[] item;
    assert(arr.next(item) && item == `"a"`);
    assert(arr.next(item) && item == `"b"`);
    assert(!arr.next(item));

    // ---- string decoding ----
    auto dst = appender!(char[]);
    assert(decodeString(`"plain"`, dst) && dst.data == "plain");
    dst.clear();
    assert(decodeString(`"a\"b\\c\nd\tz"`, dst) && dst.data == "a\"b\\c\nd\tz");
    dst.clear();
    assert(decodeString(`"\u00fc\ud83d\ude00"`, dst) && dst.data == "ü😀", dst.data);
    dst.clear();
    assert(!decodeString(`"abc`, dst));
    assert(decodeString(`""`, dst) && dst.data == "");
}

/// Test helper: a member's raw value.
private const(char)[] m_value(const(char)[] objectText, const(char)[] name) @trusted
{
    auto o = JsonObject.init;
    assert(o.parseObject(objectText));
    Member m;
    while (o.next(m))
        if (m.name == name) return m.value;
    return null;
}
