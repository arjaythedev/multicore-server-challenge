package main

import (
	"bytes"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"
	"unsafe"
)

const (
	limitHeaderBytes = 16 << 10
	limitBodyBytes   = 1 << 20
	limitFrameBytes  = limitHeaderBytes + limitBodyBytes + (64 << 10)
	arenaChunkBytes  = 16 << 10
)

type httpFrame struct {
	verb, uri, authVal, payload []byte
	authHeaders                 int
	shouldClose, isHead         bool
	isHTTP10, wantsContinue     bool
	isChunked, parsedHeaders    bool
}

type httpReply struct {
	code    int
	payload []byte
}

func remapSubslice(targetBuf, originBuf, sub []byte) []byte {
	if len(sub) == 0 {
		return nil
	}
	delta := int(uintptr(unsafe.Pointer(&sub[0])) - uintptr(unsafe.Pointer(&originBuf[0])))
	return targetBuf[delta : delta+len(sub)]
}

func remapHTTPFrame(dst *httpFrame, dstBuf, srcBuf []byte, src httpFrame) {
	*dst = src
	dst.verb = remapSubslice(dstBuf, srcBuf, src.verb)
	dst.uri = remapSubslice(dstBuf, srcBuf, src.uri)
	dst.authVal = remapSubslice(dstBuf, srcBuf, src.authVal)
	dst.payload = remapSubslice(dstBuf, srcBuf, src.payload)
}

func validTChar(c byte) bool {
	switch c {
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.',
		'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
		'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
		'^', '_', '`',
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
		'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
		'|', '~':
		return true
	default:
		return false
	}
}

func decodeHexNibble(c byte) int {
	switch c {
	case '0':
		return 0
	case '1':
		return 1
	case '2':
		return 2
	case '3':
		return 3
	case '4':
		return 4
	case '5':
		return 5
	case '6':
		return 6
	case '7':
		return 7
	case '8':
		return 8
	case '9':
		return 9
	case 'A', 'a':
		return 10
	case 'B', 'b':
		return 11
	case 'C', 'c':
		return 12
	case 'D', 'd':
		return 13
	case 'E', 'e':
		return 14
	case 'F', 'f':
		return 15
	default:
		return -1
	}
}

func matchHeaderKey(raw []byte, lowerKey string) bool {
	if len(raw) != len(lowerKey) {
		return false
	}
	for i := 0; i < len(raw); i++ {
		ch := raw[i]
		k := lowerKey[i]
		if ch != k && (ch|0x20 != k || k < 'a') {
			return false
		}
	}
	return true
}

func containsHeaderToken(raw []byte, lowerTok string) bool {
	for len(raw) > 0 {
		seg, rem, hasMore := bytes.Cut(raw, []byte(","))
		if matchHeaderKey(bytes.Trim(seg, " \t"), lowerTok) {
			return true
		}
		if !hasMore {
			break
		}
		raw = rem
	}
	return false
}

