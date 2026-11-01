package http

import "strconv"

// hdrMax bounds a rendered response header: the longest status line, the
// content headers with a 10-digit length, and a Connection header.
const hdrMax = 192

var statusText = map[int]string{
	100: "Continue", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
	301: "Moved Permanently", 302: "Found", 304: "Not Modified",
	400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
	405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 411: "Length Required",
	413: "Content Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Content",
	429: "Too Many Requests", 431: "Request Header Fields Too Large",
	500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
	503: "Service Unavailable", 504: "Gateway Timeout",
}

// statusLines holds "HTTP/1.1 <code> <reason>\r\n" for every code from 100 to 599.
var statusLines [600][]byte

// errorResponses holds the complete closing responses the server sends by
// itself, by status.
var errorResponses = map[int][]byte{}

var continueResponse = []byte("HTTP/1.1 100 Continue\r\n\r\n")

func init() {
	for code := 100; code < len(statusLines); code++ {
		reason, ok := statusText[code]
		if !ok {
			reason = "Status " + strconv.Itoa(code)
		}
		statusLines[code] = []byte("HTTP/1.1 " + strconv.Itoa(code) + " " + reason + "\r\n")
	}
	for _, code := range []int{400, 411, 413, 431, 500, 503} {
		body := `{"errors":{"body":["` + statusText[code] + `"]}}`
		errorResponses[code] = append(appendHeader(nil, code, len(body), false, false), body...)
	}
}

// appendHeader renders a response header. bodyLen is the Content-Length; 1xx,
// 204 and 304 responses carry no content headers.
func appendHeader(dst []byte, status, bodyLen int, keepAlive, http10 bool) []byte {
	if status < 100 || status >= len(statusLines) {
		status = 500
	}
	dst = append(dst, statusLines[status]...)
	if hasBody(status) {
		dst = append(dst, "Content-Type: application/json\r\nContent-Length: "...)
		dst = strconv.AppendInt(dst, int64(bodyLen), 10)
		dst = append(dst, "\r\n"...)
	}
	if !keepAlive {
		dst = append(dst, "Connection: close\r\n"...)
	} else if http10 {
		dst = append(dst, "Connection: keep-alive\r\n"...)
	}
	return append(dst, "\r\n"...)
}

func hasBody(status int) bool { return status >= 200 && status != 204 && status != 304 }

// sendsBody reports whether a response's body bytes go on the wire.
func sendsBody(status int, head bool) bool { return !head && hasBody(status) }
