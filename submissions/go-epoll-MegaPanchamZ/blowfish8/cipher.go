package blowfish8

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"unsafe"

	xbcrypt "golang.org/x/crypto/bcrypt"
)

const (
	Lanes         = 8
	maxPassBytes  = 72
	encodedDigest = 60
)

type bfBox struct {
	p              [18]uint32
	s0, s1, s2, s3 [256]uint32
}

func (b *bfBox) words() *[521][2]uint32 {
	return (*[521][2]uint32)(unsafe.Pointer(b))
}

func laneWords(boxes *[Lanes]bfBox) *[Lanes][521][2]uint32 {
	return (*[Lanes][521][2]uint32)(unsafe.Pointer(boxes))
}

var (
	seedBox      = bfBox{p: piP, s0: piS0, s1: piS1, s2: piS2, s3: piS3}
	radix64      = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding)
	orpheanWords = [6]uint32{0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274}
)

type HashJob struct {
	Plain    []byte
	Existing []byte
	Cost     int
	Encoded  [encodedDigest]byte
	Matched  bool

	eligible bool
	workCost int
	rawSalt  [16]byte
	pwWords  [18]uint32
	sltWords [18]uint32
}

type Engine struct {
	boxes [Lanes]bfBox
}

func (e *Engine) Evaluate(jobs []HashJob) {
	for i := range jobs {
		jb := &jobs[i]
		jb.Matched = false
		if !jb.initSchedule() && jb.Existing != nil {
			jb.Matched = xbcrypt.CompareHashAndPassword(jb.Existing, jb.Plain) == nil
		}
	}
	var active [Lanes]*HashJob
	for {
		n := 0
		sharedCost := -1
		for i := range jobs {
			jb := &jobs[i]
			if !jb.eligible {
				continue
			}
			if sharedCost < 0 {
				sharedCost = jb.workCost
			}
			if jb.workCost == sharedCost {
				jb.eligible = false
				active[n] = jb
				n++
				if n == Lanes {
					break
				}
			}
		}
		if n == 0 {
			return
		}
		e.runInterleaved(active[:n])
	}
}

func (jb *HashJob) initSchedule() bool {
	jb.eligible = false
	if len(jb.Existing) == 0 {
		if len(jb.Plain) > maxPassBytes || jb.Cost < xbcrypt.MinCost || jb.Cost > xbcrypt.MaxCost {
			return false
		}
		if _, err := rand.Read(jb.rawSalt[:]); err != nil {
			return false
		}
		jb.workCost = jb.Cost
	} else {
		h := jb.Existing
		if len(h) != encodedDigest || h[0] != '$' || h[1] != '2' ||
			(h[2] != 'a' && h[2] != 'b' && h[2] != 'y') ||
			h[3] != '$' || h[6] != '$' {
			return false
		}
		d0, d1 := h[4]-'0', h[5]-'0'
		if d0 > 9 || d1 > 9 {
			return false
		}
		c := int(d0)*10 + int(d1)
		if c < xbcrypt.MinCost || c > xbcrypt.MaxCost {
			return false
		}
		if n, err := radix64.Decode(jb.rawSalt[:], h[7:29]); err != nil || n != 16 {
			return false
		}
		jb.workCost = c
	}

	pLen := len(jb.Plain)
	mod := pLen + 1
	cursor := 0
	for i := 0; i < 18; i++ {
		var acc uint32
		for b := 0; b < 4; b++ {
			var ch byte
			if cursor < pLen {
				ch = jb.Plain[cursor]
			}
			acc = (acc << 8) | uint32(ch)
			cursor++
			if cursor == mod {
				cursor = 0
			}
		}
		jb.pwWords[i] = acc
		jb.sltWords[i] = binary.BigEndian.Uint32(jb.rawSalt[4*(i&3):])
	}
	jb.eligible = true
	return true
}

