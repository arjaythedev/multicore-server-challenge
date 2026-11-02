// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Package bcryptlane computes independent bcrypt checksums. It does not parse
// hashes or compare passwords. The caller owns salts, cost and validation.
package bcryptlane

import "golang.org/x/crypto/blowfish"

//go:generate python3 generate.py
//go:generate gofmt -w lanes_generated.go
//go:generate python3 asm_generate.py

func standardSingle(password []byte, salt [16]byte, cost uint) (result [23]byte) {
	key := append(append([]byte(nil), password...), 0)
	c, err := blowfish.NewSaltedCipher(key, salt[:])
	if err != nil {
		panic(err)
	}
	for rounds := 0; rounds < 1<<cost; rounds++ {
		blowfish.ExpandKey(key, c)
		blowfish.ExpandKey(salt[:], c)
	}
	text := []byte("OrpheanBeholderScryDoubt")
	for i := 0; i < len(text); i += 8 {
		for range 64 {
			c.Encrypt(text[i:i+8], text[i:i+8])
		}
	}
	copy(result[:], text[:23])
	return
}
