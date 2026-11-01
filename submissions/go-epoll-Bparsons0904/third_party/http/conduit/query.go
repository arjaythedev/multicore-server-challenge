package conduit

import "bytes"

// Query parameters, by index in queryValues.
const (
	qLimit = iota
	qOffset
	qTag
	qAuthor
	qFavorited
	nQuery
)

var queryNames = [nQuery]string{"limit", "offset", "tag", "author", "favorited"}

// maxParams is net/url's limit: a query with more parameters parses as empty.
const maxParams = 10000

// queryValues holds the first value of each parameter the API reads, still
// escaped, as url.ParseQuery and Values.Get see them: pairs are split on '&';
// a pair with a ';' or an invalid escape in its name or value is dropped; a
// name without '=' has the empty value.
type queryValues struct {
	vals [nQuery][]byte
	has  [nQuery]bool
}

func (q *queryValues) parse(query []byte) {
	if len(query) >= maxParams && bytes.Count(query, []byte("&"))+1 > maxParams {
		return
	}
	for len(query) > 0 {
		pair := query
		if i := bytes.IndexByte(query, '&'); i >= 0 {
			pair, query = query[:i], query[i+1:]
		} else {
			query = nil
		}
		if len(pair) == 0 || bytes.IndexByte(pair, ';') >= 0 {
			continue
		}
		key, val := pair, pair[len(pair):]
		if i := bytes.IndexByte(pair, '='); i >= 0 {
			key, val = pair[:i], pair[i+1:]
		}
		if !escapesOK(key) || !escapesOK(val) {
			continue
		}
		if k := queryKey(key); k >= 0 && !q.has[k] {
			q.vals[k], q.has[k] = val, true
		}
	}
}

// queryKey returns the index of the parameter that the escaped name key
// names, or -1.
func queryKey(key []byte) int {
	if len(key) > 3*len("favorited") {
		return -1
	}
	var buf [3 * len("favorited")]byte
	name := queryDecode(buf[:0], key)
	for i, n := range queryNames {
		if string(name) == n {
			return i
		}
	}
	return -1
}

// queryDecode appends the query component s (valid escapes) decoded, '+' as a
// space.
func queryDecode(dst, s []byte) []byte {
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '%':
			dst = append(dst, unhex(s[i+1])<<4|unhex(s[i+2]))
			i += 2
		case '+':
			dst = append(dst, ' ')
		default:
			dst = append(dst, c)
		}
	}
	return dst
}

func queryDecodedLen(s []byte) int { return len(s) - 2*bytes.Count(s, []byte("%")) }
