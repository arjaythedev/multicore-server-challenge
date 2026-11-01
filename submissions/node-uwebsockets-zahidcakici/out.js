'use strict';
// Responses are written as bytes into one buffer per batch: constant JSON fragments are copied in, text columns
// are copied from the Postgres receive buffer with JSON escaping, integers and timestamps are formatted in place.
// No JS string is created for any row data.

const HEX = Buffer.from('0123456789abcdef');
const EPOCH_2000_MS = 946684800000;

function lit(s) { return Buffer.from(s, 'latin1'); }

class Out {
  constructor(size) {
    this.b = Buffer.allocUnsafe(size || 1 << 20);
    this.p = 0;
  }
  need(n) {
    if (this.p + n > this.b.length) {
      const nb = Buffer.allocUnsafe(Math.max(this.b.length * 2, this.p + n + 65536));
      this.b.copy(nb, 0, 0, this.p);
      this.b = nb;
    }
  }
  // a constant fragment (Buffer)
  lit(c) {
    const n = c.length;
    this.need(n);
    const b = this.b;
    let p = this.p;
    if (n < 24) { for (let i = 0; i < n; i++) b[p + i] = c[i]; } else c.copy(b, p);
    this.p = p + n;
  }
  ch(c) { this.need(1); this.b[this.p++] = c; }
  // JSON string from UTF-8 bytes src[off, off+len)
  bstr(src, off, len) {
    this.need(len * 6 + 2);
    const b = this.b;
    let p = this.p;
    b[p++] = 34;
    const e = off + len;
    for (let i = off; i < e; i++) {
      const c = src[i];
      if (c >= 32 && c !== 34 && c !== 92) { b[p++] = c; continue; }
      b[p++] = 92;
      if (c === 34 || c === 92) b[p++] = c;
      else if (c === 10) b[p++] = 110;
      else if (c === 13) b[p++] = 114;
      else if (c === 9) b[p++] = 116;
      else if (c === 8) b[p++] = 98;
      else if (c === 12) b[p++] = 102;
      else { b[p++] = 117; b[p++] = 48; b[p++] = 48; b[p++] = HEX[c >> 4]; b[p++] = HEX[c & 15]; }
    }
    b[p++] = 34;
    this.p = p;
  }
  // JSON string or null from a Postgres column
  col(pg, c) {
    const l = pg.colLen[c];
    if (l < 0) this.lit(NULL);
    else this.bstr(pg.rb, pg.colOff[c], l);
  }
  // JSON string from a JS string (request data)
  jstr(s) {
    if (s == null) { this.lit(NULL); return; }
    const j = JSON.stringify(s);
    this.need(j.length * 3);
    this.p += this.b.utf8Write(j, this.p);
  }
  int(n) {
    this.need(24);
    const b = this.b;
    if (n < 0) { b[this.p++] = 45; n = -n; }
    if (n < 10) { b[this.p++] = 48 + n; return; }
    let p = this.p;
    let digits = 0;
    for (let t = n; t >= 1; t = Math.floor(t / 10)) digits++;
    let q = p + digits;
    this.p = q;
    while (n >= 1) { const d = n % 10; b[--q] = 48 + d; n = (n - d) / 10; }
  }
  bool(v) { this.lit(v ? TRUE : FALSE); }
  // "YYYY-MM-DDTHH:MM:SS.mmmZ" from a binary timestamptz (microseconds since 2000-01-01), truncated to ms
  ts(us) {
    const ms = Math.floor(us / 1000) + EPOCH_2000_MS;
    const days = Math.floor(ms / 86400000);
    let rem = ms - days * 86400000;
    // civil date from days since 1970-01-01 (H. Hinnant)
    const z = days + 719468;
    const era = Math.floor(z / 146097);
    const doe = z - era * 146097;
    const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    let y = yoe + era * 400;
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    const mp = Math.floor((5 * doy + 2) / 153);
    const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
    const m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    const hh = Math.floor(rem / 3600000); rem -= hh * 3600000;
    const mi = Math.floor(rem / 60000); rem -= mi * 60000;
    const ss = Math.floor(rem / 1000); const mss = rem - ss * 1000;
    this.need(26);
    const b = this.b;
    let p = this.p;
    b[p] = 34;
    b[p + 1] = 48 + Math.floor(y / 1000) % 10; b[p + 2] = 48 + Math.floor(y / 100) % 10;
    b[p + 3] = 48 + Math.floor(y / 10) % 10; b[p + 4] = 48 + y % 10; b[p + 5] = 45;
    b[p + 6] = 48 + Math.floor(m / 10); b[p + 7] = 48 + m % 10; b[p + 8] = 45;
    b[p + 9] = 48 + Math.floor(d / 10); b[p + 10] = 48 + d % 10; b[p + 11] = 84;
    b[p + 12] = 48 + Math.floor(hh / 10); b[p + 13] = 48 + hh % 10; b[p + 14] = 58;
    b[p + 15] = 48 + Math.floor(mi / 10); b[p + 16] = 48 + mi % 10; b[p + 17] = 58;
    b[p + 18] = 48 + Math.floor(ss / 10); b[p + 19] = 48 + ss % 10; b[p + 20] = 46;
    b[p + 21] = 48 + Math.floor(mss / 100); b[p + 22] = 48 + Math.floor(mss / 10) % 10; b[p + 23] = 48 + mss % 10;
    b[p + 24] = 90; b[p + 25] = 34;
    this.p = p + 26;
  }
}

const NULL = lit('null');
const TRUE = lit('true');
const FALSE = lit('false');

module.exports = { Out, lit };
