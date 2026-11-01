package fastbc

import (
	"crypto/rand"
	"crypto/subtle"
)

// Task is one bcrypt computation for Do: a verify when Hash is set, a new
// hash otherwise.
type Task struct {
	Hash []byte // stored hash to verify PW against; nil to create a hash
	PW   []byte
	OK   bool   // verify: PW matches Hash
	Out  []byte // hash: the new $2a$ hash
}

// Do runs tasks (1..8) in one interleaved pass when they share a cost, which
// is cost for new hashes. Tasks with another cost, or a malformed stored hash,
// are handled on their own.
func (im *Impl) Do(tasks []Task, cost uint) {
	var jobs [8]Job
	var idx [8]int
	var want [8][23]byte
	var salts [8][16]byte
	n := 0
	for i := range tasks {
		t := &tasks[i]
		if t.Hash == nil {
			rand.Read(salts[n][:])
			Prepare(&jobs[n], &salts[n], t.PW)
			idx[n] = i
			n++
			continue
		}
		salt, w, c, ok := Parse(t.Hash)
		if !ok {
			t.OK = false
			continue
		}
		var j [1]Job
		if c != cost {
			Prepare(&j[0], &salt, t.PW)
			im.Run(j[:], c)
			r := j[0].raw()
			t.OK = subtle.ConstantTimeCompare(r[:23], w[:]) == 1
			continue
		}
		want[n] = w
		Prepare(&jobs[n], &salt, t.PW)
		idx[n] = i
		n++
	}
	if n == 0 {
		return
	}
	im.Run(jobs[:n], cost)
	for k := 0; k < n; k++ {
		t := &tasks[idx[k]]
		r := jobs[k].raw()
		if t.Hash == nil {
			out := []byte{'$', '2', 'a', '$', byte('0' + cost/10), byte('0' + cost%10), '$'}
			out = b64enc(out, salts[k][:])
			t.Out = b64enc(out, r[:23])
			continue
		}
		t.OK = subtle.ConstantTimeCompare(r[:23], want[k][:]) == 1
	}
}
