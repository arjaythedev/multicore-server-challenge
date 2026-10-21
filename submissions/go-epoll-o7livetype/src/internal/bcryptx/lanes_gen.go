// Blowfish rounds unrolled for 1-4 interleaved lanes (generated once; edit with care).

package bcryptx

// encrypt1 is one Blowfish block encryption, matching x/crypto/blowfish encryptBlock.
func encrypt1(s0 *state, l0, r0 uint32) (uint32, uint32) {
	l0 ^= s0.p[0]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[1]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[2]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[3]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[4]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[5]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[6]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[7]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[8]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[9]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[10]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[11]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[12]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[13]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[14]
	r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[15]
	l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[16]
	r0 ^= s0.p[17]
	l0, r0 = r0, l0
	return l0, r0
}

// expand1 is ExpandKey without salt for 1 independent states.
func expand1(s0 *state, k0 *[18]uint32) {
	for i := range 18 {
		s0.p[i] ^= k0[i]
	}
	var l0, r0 uint32
	q0 := s0.pairs()
	for i := range 521 {
		l0 ^= s0.p[0]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[1]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[2]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[3]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[4]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[5]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[6]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[7]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[8]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[9]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[10]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[11]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[12]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[13]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[14]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[15]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[16]
		r0 ^= s0.p[17]
		l0, r0 = r0, l0
		q0[i][0], q0[i][1] = l0, r0
	}
}

// expand2 is ExpandKey without salt for 2 independent states.
func expand2(s0, s1 *state, k0, k1 *[18]uint32) {
	for i := range 18 {
		s0.p[i] ^= k0[i]
		s1.p[i] ^= k1[i]
	}
	var l0, r0, l1, r1 uint32
	q0 := s0.pairs()
	q1 := s1.pairs()
	for i := range 521 {
		l0 ^= s0.p[0]
		l1 ^= s1.p[0]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[1]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[1]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[2]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[2]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[3]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[3]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[4]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[4]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[5]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[5]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[6]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[6]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[7]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[7]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[8]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[8]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[9]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[9]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[10]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[10]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[11]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[11]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[12]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[12]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[13]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[13]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[14]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[14]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[15]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[15]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[16]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[16]
		r0 ^= s0.p[17]
		l0, r0 = r0, l0
		r1 ^= s1.p[17]
		l1, r1 = r1, l1
		q0[i][0], q0[i][1] = l0, r0
		q1[i][0], q1[i][1] = l1, r1
	}
}

// expand3 is ExpandKey without salt for 3 independent states.
func expand3(s0, s1, s2 *state, k0, k1, k2 *[18]uint32) {
	for i := range 18 {
		s0.p[i] ^= k0[i]
		s1.p[i] ^= k1[i]
		s2.p[i] ^= k2[i]
	}
	var l0, r0, l1, r1, l2, r2 uint32
	q0 := s0.pairs()
	q1 := s1.pairs()
	q2 := s2.pairs()
	for i := range 521 {
		l0 ^= s0.p[0]
		l1 ^= s1.p[0]
		l2 ^= s2.p[0]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[1]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[1]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[1]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[2]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[2]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[2]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[3]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[3]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[3]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[4]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[4]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[4]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[5]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[5]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[5]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[6]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[6]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[6]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[7]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[7]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[7]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[8]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[8]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[8]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[9]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[9]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[9]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[10]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[10]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[10]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[11]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[11]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[11]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[12]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[12]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[12]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[13]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[13]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[13]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[14]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[14]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[14]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[15]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[15]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[15]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[16]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[16]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[16]
		r0 ^= s0.p[17]
		l0, r0 = r0, l0
		r1 ^= s1.p[17]
		l1, r1 = r1, l1
		r2 ^= s2.p[17]
		l2, r2 = r2, l2
		q0[i][0], q0[i][1] = l0, r0
		q1[i][0], q1[i][1] = l1, r1
		q2[i][0], q2[i][1] = l2, r2
	}
}

// expand4 is ExpandKey without salt for 4 independent states.
func expand4(s0, s1, s2, s3 *state, k0, k1, k2, k3 *[18]uint32) {
	for i := range 18 {
		s0.p[i] ^= k0[i]
		s1.p[i] ^= k1[i]
		s2.p[i] ^= k2[i]
		s3.p[i] ^= k3[i]
	}
	var l0, r0, l1, r1, l2, r2, l3, r3 uint32
	q0 := s0.pairs()
	q1 := s1.pairs()
	q2 := s2.pairs()
	q3 := s3.pairs()
	for i := range 521 {
		l0 ^= s0.p[0]
		l1 ^= s1.p[0]
		l2 ^= s2.p[0]
		l3 ^= s3.p[0]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[1]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[1]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[1]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[1]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[2]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[2]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[2]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[2]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[3]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[3]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[3]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[3]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[4]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[4]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[4]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[4]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[5]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[5]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[5]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[5]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[6]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[6]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[6]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[6]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[7]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[7]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[7]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[7]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[8]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[8]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[8]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[8]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[9]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[9]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[9]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[9]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[10]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[10]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[10]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[10]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[11]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[11]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[11]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[11]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[12]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[12]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[12]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[12]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[13]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[13]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[13]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[13]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[14]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[14]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[14]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[14]
		r0 ^= (((s0.s0[uint8(l0>>24)] + s0.s1[uint8(l0>>16)]) ^ s0.s2[uint8(l0>>8)]) + s0.s3[uint8(l0)]) ^ s0.p[15]
		r1 ^= (((s1.s0[uint8(l1>>24)] + s1.s1[uint8(l1>>16)]) ^ s1.s2[uint8(l1>>8)]) + s1.s3[uint8(l1)]) ^ s1.p[15]
		r2 ^= (((s2.s0[uint8(l2>>24)] + s2.s1[uint8(l2>>16)]) ^ s2.s2[uint8(l2>>8)]) + s2.s3[uint8(l2)]) ^ s2.p[15]
		r3 ^= (((s3.s0[uint8(l3>>24)] + s3.s1[uint8(l3>>16)]) ^ s3.s2[uint8(l3>>8)]) + s3.s3[uint8(l3)]) ^ s3.p[15]
		l0 ^= (((s0.s0[uint8(r0>>24)] + s0.s1[uint8(r0>>16)]) ^ s0.s2[uint8(r0>>8)]) + s0.s3[uint8(r0)]) ^ s0.p[16]
		l1 ^= (((s1.s0[uint8(r1>>24)] + s1.s1[uint8(r1>>16)]) ^ s1.s2[uint8(r1>>8)]) + s1.s3[uint8(r1)]) ^ s1.p[16]
		l2 ^= (((s2.s0[uint8(r2>>24)] + s2.s1[uint8(r2>>16)]) ^ s2.s2[uint8(r2>>8)]) + s2.s3[uint8(r2)]) ^ s2.p[16]
		l3 ^= (((s3.s0[uint8(r3>>24)] + s3.s1[uint8(r3>>16)]) ^ s3.s2[uint8(r3>>8)]) + s3.s3[uint8(r3)]) ^ s3.p[16]
		r0 ^= s0.p[17]
		l0, r0 = r0, l0
		r1 ^= s1.p[17]
		l1, r1 = r1, l1
		r2 ^= s2.p[17]
		l2, r2 = r2, l2
		r3 ^= s3.p[17]
		l3, r3 = r3, l3
		q0[i][0], q0[i][1] = l0, r0
		q1[i][0], q1[i][1] = l1, r1
		q2[i][0], q2[i][1] = l2, r2
		q3[i][0], q3[i][1] = l3, r3
	}
}
