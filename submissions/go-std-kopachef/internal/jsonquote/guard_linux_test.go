//go:build linux && amd64 && !purego

package jsonquote

import (
	"bytes"
	"encoding/json/jsontext"
	"os"
	"syscall"
	"testing"
	"unsafe"
)

// Guard both sides of the readable page. Race/checkptr instrumentation cannot
// detect an out-of-range assembly load, so exercise actual inaccessible pages.
func TestJSONVectorGuardPages(t *testing.T) {
	page := os.Getpagesize()
	area, err := syscall.Mmap(-1, 0, 3*page, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Munmap(area)
	for _, guard := range [][]byte{area[:page], area[2*page:]} {
		if err := syscall.Mprotect(guard, syscall.PROT_NONE); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range []int{0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, page} {
		for _, start := range []int{page, 2*page - n} {
			data := area[start : start+n]
			for i := range data {
				data[i] = 'A'
			}
			for _, pos := range []int{-1, 0, n / 2, n - 1} {
				if pos >= 0 && pos < n {
					data[pos] = '\n'
				}
				// The mapping remains alive and unchanged throughout each call.
				value := unsafe.String((*byte)(unsafe.Pointer(&area[start])), n)
				if got, want := firstJSONSpecial(value), firstJSONSpecialScalar(value); got != want {
					t.Fatalf("length=%d start=%d special=%d index=%d want=%d", n, start, pos, got, want)
				}
				want, _ := jsontext.AppendQuote(nil, value)
				if got := Append(nil, value); !bytes.Equal(got, want) {
					t.Fatal("guarded quoting differs", n, start, pos)
				}
				if pos >= 0 && pos < n {
					data[pos] = 'A'
				}
			}
		}
	}
}
