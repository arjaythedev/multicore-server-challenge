package server

import (
	"bytes"
	"encoding/json"
	"encoding/json/jsontext"
	"io"
)

var requestDecoding = envOr("JSON_DECODING", "stream")

// Read the wrapper and its fields in one token stream. Field bytes reference
// the original request body, whose lifetime is owned by the returned map; they
// never reference the decoder's temporary storage. String values are decoded
// only when a handler uses them. Duplicate names retain the last value, matching
// the compatibility decoder; names remain case-sensitive.
func decodeRequestFields(body []byte, wrapper string) (map[string]json.RawMessage, error) {
	d := jsontext.NewDecoder(bytes.NewReader(body), jsontext.AllowDuplicateNames(true), jsontext.AllowInvalidUTF8(true))
	token, err := d.ReadToken()
	if err != nil || token.Kind() != '{' {
		return nil, errBadBody
	}
	var fields map[string]json.RawMessage
	for d.PeekKind() != '}' {
		name, err := d.ReadToken()
		if err != nil {
			return nil, errBadBody
		}
		key := name.String() // Tokens expire on the next decoder operation.
		if key != wrapper || d.PeekKind() != '{' {
			if _, err := d.ReadValue(); err != nil {
				return nil, errBadBody
			}
			if key == wrapper {
				fields = nil
			}
			continue
		}
		if _, err := d.ReadToken(); err != nil {
			return nil, errBadBody
		}
		fields = make(map[string]json.RawMessage)
		for d.PeekKind() != '}' {
			name, err := d.ReadToken()
			if err != nil {
				return nil, errBadBody
			}
			key := name.String()
			raw, err := d.ReadValue()
			if err != nil {
				return nil, errBadBody
			}
			end := int(d.InputOffset())
			fields[key] = body[end-len(raw) : end]
		}
		if _, err := d.ReadToken(); err != nil {
			return nil, errBadBody
		}
	}
	if _, err := d.ReadToken(); err != nil {
		return nil, errBadBody
	}
	if _, err := d.ReadToken(); err != io.EOF || fields == nil {
		return nil, errBadBody
	}
	return fields, nil
}
