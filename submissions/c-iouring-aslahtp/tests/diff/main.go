// diffcheck sends the same requests to two Conduit servers and compares the answers: status codes, and the JSON
// bodies as parsed values (field order and number formatting don't matter; error messages are free text, so only
// the error shape is compared).
//
// Reads (-n) run at high concurrency (-c) against both servers on one database, so batching and pipelining are
// exercised with mixed traffic. Writes (-writes) are scripted scenarios that need each server on its own copy of
// the same database: the same steps on identical copies must give the same ids, slugs and bodies (timestamps and
// tokens are normalized).
//
//	go run . -a http://127.0.0.1:3001 -b http://127.0.0.1:3002 -secret multicore-server-challenge -n 20000 -c 256
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	baseA   = flag.String("a", "http://127.0.0.1:3001", "first server (the reference)")
	baseB   = flag.String("b", "http://127.0.0.1:3002", "second server (under test)")
	secret  = flag.String("secret", "multicore-server-challenge", "JWT secret both servers use")
	nReads  = flag.Int("n", 20000, "random read requests")
	conc    = flag.Int("c", 256, "concurrent read requests")
	nWrites = flag.Int("writes", 0, "write scenarios (each server must use its own copy of the database)")
	seed    = flag.Uint64("seed", 1, "random seed")
	users   = flag.Int64("users", 100000, "user ids 1..users exist")
	runID   = flag.String("run", strconv.FormatInt(time.Now().Unix(), 36), "suffix for names created by writes")
	maxShow = flag.Int("show", 10, "differences to print in full")
)

var client = &http.Client{
	Timeout:   30 * time.Second,
	Transport: &http.Transport{MaxIdleConnsPerHost: 4096, MaxConnsPerHost: 0, DisableCompression: true},
}

type request struct {
	method, path, token, body string
}

type response struct {
	status int
	body   []byte
	err    error
}