func (e *Engine) runInterleaved(batch []*HashJob) {
	for lane, jb := range batch {
		bx := &e.boxes[lane]
		*bx = seedBox
		for i := 0; i < 18; i++ {
			bx.p[i] ^= jb.pwWords[i]
		}
		var xl, xr uint32
		pairs := bx.words()
		for i := 0; i < 521; i++ {
			xl ^= jb.sltWords[(2*i)&3]
			xr ^= jb.sltWords[(2*i+1)&3]
			xl, xr = encBlock(bx, xl, xr)
			pairs[i][0], pairs[i][1] = xl, xr
		}
	}

	cycles := 1 << batch[0].workCost
	switch len(batch) {
	case 8:
		for c := 0; c < cycles; c++ {
			keyStep8(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords, &batch[3].pwWords, &batch[4].pwWords, &batch[5].pwWords, &batch[6].pwWords, &batch[7].pwWords)
			keyStep8(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords, &batch[3].sltWords, &batch[4].sltWords, &batch[5].sltWords, &batch[6].sltWords, &batch[7].sltWords)
		}
	case 7:
		for c := 0; c < cycles; c++ {
			keyStep7(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords, &batch[3].pwWords, &batch[4].pwWords, &batch[5].pwWords, &batch[6].pwWords)
			keyStep7(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords, &batch[3].sltWords, &batch[4].sltWords, &batch[5].sltWords, &batch[6].sltWords)
		}
	case 6:
		for c := 0; c < cycles; c++ {
			keyStep6(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords, &batch[3].pwWords, &batch[4].pwWords, &batch[5].pwWords)
			keyStep6(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords, &batch[3].sltWords, &batch[4].sltWords, &batch[5].sltWords)
		}
	case 5:
		for c := 0; c < cycles; c++ {
			keyStep5(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords, &batch[3].pwWords, &batch[4].pwWords)
			keyStep5(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords, &batch[3].sltWords, &batch[4].sltWords)
		}
	case 4:
		for c := 0; c < cycles; c++ {
			keyStep4(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords, &batch[3].pwWords)
			keyStep4(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords, &batch[3].sltWords)
		}
	case 3:
		for c := 0; c < cycles; c++ {
			keyStep3(&e.boxes, &batch[0].pwWords, &batch[1].pwWords, &batch[2].pwWords)
			keyStep3(&e.boxes, &batch[0].sltWords, &batch[1].sltWords, &batch[2].sltWords)
		}
	case 2:
		for c := 0; c < cycles; c++ {
			keyStep2(&e.boxes, &batch[0].pwWords, &batch[1].pwWords)
			keyStep2(&e.boxes, &batch[0].sltWords, &batch[1].sltWords)
		}
	case 1:
		for c := 0; c < cycles; c++ {
			keyStep1(&e.boxes[0], &batch[0].pwWords)
			keyStep1(&e.boxes[0], &batch[0].sltWords)
		}
	}

	for lane, jb := range batch {
		bx := &e.boxes[lane]
		ct := orpheanWords
		for w := 0; w < 6; w += 2 {
			l, r := ct[w], ct[w+1]
			for round := 0; round < 64; round++ {
				l, r = encBlock(bx, l, r)
			}
			ct[w], ct[w+1] = l, r
		}
		var rawBytes [24]byte
		for i := 0; i < 6; i++ {
			binary.BigEndian.PutUint32(rawBytes[4*i:], ct[i])
		}
		var encodedTail [31]byte
		radix64.Encode(encodedTail[:], rawBytes[:23])
		if len(jb.Existing) != 0 {
			jb.Matched = subtle.ConstantTimeCompare(encodedTail[:], jb.Existing[29:]) == 1
			continue
		}
		jb.Encoded[0], jb.Encoded[1], jb.Encoded[2], jb.Encoded[3] = '$', '2', 'a', '$'
		jb.Encoded[4] = byte('0' + jb.workCost/10)
		jb.Encoded[5] = byte('0' + jb.workCost%10)
		jb.Encoded[6] = '$'
		radix64.Encode(jb.Encoded[7:29], jb.rawSalt[:])
		copy(jb.Encoded[29:], encodedTail[:])
		jb.Matched = true
	}
}
