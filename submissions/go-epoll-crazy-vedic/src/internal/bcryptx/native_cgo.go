//go:build cgo

package bcryptx

/*
#include "native.h"
*/
import "C"

import (
	"crypto/subtle"
	"runtime"
	"unsafe"
)

const nativeCompiled = true

// processNative uses the interleaved C++ implementation only when every lane
// has ordinary ASCII input. The Go implementation handles all other inputs.
func processNative(g []*Request) bool {
	if len(g) == 0 || len(g) > MaxLanes {
		return false
	}
	var passwords [MaxLanes * 73]byte
	var lengths [MaxLanes]int32
	var salts [MaxLanes * 16]byte
	var costs [MaxLanes]int32
	var hashes [MaxLanes * hashLen]byte
	for i, r := range g {
		// Worker.Process has already cleared r.fast when it takes ownership of
		// the request, so eligibility depends on the prepared input itself.
		if len(r.Password) > maxPassword {
			return false
		}
		for _, c := range r.Password {
			if c == 0 || c >= 0x80 {
				return false
			}
		}
		copy(passwords[i*73:], r.Password)
		lengths[i], costs[i] = int32(len(r.Password)), int32(r.cost)
		copy(salts[i*16:], r.salt[:])
	}
	if C.bcryptx_compute(
		(*C.uint8_t)(unsafe.Pointer(&passwords[0])),
		(*C.int32_t)(unsafe.Pointer(&lengths[0])),
		(*C.uint8_t)(unsafe.Pointer(&salts[0])),
		(*C.int32_t)(unsafe.Pointer(&costs[0])),
		(*C.uint8_t)(unsafe.Pointer(&hashes[0])), C.int(len(g))) != 0 {
		return false
	}
	for i, r := range g {
		got := hashes[i*hashLen : (i+1)*hashLen]
		if r.Hash != nil {
			r.OK = subtle.ConstantTimeCompare(got[29:], r.Hash[29:]) == 1
		} else {
			copy(r.Result[:], got)
			r.OK = true
		}
	}
	runtime.KeepAlive(&passwords)
	runtime.KeepAlive(&lengths)
	runtime.KeepAlive(&salts)
	runtime.KeepAlive(&costs)
	runtime.KeepAlive(&hashes)
	return true
}
