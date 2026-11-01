# JSON input: a strict tokenizer for request bodies and JWT segments. One pass builds a flat token list; each token
# records where its subtree ends, so object members can be walked without a tree. Anything that isn't valid JSON
# (trailing bytes, bad escapes, unterminated input, deep nesting) is rejected.

from buf import BytePtr, ByteBuf

comptime T_OBJECT = 1
comptime T_ARRAY = 2
comptime T_STRING = 3
comptime T_NUMBER = 4
comptime T_TRUE = 5
comptime T_FALSE = 6
comptime T_NULL = 7

comptime MAX_DEPTH = 32


struct Tok(ImplicitlyCopyable):
    var kind: Int
    var start: Int  # strings: first byte after the quote; others: first byte
    var end: Int  # strings: the closing quote; others: one past the last byte
    var next: Int  # index of the first token after this one's subtree
    var escaped: Bool  # strings: contains a backslash

    def __init__(out self, kind: Int, start: Int):
        self.kind = kind
        self.start = start
        self.end = start
        self.next = 0
        self.escaped = False


struct Json:
    var p: BytePtr
    var n: Int
    var toks: List[Tok]
    var pos: Int
    var ok: Bool

    def __init__(out self, p: BytePtr, n: Int):
        """Parses p[0:n]. Check `ok`; the root value is token 0."""
        self.p = p
        self.n = n
        self.toks = List[Tok]()
        self.pos = 0
        self.ok = False
        self.ok = self.value(0)
        if self.ok:
            self.skip_ws()
            self.ok = self.pos == self.n

    @inline(.always)
    def skip_ws(mut self):
        while self.pos < self.n:
            var c = self.p[unsafe_offset=self.pos]
            if c == 32 or c == 10 or c == 13 or c == 9:
                self.pos += 1
            else:
                return

    def value(mut self, depth: Int) -> Bool:
        if depth > MAX_DEPTH:
            return False
        self.skip_ws()
        if self.pos >= self.n:
            return False
        var c = self.p[unsafe_offset=self.pos]
        var idx = len(self.toks)
        if c == 123:  # {
            self.toks.append(Tok(T_OBJECT, self.pos))
            self.pos += 1
            self.skip_ws()
            if self.pos < self.n and self.p[unsafe_offset=self.pos] == 125:
                self.pos += 1
            else:
                while True:
                    self.skip_ws()
                    if self.pos >= self.n or self.p[unsafe_offset=self.pos] != 34:
                        return False
                    if not self.string():
                        return False
                    self.skip_ws()
                    if self.pos >= self.n or self.p[unsafe_offset=self.pos] != 58:  # :
                        return False
                    self.pos += 1
                    if not self.value(depth + 1):
                        return False
                    self.skip_ws()
                    if self.pos >= self.n:
                        return False
                    var d = self.p[unsafe_offset=self.pos]
                    self.pos += 1
                    if d == 125:  # }
                        break
                    if d != 44:  # ,
                        return False
        elif c == 91:  # [
            self.toks.append(Tok(T_ARRAY, self.pos))
            self.pos += 1
            self.skip_ws()
            if self.pos < self.n and self.p[unsafe_offset=self.pos] == 93:
                self.pos += 1
            else:
                while True:
                    if not self.value(depth + 1):
                        return False
                    self.skip_ws()
                    if self.pos >= self.n:
                        return False
                    var d = self.p[unsafe_offset=self.pos]
                    self.pos += 1
                    if d == 93:  # ]
                        break
                    if d != 44:
                        return False
        elif c == 34:
            return self.string()
        elif c == 116:
            return self.literal("true", T_TRUE)
        elif c == 102:
            return self.literal("false", T_FALSE)
        elif c == 110:
            return self.literal("null", T_NULL)
        elif c == 45 or (c >= 48 and c <= 57):
            return self.number()
        else:
            return False
        self.toks[idx].end = self.pos
        self.toks[idx].next = len(self.toks)
        return True

    def literal(mut self, word: StaticString, kind: Int) -> Bool:
        var l = word.byte_length()
        if self.pos + l > self.n:
            return False
        var w = word.unsafe_ptr()
        for i in range(l):
            if self.p[unsafe_offset=self.pos + i] != w[unsafe_offset=i]:
                return False
        var t = Tok(kind, self.pos)
        self.pos += l
        t.end = self.pos
        t.next = len(self.toks) + 1
        self.toks.append(t)
        return True

    def number(mut self) -> Bool:
        var t = Tok(T_NUMBER, self.pos)
        if self.p[unsafe_offset=self.pos] == 45:
            self.pos += 1
        if self.pos >= self.n:
            return False
        if self.p[unsafe_offset=self.pos] == 48:
            self.pos += 1
        elif self.digits() == 0:
            return False
        if self.pos < self.n and self.p[unsafe_offset=self.pos] == 46:  # .
            self.pos += 1
            if self.digits() == 0:
                return False
        if self.pos < self.n and (self.p[unsafe_offset=self.pos] | 0x20) == 101:  # e E
            self.pos += 1
            if self.pos < self.n and (self.p[unsafe_offset=self.pos] == 43 or self.p[unsafe_offset=self.pos] == 45):
                self.pos += 1
            if self.digits() == 0:
                return False
        t.end = self.pos
        t.next = len(self.toks) + 1
        self.toks.append(t)
        return True

    def digits(mut self) -> Int:
        var start = self.pos
        while self.pos < self.n and self.p[unsafe_offset=self.pos] >= 48 and self.p[unsafe_offset=self.pos] <= 57:
            self.pos += 1
        return self.pos - start

    def string(mut self) -> Bool:
        self.pos += 1  # opening quote
        var t = Tok(T_STRING, self.pos)
        while self.pos < self.n:
            var c = self.p[unsafe_offset=self.pos]
            if c == 34:
                t.end = self.pos
                t.next = len(self.toks) + 1
                self.pos += 1
                self.toks.append(t)
                return True
            if c < 0x20:
                return False
            if c == 92:
                t.escaped = True
                self.pos += 1
                if self.pos >= self.n:
                    return False
                var e = self.p[unsafe_offset=self.pos]
                if e == 117:  # u: four hex digits
                    if self.pos + 4 >= self.n:
                        return False
                    for k in range(1, 5):
                        if hexval(self.p[unsafe_offset=self.pos + k]) < 0:
                            return False
                    self.pos += 4
                elif not (e == 34 or e == 92 or e == 47 or e == 98 or e == 102 or e == 110 or e == 114 or e == 116):
                    return False
            self.pos += 1
        return False

    # --- reading ---

    def get(self, obj: Int, key: StaticString) -> Int:
        """The value token of `key` in object token `obj`, or -1. Keys are compared raw (no escapes in our keys)."""
        if obj < 0 or self.toks[obj].kind != T_OBJECT:
            return -1
        var i = obj + 1
        var end = self.toks[obj].next
        var kl = key.byte_length()
        var kp = key.unsafe_ptr()
        var found = -1
        while i < end:
            var k = self.toks[i]
            var v = i + 1
            if not k.escaped and k.end - k.start == kl:
                var same = True
                for j in range(kl):
                    if self.p[unsafe_offset=k.start + j] != kp[unsafe_offset=j]:
                        same = False
                        break
                if same:
                    found = v  # the last duplicate wins, as in most JSON decoders
            i = self.toks[v].next
        return found

    def kind(self, t: Int) -> Int:
        return self.toks[t].kind if t >= 0 else 0

    def string_value(self, t: Int, mut out: ByteBuf) -> Bool:
        """Appends the decoded string to `out`. False if `t` isn't a string or has an invalid \\u sequence."""
        if t < 0 or self.toks[t].kind != T_STRING:
            return False
        var tok = self.toks[t]
        if not tok.escaped:
            out.put_bytes(self.p.unsafe_offset(tok.start), tok.end - tok.start)
            return True
        var i = tok.start
        while i < tok.end:
            var c = self.p[unsafe_offset=i]
            if c != 92:
                out.put(c)
                i += 1
                continue
            var e = self.p[unsafe_offset=i + 1]
            i += 2
            if e == 98:
                out.put(8)
            elif e == 102:
                out.put(12)
            elif e == 110:
                out.put(10)
            elif e == 114:
                out.put(13)
            elif e == 116:
                out.put(9)
            elif e == 117:
                var cp = hex4(self.p.unsafe_offset(i))
                i += 4
                if cp >= 0xD800 and cp <= 0xDBFF:
                    # a high surrogate must be followed by \u and a low surrogate
                    if i + 6 > tok.end or self.p[unsafe_offset=i] != 92 or self.p[unsafe_offset=i + 1] != 117:
                        return False
                    var lo = hex4(self.p.unsafe_offset(i + 2))
                    if lo < 0xDC00 or lo > 0xDFFF:
                        return False
                    i += 6
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                elif cp >= 0xDC00 and cp <= 0xDFFF:
                    return False
                put_utf8(out, cp)
            else:
                out.put(e)  # " \ /
        return True

    def int_value(self, t: Int, mut ok: Bool) -> Int:
        """An integer JSON number (no fraction or exponent) that fits comfortably in an Int."""
        ok = False
        if t < 0 or self.toks[t].kind != T_NUMBER:
            return 0
        var tok = self.toks[t]
        var i = tok.start
        var neg = False
        if self.p[unsafe_offset=i] == 45:
            neg = True
            i += 1
        if tok.end - i > 18:
            return 0
        var v = 0
        while i < tok.end:
            var c = self.p[unsafe_offset=i]
            if c < 48 or c > 57:
                return 0
            v = v * 10 + Int(c) - 48
            i += 1
        ok = True
        return -v if neg else v


@inline(.always)
def hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    var l = c | 0x20
    if l >= 97 and l <= 102:
        return Int(l) - 87
    return -1


def hex4(p: BytePtr) -> Int:
    return (
        (hexval(p[unsafe_offset=0]) << 12)
        | (hexval(p[unsafe_offset=1]) << 8)
        | (hexval(p[unsafe_offset=2]) << 4)
        | hexval(p[unsafe_offset=3])
    )


def put_utf8(mut out: ByteBuf, cp: Int):
    if cp < 0x80:
        out.put(UInt8(cp))
    elif cp < 0x800:
        out.put(UInt8(0xC0 | (cp >> 6)))
        out.put(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.put(UInt8(0xE0 | (cp >> 12)))
        out.put(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.put(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.put(UInt8(0xF0 | (cp >> 18)))
        out.put(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.put(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.put(UInt8(0x80 | (cp & 0x3F)))