func scanHTTPFrame(raw []byte, out *httpFrame) int {
	*out = httpFrame{}
	hdrSep := bytes.Index(raw, []byte("\r\n\r\n"))
	if hdrSep < 0 {
		if len(raw) >= limitHeaderBytes {
			return -400
		}
		return 0
	}
	bodyStart := hdrSep + 4
	if bodyStart > limitHeaderBytes {
		return -400
	}

	firstCRLF := bytes.Index(raw[:bodyStart], []byte("\r\n"))
	if firstCRLF <= 0 {
		return -400
	}
	startLine := raw[:firstCRLF]
	sp1 := bytes.IndexByte(startLine, ' ')
	if sp1 <= 0 {
		return -400
	}
	out.verb = startLine[:sp1]
	for _, ch := range out.verb {
		if !validTChar(ch) {
			return -400
		}
	}
	afterVerb := startLine[sp1+1:]
	sp2 := bytes.IndexByte(afterVerb, ' ')
	if sp2 <= 0 {
		return -400
	}
	out.uri = afterVerb[:sp2]
	if out.uri[0] != '/' {
		return -400
	}
	for i := 0; i < len(out.uri); i++ {
		ch := out.uri[i]
		if ch-0x26 >= 0x59 {
			if ch <= 0x20 || ch == 0x7f || ch == '#' {
				return -400
			}
			if ch == '%' {
				if i+2 >= len(out.uri) || decodeHexNibble(out.uri[i+1]) < 0 || decodeHexNibble(out.uri[i+2]) < 0 {
					return -400
				}
				i += 2
			}
		}
	}
	switch bytesToStr(afterVerb[sp2+1:]) {
	case "HTTP/1.1":
	case "HTTP/1.0":
		out.isHTTP10 = true
		out.shouldClose = true
	default:
		return -400
	}
	out.isHead = bytesToStr(out.verb) == "HEAD"

	var (
		parsedLen  int
		seenCL     bool
		seenTE     bool
		hostCount  int
		explicitCl bool
	)
	for offset := firstCRLF + 2; offset < hdrSep; {
		lineLen := bytes.Index(raw[offset:bodyStart], []byte("\r\n"))
		if lineLen < 0 {
			return -400
		}
		hdrLine := raw[offset : offset+lineLen]
		offset += lineLen + 2
		colonPos := bytes.IndexByte(hdrLine, ':')
		if colonPos <= 0 {
			return -400
		}
		hName := hdrLine[:colonPos]
		for _, ch := range hName {
			if !validTChar(ch) {
				return -400
			}
		}
		hVal := bytes.Trim(hdrLine[colonPos+1:], " \t")
		for _, ch := range hVal {
			if ch-0x20 >= 0x5f && ch != '\t' && ch < 0x80 {
				return -400
			}
		}
		switch len(hName) {
		case 4:
			if matchHeaderKey(hName, "host") {
				hostCount++
				if hostCount > 1 || len(hVal) == 0 {
					return -400
				}
			}
		case 6:
			if matchHeaderKey(hName, "expect") {
				if !matchHeaderKey(hVal, "100-continue") {
					return -417
				}
				out.wantsContinue = true
			}
		case 10:
			if matchHeaderKey(hName, "connection") {
				if containsHeaderToken(hVal, "close") {
					explicitCl = true
					out.shouldClose = true
				} else if !explicitCl && containsHeaderToken(hVal, "keep-alive") {
					out.shouldClose = false
				}
			}
		case 13:
			if matchHeaderKey(hName, "authorization") {
				out.authHeaders++
				out.authVal = hVal
			}
		case 14:
			if matchHeaderKey(hName, "content-length") {
				if seenCL || len(hVal) == 0 {
					return -400
				}
				seenCL = true
				for _, ch := range hVal {
					d := ch - '0'
					if d > 9 {
						return -400
					}
					if parsedLen > limitBodyBytes/10 {
						return -413
					}
					parsedLen = parsedLen*10 + int(d)
					if parsedLen > limitBodyBytes {
						return -413
					}
				}
			}
		case 17:
			if matchHeaderKey(hName, "transfer-encoding") {
				if seenTE || !matchHeaderKey(hVal, "chunked") {
					return -400
				}
				seenTE = true
				out.isChunked = true
			}
		}
	}
	if (!out.isHTTP10 && hostCount != 1) || (seenCL && seenTE) {
		return -400
	}
	out.parsedHeaders = true
	if seenTE {
		frameEnd := scanChunkedStream(raw, bodyStart)
		if frameEnd > 0 {
			out.payload = raw[bodyStart:frameEnd]
		}
		return frameEnd
	}
	frameEnd := bodyStart + parsedLen
	if len(raw) < frameEnd {
		return 0
	}
	out.payload = raw[bodyStart:frameEnd]
	return frameEnd
}

func scanChunkedStream(raw []byte, cursor int) int {
	bodyTotal := 0
	for {
		if cursor > len(raw) {
			return 0
		}
		nl := bytes.Index(raw[cursor:], []byte("\r\n"))
		if nl < 0 {
			if len(raw)-cursor > 1024 {
				return -400
			}
			return 0
		}
		sizeSpec := raw[cursor : cursor+nl]
		if len(sizeSpec) > 1024 {
			return -400
		}
		if semi := bytes.IndexByte(sizeSpec, ';'); semi >= 0 {
			for _, ch := range sizeSpec[semi+1:] {
				if ch-0x20 >= 0x5f && ch != '\t' && ch < 0x80 {
					return -400
				}
			}
			sizeSpec = sizeSpec[:semi]
		}
		if len(sizeSpec) == 0 || len(sizeSpec) > 8 {
			return -400
		}
		chunkBytes := 0
		for _, ch := range sizeSpec {
			nib := decodeHexNibble(ch)
			if nib < 0 {
				return -400
			}
			chunkBytes = (chunkBytes << 4) | nib
			if chunkBytes > limitBodyBytes {
				return -413
			}
		}
		cursor += nl + 2
		if chunkBytes == 0 {
			trailerOrigin := cursor
			for {
				tnl := bytes.Index(raw[cursor:], []byte("\r\n"))
				if tnl < 0 {
					if len(raw)-trailerOrigin > limitHeaderBytes {
						return -400
					}
					return 0
				}
				if cursor-trailerOrigin+tnl > limitHeaderBytes {
					return -400
				}
				if tnl == 0 {
					return cursor + 2
				}
				tLine := raw[cursor : cursor+tnl]
				cPos := bytes.IndexByte(tLine, ':')
				if cPos <= 0 {
					return -400
				}
				tName := tLine[:cPos]
				for _, ch := range tName {
					if !validTChar(ch) {
						return -400
					}
				}
				for _, ch := range tLine[cPos+1:] {
					if ch-0x20 >= 0x5f && ch != '\t' && ch < 0x80 {
						return -400
					}
				}
				switch len(tName) {
				case 4:
					if matchHeaderKey(tName, "host") {
						return -400
					}
				case 13:
					if matchHeaderKey(tName, "authorization") {
						return -400
					}
				case 14:
					if matchHeaderKey(tName, "content-length") {
						return -400
					}
				case 17:
					if matchHeaderKey(tName, "transfer-encoding") {
						return -400
					}
				}
				cursor += tnl + 2
			}
		}
		bodyTotal += chunkBytes
		if bodyTotal > limitBodyBytes {
			return -413
		}
		if cursor+chunkBytes+2 > len(raw) {
			return 0
		}
		if raw[cursor+chunkBytes] != '\r' || raw[cursor+chunkBytes+1] != '\n' {
			return -400
		}
		cursor += chunkBytes + 2
	}
}