func do(base string, r request) response {
	var rd io.Reader
	if r.body != "" {
		rd = strings.NewReader(r.body)
	}
	req, err := http.NewRequest(r.method, base+r.path, rd)
	if err != nil {
		return response{err: err}
	}
	if r.body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if r.token != "" {
		req.Header.Set("Authorization", "Token "+r.token)
	}
	resp, err := client.Do(req)
	if err != nil {
		return response{err: err}
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return response{status: resp.StatusCode, body: b, err: err}
}

func mint(id int64) string {
	enc := base64.RawURLEncoding
	now := time.Now().Unix()
	h := enc.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	p := enc.EncodeToString([]byte(fmt.Sprintf(`{"sub":"%d","iat":%d,"exp":%d}`, id, now, now+3600)))
	m := hmac.New(sha256.New, []byte(*secret))
	m.Write([]byte(h + "." + p))
	return h + "." + p + "." + enc.EncodeToString(m.Sum(nil))
}

// normalize parses a body and replaces values that legitimately differ between servers or runs.
func normalize(b []byte) (any, error) {
	if len(b) == 0 {
		return nil, nil
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	return scrub(v), nil
}

func scrub(v any) any {
	switch x := v.(type) {
	case map[string]any:
		if e, ok := x["errors"].(map[string]any); ok && len(x) == 1 {
			if body, ok := e["body"].([]any); ok && len(body) == 1 {
				if _, ok := body[0].(string); ok {
					return "<error>"
				}
			}
		}
		for k, val := range x {
			switch k {
			case "token":
				if s, ok := val.(string); ok && s != "" {
					x[k] = "<token>"
					continue
				}
			case "createdAt", "updatedAt":
				if *nWrites > 0 {
					x[k] = "<time>"
					continue
				}
			}
			x[k] = scrub(val)
		}
		return x
	case []any:
		for i := range x {
			x[i] = scrub(x[i])
		}
		return x
	}
	return v
}

type differ struct {
	mu    sync.Mutex
	diffs int
	shown int
}

func (d *differ) compare(r request, a, b response) bool {
	why := ""
	if a.err != nil || b.err != nil {
		why = fmt.Sprintf("transport: a=%v b=%v", a.err, b.err)
	} else if a.status != b.status {
		why = fmt.Sprintf("status %d vs %d", a.status, b.status)
	} else {
		va, ea := normalize(a.body)
		vb, eb := normalize(b.body)
		if ea != nil || eb != nil {
			why = fmt.Sprintf("json: a=%v b=%v", ea, eb)
		} else if !reflect.DeepEqual(va, vb) {
			why = "body differs"
		}
	}
	if why == "" {
		return true
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.diffs++
	if d.shown < *maxShow {
		d.shown++
		fmt.Printf("DIFF %s %s (token=%v body=%q): %s\n  a: %s\n  b: %s\n", r.method, r.path, r.token != "", r.body,
			why, clip(a.body), clip(b.body))
	}
	return false
}

func clip(b []byte) string {
	if len(b) > 600 {
		return string(b[:600]) + "..."
	}
	return string(b)
}

// ---- discovery: names that exist, so reads hit real rows ----

type corpus struct {
	tags, slugs, authors []string
}

func discover() corpus {
	var c corpus
	get := func(path string, v any) {
		r := do(*baseA, request{method: "GET", path: path})
		if r.err != nil || r.status != 200 {
			fmt.Fprintf(os.Stderr, "discover %s: %v %d\n", path, r.err, r.status)
			os.Exit(2)
		}
		json.Unmarshal(r.body, v)
	}
	var tags struct{ Tags []string }
	get("/api/tags", &tags)
	c.tags = tags.Tags
	seen := map[string]bool{}
	addList := func(path string) {
		var l struct {
			Articles []struct {
				Slug   string
				Author struct{ Username string }
			}
		}
		get(path, &l)
		for _, a := range l.Articles {
			c.slugs = append(c.slugs, a.Slug)
			if !seen[a.Author.Username] {
				seen[a.Author.Username] = true
				c.authors = append(c.authors, a.Author.Username)
			}
		}
	}
	for off := 0; off < 1000; off += 100 {
		addList(fmt.Sprintf("/api/articles?limit=100&offset=%d", off))
	}
	for i := 0; i < len(c.tags) && i < 20; i++ {
		addList("/api/articles?limit=50&tag=" + url.QueryEscape(c.tags[i]))
	}
	sort.Strings(c.authors)
	return c
}

// ---- random reads ----

func pick[T any](rng *rand.Rand, xs []T) T { return xs[rng.IntN(len(xs))] }

func limitOffset(rng *rand.Rand) string {
	var q []string
	switch rng.IntN(8) {
	case 0:
	case 1:
		q = append(q, "limit=5")
	case 2:
		q = append(q, "limit=100")
	case 3:
		q = append(q, "limit="+pick(rng, []string{"0", "101", "-1", "abc", "", "1.5", "+5", "05", "%205"}))
	default:
		q = append(q, "limit=10")
	}
	switch rng.IntN(8) {
	case 0, 1, 2:
	case 3:
		q = append(q, "offset="+pick(rng, []string{"-1", "x", "", "99999999999999999999", "05"}))
	case 4:
		q = append(q, "offset="+strconv.Itoa(990+rng.IntN(20)))
	default:
		q = append(q, "offset="+strconv.Itoa(10*rng.IntN(5)))
	}
	return strings.Join(q, "&")
}

func randomRead(rng *rand.Rand, c corpus) request {
	r := request{method: "GET"}
	if rng.IntN(3) > 0 {
		r.token = mint(1 + rng.Int64N(*users))
	}
	lo := limitOffset(rng)
	join := func(parts ...string) string {
		var nonEmpty []string
		for _, p := range parts {
			if p != "" {
				nonEmpty = append(nonEmpty, p)
			}
		}
		if len(nonEmpty) == 0 {
			return ""
		}
		return "?" + strings.Join(nonEmpty, "&")
	}
	switch n := rng.IntN(100); {
	case n < 18:
		r.path = "/api/articles" + join(lo)
	case n < 26:
		r.path = "/api/articles" + join("tag="+url.QueryEscape(pick(rng, c.tags)), lo)
	case n < 33:
		r.path = "/api/articles" + join("author="+url.QueryEscape(pick(rng, c.authors)), lo)
	case n < 38:
		r.path = "/api/articles" + join("favorited="+url.QueryEscape(pick(rng, c.authors)), lo)
	case n < 40:
		r.path = "/api/articles" + join("tag=", "author="+url.QueryEscape(pick(rng, c.authors)), "tag=nope", lo)
	case n < 42:
		r.path = "/api/articles" + join("tag=no-such-tag-zz", lo)
	case n < 55:
		if r.token == "" && rng.IntN(4) > 0 {
			r.token = mint(1 + rng.Int64N(*users))
		}
		r.path = "/api/articles/feed" + join(lo)
	case n < 70:
		r.path = "/api/articles/" + url.PathEscape(pick(rng, c.slugs))
	case n < 72:
		r.path = "/api/articles/no-such-article-" + strconv.Itoa(rng.IntN(1000))
	case n < 85:
		r.path = "/api/articles/" + url.PathEscape(pick(rng, c.slugs)) + "/comments"
	case n < 92:
		r.path = "/api/profiles/" + url.PathEscape(pick(rng, c.authors))
	case n < 93:
		r.path = "/api/profiles/nobody-" + strconv.Itoa(rng.IntN(1000))
	case n < 96:
		r.path = "/api/tags"
	case n < 98:
		r.path = "/api/user"
	default:
		r.path = pick(rng, []string{"/api/articles/", "/api/nope", "/api/user/", "/api/articles?tag=" + url.QueryEscape(pick(rng, c.tags)) + "&limit=0"})
		if rng.IntN(2) == 0 {
			r.token = "garbage." + r.token
		}
	}
	return r
}

func runReads(c corpus, d *differ) {
	var next atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < *conc; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for {
				i := next.Add(1) - 1
				if i >= int64(*nReads) {
					return
				}
				rng := rand.New(rand.NewPCG(*seed, uint64(i)))
				r := randomRead(rng, c)
				var a, b response
				var inner sync.WaitGroup
				inner.Add(2)
				go func() { defer inner.Done(); a = do(*baseA, r) }()
				go func() { defer inner.Done(); b = do(*baseB, r) }()
				inner.Wait()
				d.compare(r, a, b)
			}
		}(w)
	}
	wg.Wait()
	fmt.Printf("reads: %d requests, %d differences (%.1fs)\n", *nReads, d.diffs, time.Since(start).Seconds())
}

// ---- scripted writes ----

// step runs one request on both servers; tokA/tokB are each server's own token for the acting user.
type session struct {
	d          *differ
	tokA, tokB string
	failed     bool
}

func (s *session) step(method, path, body string, auth bool) (response, response) {
	ra, rb := request{method: method, path: path, body: body}, request{method: method, path: path, body: body}
	if auth {
		ra.token, rb.token = s.tokA, s.tokB
	}
	a, b := do(*baseA, ra), do(*baseB, rb)
	if !s.d.compare(ra, a, b) {
		s.failed = true
	}
	return a, b
}

func field(body []byte, path ...string) string {
	var v any
	json.Unmarshal(body, &v)
	for _, p := range path {
		m, _ := v.(map[string]any)
		v = m[p]
	}
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatInt(int64(x), 10)
	}
	return ""
}

