package bcryptx

import (
	"bytes"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestNativeBatchAgainstReference(t *testing.T) {
	if !nativeCompiled {
		t.Skip("cgo is disabled")
	}
	passwords := [][]byte{[]byte("a"), []byte("password123"), bytes.Repeat([]byte("x"), 72), []byte("mixed-ASCII-123")}
	var worker Worker
	requests := make([]*Request, len(passwords))
	for i, password := range passwords {
		hash, err := bcrypt.GenerateFromPassword(password, 5)
		if err != nil {
			t.Fatal(err)
		}
		requests[i] = &Request{Password: password, Hash: hash}
	}
	worker.Process(requests)
	if worker.NativeJobs != 4 || worker.FallbackJobs != 0 {
		t.Fatalf("ASCII verification did not use native path: native=%d fallback=%d", worker.NativeJobs, worker.FallbackJobs)
	}
	for i, r := range requests {
		if !r.OK {
			t.Fatalf("native batch failed to verify lane %d", i)
		}
		r.Password = []byte("incorrect")
	}
	worker.Process(requests)
	if worker.NativeJobs != 8 || worker.FallbackJobs != 0 {
		t.Fatalf("ASCII wrong-password verification did not use native path: native=%d fallback=%d", worker.NativeJobs, worker.FallbackJobs)
	}
	for i, r := range requests {
		if r.OK {
			t.Fatalf("native batch accepted wrong password in lane %d", i)
		}
	}

	newPasswords := [][]byte{[]byte("new-a"), []byte("new-b"), []byte("new-c"), []byte("new-d")}
	newRequests := make([]*Request, len(newPasswords))
	for i, password := range newPasswords {
		newRequests[i] = &Request{Password: password, Cost: 10}
	}
	worker.Process(newRequests)
	if worker.NativeJobs != 12 || worker.FallbackJobs != 0 {
		t.Fatalf("ASCII new hashes did not use native path: native=%d fallback=%d", worker.NativeJobs, worker.FallbackJobs)
	}
	for i, r := range newRequests {
		if !r.OK || bcrypt.CompareHashAndPassword(r.Result[:], newPasswords[i]) != nil {
			t.Fatalf("native cost-10 hash failed reference check in lane %d", i)
		}
		if cost, err := bcrypt.Cost(r.Result[:]); err != nil || cost != 10 {
			t.Fatalf("native hash lane %d has cost %d, err %v", i, cost, err)
		}
	}
}
