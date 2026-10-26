package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json/jsontext"
	"hash"
	"simd/archsimd"
	"strconv"
	"time"
	"unsafe"

	"github.com/golang-jwt/jwt/v5"
)

const (
	pgEpochOffsetMicros = 946684800_000_000
	jwtValidityWindow   = 30 * 24 * time.Hour
	jwtHS256Prefix      = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
)

var (
	pgBoolTrue  = []byte{1}
	pgBoolFalse = []byte{0}
	emptySlice  = []byte{}

	msgBadRequest    = []byte(`{"errors":{"body":["invalid request"]}}`)
	msgUnauthorized  = []byte(`{"errors":{"body":["unauthorized"]}}`)
	msgNotFound      = []byte(`{"errors":{"body":["not found"]}}`)
	msgArticle404    = []byte(`{"errors":{"body":["article not found"]}}`)
	msgProfile404    = []byte(`{"errors":{"body":["profile not found"]}}`)
	msgComment404    = []byte(`{"errors":{"body":["comment not found"]}}`)
	msgForbidden     = []byte(`{"errors":{"body":["not the author"]}}`)
	msgMalformedBody = []byte(`{"errors":{"body":["invalid body"]}}`)
	msgServerError   = []byte(`{"errors":{"body":["internal error"]}}`)
	msgServerBusy    = []byte(`{"errors":{"body":["server busy"]}}`)
	msgBadPagination = []byte(`{"errors":{"body":["limit must be 1-100 and offset >= 0"]}}`)
	msgBadLogin      = []byte(`{"errors":{"body":["invalid email or password"]}}`)
	msgDuplicateUser = []byte(`{"errors":{"body":["username or email is already taken"]}}`)
	msgPassTooLong   = []byte(`{"errors":{"body":["password is too long"]}}`)
	msgRegRequired   = []byte(`{"errors":{"body":["username, email and password are required"]}}`)
	msgLoginRequired = []byte(`{"errors":{"body":["email and password are required"]}}`)
	msgBadUserUpdate = []byte(`{"errors":{"body":["invalid user fields"]}}`)
	msgArtRequired   = []byte(`{"errors":{"body":["title, description and body are required"]}}`)
	msgBadArtUpdate  = []byte(`{"errors":{"body":["title, description and body must be non-empty strings"]}}`)
	msgBadTagList    = []byte(`{"errors":{"body":["tagList must be an array of non-empty strings"]}}`)
	msgCmtRequired   = []byte(`{"errors":{"body":["body is required"]}}`)
)

func bytesToStr(b []byte) string {
	return unsafe.String(unsafe.SliceData(b), len(b))
}

func strToBytes(s string) []byte {
	if s == "" {
		return emptySlice
	}
	return unsafe.Slice(unsafe.StringData(s), len(s))
}

func writeJSONStr(dst, val []byte) []byte {
	i := 0
	if len(val) >= 32 && archsimd.X86.AVX() {
		vMin := archsimd.BroadcastInt8x16(0x20)
		vQuote := archsimd.BroadcastInt8x16('"')
		vSlash := archsimd.BroadcastInt8x16('\\')
		for ; i+16 <= len(val); i += 16 {
			chunk := archsimd.LoadUint8x16(val[i:]).AsInt8x16()
			bad := chunk.Less(vMin).Or(chunk.Equal(vQuote)).Or(chunk.Equal(vSlash))
			if !bad.ToInt8x16().IsZero() {
				out, _ := jsontext.AppendQuote(dst, val)
				return out
			}
		}
	}
	for ; i < len(val); i++ {
		c := val[i]
		if int8(c) < 0x20 || c == '"' || c == '\\' {
			out, _ := jsontext.AppendQuote(dst, val)
			return out
		}
	}
	dst = append(dst, '"')
	dst = append(dst, val...)
	return append(dst, '"')
}

func writeOptJSONStr(dst, val []byte) []byte {
	if val == nil {
		return append(dst, "null"...)
	}
	return writeJSONStr(dst, val)
}

func writeJSONBool(dst, val []byte) []byte {
	if len(val) == 1 && val[0] != 0 {
		return append(dst, "true"...)
	}
	return append(dst, "false"...)
}

func decodePGInt8(val []byte) int64 {
	if len(val) != 8 {
		return 0
	}
	return int64(binary.BigEndian.Uint64(val))
}

func writePGInt8(dst, val []byte) []byte {
	return strconv.AppendInt(dst, decodePGInt8(val), 10)
}

func encodePGInt8(buf *[8]byte, v int64) []byte {
	binary.BigEndian.PutUint64(buf[:], uint64(v))
	return buf[:]
}