func writeScenario(i int, c corpus, d *differ) {
	rng := rand.New(rand.NewPCG(*seed, uint64(1_000_000+i)))
	s := &session{d: d}
	name := fmt.Sprintf("diff_%s_%d", *runID, i)
	reg := fmt.Sprintf(`{"user":{"username":%q,"email":%q,"password":"pw-%d"}}`, name, name+"@example.com", i)
	a, b := s.step("POST", "/api/users", reg, false)
	s.tokA, s.tokB = field(a.body, "user", "token"), field(b.body, "user", "token")
	if s.tokA == "" || s.tokB == "" {
		return
	}
	s.step("POST", "/api/users", reg, false) // duplicate: 422 on both
	s.step("POST", "/api/users/login", fmt.Sprintf(`{"user":{"email":%q,"password":"pw-%d"}}`, name+"@example.com", i), false)
	s.step("POST", "/api/users/login", fmt.Sprintf(`{"user":{"email":%q,"password":"nope"}}`, name+"@example.com"), false)
	s.step("PUT", "/api/user", `{"user":{"bio":"bio é \"quoted\"","image":null}}`, true)
	s.step("GET", "/api/user", "", true)

	tags := []string{pick(rng, c.tags), "new-tag-" + *runID, pick(rng, c.tags)}
	tagJSON, _ := json.Marshal(tags)
	art := fmt.Sprintf(`{"article":{"title":"Diff %s #%d: Héllo, World!","description":"d","body":"b\nline","tagList":%s}}`,
		*runID, i, tagJSON)
	a, _ = s.step("POST", "/api/articles", art, true)
	slug := field(a.body, "article", "slug")
	if slug == "" {
		return
	}
	s.step("POST", "/api/articles", `{"article":{"title":"No tags","description":"d","body":"b"}}`, true)
	s.step("GET", "/api/articles/"+slug, "", true)
	s.step("PUT", "/api/articles/"+slug, `{"article":{"body":"new body"}}`, true)
	a, _ = s.step("PUT", "/api/articles/"+slug, `{"article":{"title":"Renamed -- twice!"}}`, true)
	newSlug := field(a.body, "article", "slug")
	s.step("GET", "/api/articles/"+slug, "", false) // old slug: 404
	slug = newSlug
	s.step("POST", "/api/articles/"+slug+"/favorite", "", true)
	s.step("POST", "/api/articles/"+slug+"/favorite", "", true)
	other := pick(rng, c.slugs)
	s.step("POST", "/api/articles/"+other+"/favorite", "", true)
	s.step("DELETE", "/api/articles/"+other+"/favorite", "", true)
	s.step("DELETE", "/api/articles/"+other, "", true) // not the author: 403
	a, _ = s.step("POST", "/api/articles/"+slug+"/comments", `{"comment":{"body":"first!"}}`, true)
	cid := field(a.body, "comment", "id")
	s.step("POST", "/api/articles/"+slug+"/comments", `{"comment":{"body":""}}`, true)
	s.step("GET", "/api/articles/"+slug+"/comments", "", true)
	s.step("DELETE", "/api/articles/"+slug+"/comments/"+cid, "", true)
	s.step("DELETE", "/api/articles/"+slug+"/comments/"+cid, "", true) // gone: 404
	author := pick(rng, c.authors)
	s.step("POST", "/api/profiles/"+url.PathEscape(author)+"/follow", "", true)
	s.step("GET", "/api/articles/feed?limit=5", "", true)
	s.step("DELETE", "/api/profiles/"+url.PathEscape(author)+"/follow", "", true)
	s.step("GET", "/api/articles?author="+url.QueryEscape(name), "", true)
	s.step("GET", "/api/articles?favorited="+url.QueryEscape(name), "", true)
	s.step("DELETE", "/api/articles/"+slug, "", true)
	s.step("GET", "/api/articles/"+slug, "", true)
	s.step("PUT", "/api/user", fmt.Sprintf(`{"user":{"password":"pw2-%d","email":%q}}`, i, name+"2@example.com"), true)
	s.step("POST", "/api/users/login", fmt.Sprintf(`{"user":{"email":%q,"password":"pw2-%d"}}`, name+"2@example.com", i), false)
}

func main() {
	flag.Parse()
	d := &differ{}
	c := discover()
	fmt.Printf("corpus: %d tags, %d slugs, %d authors\n", len(c.tags), len(c.slugs), len(c.authors))
	if *nReads > 0 {
		runReads(c, d)
	}
	if *nWrites > 0 {
		before := d.diffs
		for i := 0; i < *nWrites; i++ {
			writeScenario(i, c, d)
		}
		fmt.Printf("writes: %d scenarios, %d differences\n", *nWrites, d.diffs-before)
	}
	if d.diffs > 0 {
		os.Exit(1)
	}
}
