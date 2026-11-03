package server

import (
	"errors"
	"io"
	"net/http"
)

var compactPrefixResponses = envOr("HTTP_RESPONSE_BUFFER", "vector") == "prefix"

const responseHeadReserve = 256

// The encoder owns buffer and appends its body after offset. Only the header
// is copied into that reserved prefix; the body stays at its original address.
// Shared batch bodies never enter this path.
func (w *compactResponse) writePrefixed(buffer []byte, offset int) (int, error) {
	if offset < 0 || offset > len(buffer) {
		w.err = errors.New("invalid response body offset")
		return 0, w.err
	}
	body := buffer[offset:]
	if err := w.prepare(body); err != nil {
		return 0, err
	}
	if len(w.wire) > offset {
		// Arbitrary large headers keep the existing general write path.
		return w.writeVector(body)
	}
	start, end := offset-len(w.wire), len(buffer)
	copy(buffer[start:offset], w.wire)
	if w.head || w.status == http.StatusNoContent || w.status == http.StatusNotModified {
		end = offset
	}
	n, err := w.connection.Write(buffer[start:end])
	if err == nil && n < end-start {
		err = io.ErrShortWrite
	}
	w.err = err
	if w.head && err == nil {
		return len(body), nil
	}
	return min(len(body), max(0, n-len(w.wire))), err
}
