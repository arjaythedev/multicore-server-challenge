package server

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestPasswordBatchWidths(t *testing.T) {
	var jobs [maxPasswordBatchSize]*passwordJob
	var want [maxPasswordBatchSize][23]byte
	for i, password := range []string{"", "a\x00\xffb", "password123", strings.Repeat("a", 72), "fifth password"} {
		encoded, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
		if err != nil {
			t.Fatal(err)
		}
		salt, checksum, ok := parsePasswordHash(string(encoded))
		if !ok {
			t.Fatal("standard cost-10 hash was not recognized")
		}
		want[i] = checksum
		jobs[i] = &passwordJob{ctx: context.Background(), password: []byte(password), salt: salt}
	}
	for width := 1; width <= maxPasswordBatchSize; width++ {
		for _, job := range jobs[:width] {
			job.done = make(chan struct{})
		}
		new(passwordQueue).execute(jobs[:width])
		for i, job := range jobs[:width] {
			<-job.done
			if job.result != want[i] {
				t.Fatalf("width %d lane %d checksum mismatch", width, i)
			}
		}
	}
}

func TestPasswordQueueIdleAndShutdown(t *testing.T) {
	q := newPasswordQueue(1, time.Hour)
	finished := make(chan error, 1)
	go func() {
		_, err := q.sum(context.Background(), "password123", [16]byte{})
		finished <- err
	}()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		q.close()
		t.Fatal("idle hash waited for a batch")
	}
	q.close()
	if _, err := q.sum(context.Background(), "password", [16]byte{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("closed queue returned %v", err)
	}
}

func TestPasswordQueueConcurrent(t *testing.T) {
	q := newPasswordQueueConfig(2, 2*time.Millisecond, maxPasswordBatchSize)
	defer q.close()
	a := &app{passwords: q}
	hash, err := a.hashPassword(context.Background(), "correct")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			switch i % 3 {
			case 0:
				if err := a.checkPassword(context.Background(), hash, "correct"); err != nil {
					t.Error(err)
				}
			case 1:
				if err := a.checkPassword(context.Background(), hash, "incorrect"); !errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
					t.Errorf("wrong password returned %v", err)
				}
			case 2:
				generated, err := a.hashPassword(context.Background(), "new password")
				if err != nil {
					t.Error(err)
					return
				}
				if err := bcrypt.CompareHashAndPassword([]byte(generated), []byte("new password")); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := q.sum(ctx, "canceled", [16]byte{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled request returned %v", err)
	}
}

func TestPasswordCompatibility(t *testing.T) {
	q := newPasswordQueue(2, time.Millisecond)
	defer q.close()
	a := &app{passwords: q}
	var canonical string
	for _, cost := range []int{4, 10} {
		encoded, err := bcrypt.GenerateFromPassword([]byte("password"), cost)
		if err != nil {
			t.Fatal(err)
		}
		if cost == 10 {
			canonical = string(encoded)
		}
		for _, version := range []string{"$2a$", "$2b$", "$2y$", "$2$"} {
			hash := version + string(encoded[4:])
			for _, password := range []string{"password", "wrong"} {
				want := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
				got := a.checkPassword(context.Background(), hash, password)
				if (got == nil) != (want == nil) {
					t.Fatalf("cost %d version %s: got %v, want %v", cost, version, got, want)
				}
			}
		}
	}
	const alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	for _, index := range []int{28, 59} {
		changed := []byte(canonical)
		changed[index] = alphabet[strings.IndexByte(alphabet, changed[index])+1]
		if _, _, ok := parsePasswordHash(string(changed)); ok {
			t.Fatal("noncanonical padding accepted by fast path")
		}
		want := bcrypt.CompareHashAndPassword(changed, []byte("password"))
		if got := a.checkPassword(context.Background(), string(changed), "password"); (got == nil) != (want == nil) {
			t.Fatalf("padding compatibility at %d: got %v, want %v", index, got, want)
		}
	}
	if _, err := a.hashPassword(context.Background(), strings.Repeat("x", 73)); !errors.Is(err, bcrypt.ErrPasswordTooLong) {
		t.Fatalf("long password returned %v", err)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(strings.Repeat("x", 72)), 10)
	if err != nil {
		t.Fatal(err)
	}
	long := strings.Repeat("x", 73)
	want := bcrypt.CompareHashAndPassword(hash, []byte(long))
	if got := a.checkPassword(context.Background(), string(hash), long); (got == nil) != (want == nil) {
		t.Fatalf("long-password compatibility: got %v, want %v", got, want)
	}
	for _, invalid := range []string{"", "$2a$10$", strings.Repeat("a", 60), "$2a$10$" + strings.Repeat("!", 53), "$2a$32$" + strings.Repeat("a", 53)} {
		if err := a.checkPassword(context.Background(), invalid, "password"); err == nil {
			t.Fatalf("invalid hash accepted: %q", invalid)
		}
	}
}

func TestPasswordQueueBackpressureCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := &passwordQueue{ctx: ctx, cancel: cancel, pending: make(chan *passwordJob, 1)}
	q.pending <- &passwordJob{} // No consumer: the next enqueue must wait.
	finished := make(chan error, 1)
	go func() {
		_, err := q.sum(context.Background(), "password", [16]byte{})
		finished <- err
	}()
	q.close()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("blocked enqueue returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown left a caller blocked on enqueue")
	}
}
