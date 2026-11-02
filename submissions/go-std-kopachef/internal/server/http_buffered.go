package server

import (
	"bytes"
	"net/http"
	"net/url"
)

var compactHTTPHotPath = envOr("HTTP_HOT_PATH", "0") == "1"

var bufferedHeaderNames = [...]string{"Host", "Authorization", "User-Agent", "Accept", "Accept-Encoding", "Connection"}

// Keep the usual request, URL and four header-value slots in one allocation.
// This object belongs to this request and is never pooled or reused.
type bufferedRequest struct {
	request http.Request
	url     url.URL
	values  [4]string
}

// Parse only complete, ordinary bodyless GETs already in the connection's
// reader. A rejection consumes nothing; ReadRequest handles the general case.
// All retained substrings belong to a fresh owned copy of the header bytes.
type bufferedGETSpec struct {
	end, uriEnd, count int
	seen               uint8
	spans              [len(bufferedHeaderNames)][2]int
	closeConnection    bool
}

func bufferedGET(data []byte) (*http.Request, int) {
	spec, ok := parseBufferedGET(data)
	if !ok {
		return nil, 0
	}
	return spec.request(data), spec.end + 4
}

func parseBufferedGET(data []byte) (bufferedGETSpec, bool) {
	end := bytes.Index(data, []byte("\r\n\r\n"))
	if end < 0 {
		return bufferedGETSpec{}, false
	}
	line := bytes.Index(data[:end+2], []byte("\r\n"))
	const protocol = " HTTP/1.1"
	if line < 4+len(protocol)+1 || !bytes.HasPrefix(data, []byte("GET ")) ||
		!bytes.HasSuffix(data[:line], []byte(protocol)) {
		return bufferedGETSpec{}, false
	}
	uriEnd := line - len(protocol)
	uri := data[4:uriEnd]
	if len(uri) == 0 || uri[0] != '/' {
		return bufferedGETSpec{}, false
	}
	for _, c := range uri {
		if c < 0x21 || c >= 0x7f || c == '%' || c == '#' || c == '\\' {
			return bufferedGETSpec{}, false
		}
	}
	pathBytes := uri
	if q := bytes.IndexByte(uri, '?'); q >= 0 {
		pathBytes = uri[:q]
	}
	for _, c := range pathBytes {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '/' || c == '-' || c == '_' || c == '.' || c == '~') {
			return bufferedGETSpec{}, false
		}
	}
	var spans [len(bufferedHeaderNames)][2]int
	var seen uint8
	count := 0
	closeConnection := false
	for pos := line + 2; pos < end; {
		n := bytes.Index(data[pos:end+2], []byte("\r\n"))
		if n < 0 {
			return bufferedGETSpec{}, false
		}
		last := pos + n
		colon := bytes.IndexByte(data[pos:last], ':')
		if colon <= 0 {
			return bufferedGETSpec{}, false
		}
		key := data[pos : pos+colon]
		for _, c := range key {
			if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '-') {
				return bufferedGETSpec{}, false
			}
		}
		index := -1
		for i, name := range bufferedHeaderNames {
			if bytes.EqualFold(key, []byte(name)) {
				index = i
				break
			}
		}
		if index < 0 || seen&(1<<index) != 0 {
			return bufferedGETSpec{}, false
		}
		start := pos + colon + 1
		for start < last && (data[start] == ' ' || data[start] == '\t') {
			start++
		}
		valueEnd := last
		for valueEnd > start && (data[valueEnd-1] == ' ' || data[valueEnd-1] == '\t') {
			valueEnd--
		}
		for _, c := range data[start:valueEnd] {
			if (c < 0x20 && c != '\t') || c >= 0x7f {
				return bufferedGETSpec{}, false
			}
		}
		if index == 0 && start == valueEnd {
			return bufferedGETSpec{}, false
		}
		if index == 5 {
			switch {
			case bytes.EqualFold(data[start:valueEnd], []byte("close")):
				closeConnection = true
			case bytes.EqualFold(data[start:valueEnd], []byte("keep-alive")):
			default:
				return bufferedGETSpec{}, false
			}
		}
		seen |= 1 << index
		spans[index] = [2]int{start, valueEnd}
		if index != 0 {
			count++
		}
		pos = last + 2
	}
	if seen&1 == 0 {
		return bufferedGETSpec{}, false
	}
	return bufferedGETSpec{end: end, uriEnd: uriEnd, count: count, seen: seen, spans: spans, closeConnection: closeConnection}, true
}

func (spec bufferedGETSpec) request(data []byte) *http.Request {
	end, uriEnd, count, seen, spans := spec.end, spec.uriEnd, spec.count, spec.seen, spec.spans
	uri := data[4:uriEnd]
	owned := string(data[:end+4])
	envelope := new(bufferedRequest)
	headers := make(http.Header, count)
	values := envelope.values[:]
	if count > len(values) {
		values = make([]string, count)
	}
	n := 0
	for i, name := range bufferedHeaderNames {
		if i == 0 || seen&(1<<i) == 0 {
			continue
		}
		values[n] = owned[spans[i][0]:spans[i][1]]
		headers[name] = values[n : n+1 : n+1]
		n++
	}
	uriText := owned[4:uriEnd]
	path, query, forceQuery := uriText, "", false
	if i := bytes.IndexByte(uri, '?'); i >= 0 {
		path, query = uriText[:i], uriText[i+1:]
		forceQuery = i == len(uriText)-1
	}
	envelope.url = url.URL{Path: path, RawQuery: query, ForceQuery: forceQuery}
	envelope.request = http.Request{Method: http.MethodGet, URL: &envelope.url,
		Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1, Header: headers,
		Host: owned[spans[0][0]:spans[0][1]], RequestURI: uriText, Body: http.NoBody, Close: spec.closeConnection}
	return &envelope.request
}