func writePGTimestamp(dst, raw []byte) []byte {
	us := decodePGInt8(raw)
	ms := us / 1000
	if us%1000 < 0 {
		ms--
	}
	ts := time.UnixMilli(ms + pgEpochOffsetMicros/1000).UTC()
	return ts.AppendFormat(dst, `"2006-01-02T15:04:05.000Z"`)
}

func writeTimestamps(dst, createdRaw, updatedRaw []byte) []byte {
	dst = append(dst, `,"createdAt":`...)
	cStart := len(dst)
	dst = writePGTimestamp(dst, createdRaw)
	cEnd := len(dst)
	dst = append(dst, `,"updatedAt":`...)
	if len(createdRaw) == 8 && len(updatedRaw) == 8 &&
		binary.BigEndian.Uint64(createdRaw) == binary.BigEndian.Uint64(updatedRaw) {
		return append(dst, dst[cStart:cEnd]...)
	}
	return writePGTimestamp(dst, updatedRaw)
}

func writePGTextArray(dst, raw []byte) []byte {
	dst = append(dst, '[')
	if len(raw) >= 20 && binary.BigEndian.Uint32(raw[:4]) == 1 {
		elemCount := int(int32(binary.BigEndian.Uint32(raw[12:16])))
		cursor := 20
		for idx := 0; idx < elemCount && cursor+4 <= len(raw); idx++ {
			elemLen := int(int32(binary.BigEndian.Uint32(raw[cursor : cursor+4])))
			cursor += 4
			if idx > 0 {
				dst = append(dst, ',')
			}
			if elemLen < 0 || cursor+elemLen > len(raw) {
				dst = append(dst, "null"...)
				continue
			}
			dst = writeJSONStr(dst, raw[cursor:cursor+elemLen])
			cursor += elemLen
		}
	}
	return append(dst, ']')
}

func encodePGTextArray(dst []byte, elems []string) []byte {
	var header [20]byte
	if len(elems) == 0 {
		binary.BigEndian.PutUint32(header[8:12], pgOIDText)
		return append(dst, header[:12]...)
	}
	binary.BigEndian.PutUint32(header[0:4], 1)
	binary.BigEndian.PutUint32(header[8:12], pgOIDText)
	binary.BigEndian.PutUint32(header[12:16], uint32(len(elems)))
	binary.BigEndian.PutUint32(header[16:20], 1)
	dst = append(dst, header[:]...)
	for _, s := range elems {
		var lenBuf [4]byte
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(s)))
		dst = append(dst, lenBuf[:]...)
		dst = append(dst, s...)
	}
	return dst
}

type tokenSigner struct {
	key []byte
	mac hash.Hash
	buf [sha256.Size]byte
}

func newTokenSigner(secret []byte) *tokenSigner {
	return &tokenSigner{
		key: secret,
		mac: hmac.New(sha256.New, secret),
	}
}

func (ts *tokenSigner) encodeToken(dst []byte, uid int64, now time.Time) []byte {
	var claimBuf [96]byte
	c := append(claimBuf[:0], `{"sub":"`...)
	c = strconv.AppendInt(c, uid, 10)
	c = append(c, `","exp":`...)
	c = strconv.AppendInt(c, now.Add(jwtValidityWindow).Unix(), 10)
	c = append(c, `,"iat":`...)
	c = strconv.AppendInt(c, now.Unix(), 10)
	c = append(c, '}')

	msgStart := len(dst)
	dst = append(dst, jwtHS256Prefix...)
	dst = append(dst, '.')
	dst = base64.RawURLEncoding.AppendEncode(dst, c)

	ts.mac.Reset()
	ts.mac.Write(dst[msgStart:])
	sig := ts.mac.Sum(ts.buf[:0])

	dst = append(dst, '.')
	return base64.RawURLEncoding.AppendEncode(dst, sig)
}

