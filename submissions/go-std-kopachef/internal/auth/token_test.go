package auth

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

var benchmarkViewer int64

func TestTokenMAC(t *testing.T) {
	for _, keyLength := range []int{0, 1, 63, 64, 65, 256} {
		a := NewSigner(bytes.Repeat([]byte{0x9a}, keyLength))
		for repeat := 0; repeat < 3; repeat++ {
			for _, message := range [][]byte{nil, {}, []byte("a JWT message"), bytes.Repeat([]byte{0, 0xff, 0x80}, 1000)} {
				mac := hmac.New(sha256.New, a.secret)
				_, _ = mac.Write(message)
				got := a.tokenMAC(string(message))
				if !hmac.Equal(got[:], mac.Sum(nil)) {
					t.Fatalf("HMAC differs: key length %d", keyLength)
				}
			}
		}
	}
	apps := []*Signer{NewSigner([]byte("first-key")), NewSigner([]byte("second-key"))}
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a := apps[i%len(apps)]
			for j := 0; j < 32; j++ {
				message := []byte(fmt.Sprintf("message-%d-%d", i, j))
				mac := hmac.New(sha256.New, a.secret)
				_, _ = mac.Write(message)
				got := a.tokenMAC(string(message))
				if !hmac.Equal(got[:], mac.Sum(nil)) {
					t.Error("concurrent HMAC differs")
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestAuthHeaderForms(t *testing.T) {
	a := NewSigner([]byte("header-test-secret"))
	encode := func(header string, expires int64) string {
		payload := fmt.Sprintf(`{"sub":"12345","exp":%d}`, expires)
		message := base64.RawURLEncoding.EncodeToString([]byte(header)) + "." + base64.RawURLEncoding.EncodeToString([]byte(payload))
		mac := hmac.New(sha256.New, a.secret)
		_, _ = mac.Write([]byte(message))
		return message + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	}
	for _, tc := range []struct {
		header string
		valid  bool
	}{
		{`{"alg":"HS256","typ":"JWT"}`, true}, {`{"alg":"HS256"}`, true},
		{`{"typ":"JWT","alg":"HS256","extra":[1,2]}`, true},
		{`{"alg":"none","alg":"HS256"}`, true}, {`{"alg":"HS256","alg":"none"}`, false},
		{`{"alg":"HS512"}`, false}, {`{"alg":null}`, false}, {`{}`, false}, {`broken`, false},
	} {
		for _, expires := range []int64{time.Now().Unix() + 60, time.Now().Unix() - 60} {
			token := encode(tc.header, expires)
			r := &http.Request{Header: http.Header{}}
			r.Header.Set("Authorization", "Token "+token)
			id, _, present := a.AuthHeader(r.Header.Get("Authorization"))
			if !present || (id == 12345) != (tc.valid && expires > time.Now().Unix()) {
				t.Fatalf("header %s expiration %d: id %d", tc.header, expires, id)
			}
			// Recompute with the changed signing input; the old signature must fail.
			parts := strings.Split(token, ".")
			parts[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"54321","exp":9999999999}`))
			r.Header.Set("Authorization", "Token "+strings.Join(parts, "."))
			if id, _, _ := a.AuthHeader(r.Header.Get("Authorization")); id != 0 {
				t.Fatal("tampered claims accepted")
			}
		}
	}
}

func TestAuthMalformedSignature(t *testing.T) {
	a := NewSigner([]byte("test-secret"))
	token := a.IssueToken(12345)
	prefix := token[:strings.LastIndexByte(token, '.')+1]
	for _, size := range []int{0, 1, 42, 43, 44, 4096} {
		t.Run(strconv.Itoa(size), func(t *testing.T) {
			r := &http.Request{Header: http.Header{}}
			r.Header.Set("Authorization", "Token "+prefix+strings.Repeat("A", size))
			if id, _, present := a.AuthHeader(r.Header.Get("Authorization")); id != 0 || !present {
				t.Fatalf("malformed signature accepted: id=%d, present=%v", id, present)
			}
		})
	}
}

func BenchmarkAuth(b *testing.B) {
	a := NewSigner([]byte("benchmark-secret"))
	r := &http.Request{Header: http.Header{}}
	r.Header.Set("Authorization", "Token "+a.IssueToken(12345))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		id, _, _ := a.AuthHeader(r.Header.Get("Authorization"))
		benchmarkViewer = id
	}
}