func unpackChunkedBody(buf []byte) []byte {
	srcPos, dstPos := 0, 0
	for {
		nl := bytes.Index(buf[srcPos:], []byte("\r\n"))
		sizeSpec := buf[srcPos : srcPos+nl]
		if semi := bytes.IndexByte(sizeSpec, ';'); semi >= 0 {
			sizeSpec = sizeSpec[:semi]
		}
		chunkBytes := 0
		for _, ch := range sizeSpec {
			chunkBytes = (chunkBytes << 4) | decodeHexNibble(ch)
		}
		if chunkBytes == 0 {
			return buf[:dstPos]
		}
		srcPos += nl + 2
		copy(buf[dstPos:], buf[srcPos:srcPos+chunkBytes])
		dstPos += chunkBytes
		srcPos += chunkBytes + 2
	}
}

type clockStamp struct {
	unixSec   int64
	formatted [29]byte
}

var cachedClock atomic.Pointer[clockStamp]

func init() {
	refreshClockHeader()
}

func refreshClockHeader() {
	now := time.Now()
	sec := now.Unix()
	if cur := cachedClock.Load(); cur != nil && cur.unixSec == sec {
		return
	}
	next := &clockStamp{unixSec: sec}
	now.UTC().AppendFormat(next.formatted[:0], http.TimeFormat)
	cachedClock.Store(next)
}

func writeDateValue(dst []byte) []byte {
	if cur := cachedClock.Load(); cur != nil {
		return append(dst, cur.formatted[:]...)
	}
	refreshClockHeader()
	return append(dst, cachedClock.Load().formatted[:]...)
}

func writeHTTPHeader(dst []byte, rep *httpReply, closeAfter, http10 bool) []byte {
	if rep.code == 0 {
		rep.code = 200
	}
	if !http10 && !closeAfter {
		if rep.code == 204 {
			rep.payload = nil
			dst = append(dst, "HTTP/1.1 204 No Content\r\nContent-Type: application/json\r\nDate: "...)
			dst = writeDateValue(dst)
			return append(dst, "\r\n\r\n"...)
		}
		var statusHead string
		switch rep.code {
		case 200:
			statusHead = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
		case 201:
			statusHead = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: "
		case 401:
			statusHead = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "
		case 403:
			statusHead = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: "
		case 404:
			statusHead = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: "
		case 422:
			statusHead = "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: "
		}
		if statusHead != "" {
			dst = append(dst, statusHead...)
			dst = strconv.AppendInt(dst, int64(len(rep.payload)), 10)
			dst = append(dst, "\r\nDate: "...)
			dst = writeDateValue(dst)
			return append(dst, "\r\n\r\n"...)
		}
	}

	phrase := http.StatusText(rep.code)
	if phrase == "" {
		rep.code = 500
		phrase = "Internal Server Error"
	}
	if http10 {
		dst = append(dst, "HTTP/1.0 "...)
	} else {
		dst = append(dst, "HTTP/1.1 "...)
	}
	dst = strconv.AppendInt(dst, int64(rep.code), 10)
	dst = append(dst, ' ')
	dst = append(dst, phrase...)
	dst = append(dst, "\r\nContent-Type: application/json"...)
	if rep.code == 204 || rep.code == 304 {
		rep.payload = nil
	} else {
		dst = append(dst, "\r\nContent-Length: "...)
		dst = strconv.AppendInt(dst, int64(len(rep.payload)), 10)
	}
	dst = append(dst, "\r\nDate: "...)
	dst = writeDateValue(dst)
	if closeAfter {
		dst = append(dst, "\r\nConnection: close"...)
	} else if http10 {
		dst = append(dst, "\r\nConnection: keep-alive"...)
	}
	return append(dst, "\r\n\r\n"...)
}