func (ts *tokenSigner) verifyToken(tok []byte) (int64, bool) {
	dot1 := bytes.IndexByte(tok, '.')
	if dot1 <= 0 {
		return 0, false
	}
	dot2 := bytes.IndexByte(tok[dot1+1:], '.')
	if dot2 <= 0 {
		return 0, false
	}
	dot2 += dot1 + 1

	if bytesToStr(tok[:dot1]) == jwtHS256Prefix {
		sigPart := tok[dot2+1:]
		if len(sigPart) != 43 {
			return 0, false
		}
		var rawSig [36]byte
		if n, err := base64.RawURLEncoding.Decode(rawSig[:], sigPart); err != nil || n != sha256.Size {
			return 0, false
		}
		ts.mac.Reset()
		ts.mac.Write(tok[:dot2])
		if !hmac.Equal(ts.mac.Sum(ts.buf[:0]), rawSig[:sha256.Size]) {
			return 0, false
		}
		claimPart := tok[dot1+1 : dot2]
		if len(claimPart) <= 160 {
			var decoded [128]byte
			n, err := base64.RawURLEncoding.Decode(decoded[:], claimPart)
			if err != nil {
				return 0, false
			}
			if uid, ok, fast := checkStandardClaims(decoded[:n], time.Now().UnixNano()); fast {
				return uid, ok
			}
		}
	}

	var parsed jwt.RegisteredClaims
	_, err := jwt.ParseWithClaims(string(tok), &parsed, func(*jwt.Token) (any, error) {
		return ts.key, nil
	}, jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired())
	if err != nil {
		return 0, false
	}
	uid, ok := parsePositiveInt(parsed.Subject)
	return uid, ok && uid > 0
}

func checkStandardClaims(b []byte, nowNano int64) (uid int64, ok, fast bool) {
	pos := skipSpaces(b, 0)
	if pos >= len(b) || b[pos] != '{' {
		return 0, false, false
	}
	pos = skipSpaces(b, pos+1)
	var subSlice []byte
	var expSec, nbfSec int64
	var gotSub, gotExp, gotNbf, gotIat bool

	for pos < len(b) && b[pos] != '}' {
		k, nextPos, valid := readASCIIQuote(b, pos)
		if !valid {
			return 0, false, false
		}
		pos = skipSpaces(b, nextPos)
		if pos >= len(b) || b[pos] != ':' {
			return 0, false, false
		}
		pos = skipSpaces(b, pos+1)
		switch bytesToStr(k) {
		case "sub":
			if gotSub {
				return 0, false, false
			}
			subSlice, pos, valid = readASCIIQuote(b, pos)
			gotSub = true
		case "exp":
			if gotExp {
				return 0, false, false
			}
			expSec, pos, valid = readASCIIUint(b, pos)
			gotExp = true
		case "nbf":
			if gotNbf {
				return 0, false, false
			}
			nbfSec, pos, valid = readASCIIUint(b, pos)
			gotNbf = true
		case "iat":
			if gotIat {
				return 0, false, false
			}
			_, pos, valid = readASCIIUint(b, pos)
			gotIat = true
		default:
			return 0, false, false
		}
		if !valid {
			return 0, false, false
		}
		pos = skipSpaces(b, pos)
		if pos < len(b) && b[pos] == ',' {
			pos = skipSpaces(b, pos+1)
			if pos >= len(b) || b[pos] == '}' {
				return 0, false, false
			}
		} else {
			break
		}
	}
	if pos >= len(b) || b[pos] != '}' || skipSpaces(b, pos+1) != len(b) {
		return 0, false, false
	}
	if !gotExp || nowNano >= expSec*1e9 || (gotNbf && nowNano < nbfSec*1e9) || !gotSub {
		return 0, false, true
	}
	id, validID := parsePositiveInt(bytesToStr(subSlice))
	return id, validID && id > 0, true
}

func skipSpaces(b []byte, idx int) int {
	const wsMask = (uint64(1) << ' ') | (uint64(1) << '\n') | (uint64(1) << '\r') | (uint64(1) << '\t')
	for idx < len(b) {
		c := b[idx]
		if c > ' ' || (wsMask>>c)&1 == 0 {
			return idx
		}
		idx++
	}
	return idx
}

func readASCIIQuote(b []byte, idx int) ([]byte, int, bool) {
	if idx >= len(b) || b[idx] != '"' {
		return nil, idx, false
	}
	for end := idx + 1; end < len(b); end++ {
		ch := b[end]
		if ch == '"' {
			return b[idx+1 : end], end + 1, true
		}
		if int8(ch) < 0x20 || ch == '\\' {
			return nil, end, false
		}
	}
	return nil, idx, false
}

func readASCIIUint(b []byte, idx int) (int64, int, bool) {
	var val int64
	end := idx
	for end < len(b) {
		d := b[end] - '0'
		if d > 9 {
			break
		}
		val = val*10 + int64(d)
		end++
	}
	digits := end - idx
	if digits == 0 || digits > 12 || (b[idx] == '0' && digits > 1) {
		return 0, end, false
	}
	if end < len(b) && (b[end] == '.' || (b[end]|0x20) == 'e') {
		return 0, end, false
	}
	return val, end, true
}
