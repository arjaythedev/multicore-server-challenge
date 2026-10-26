package main

// wire.go: PostgreSQL binary-format parameter encoding and result decoding.

import (
	"encoding/binary"
)

// Postgres type OIDs used in prepared statements.
const (
	oidBool      = 16
	oidInt8      = 20
	oidInt4      = 23
	oidText      = 25
	oidInt4Array = 1007
	oidTextArray = 1009
	oidInt8Array = 1016
)

func encInt4(v int32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(v))
	return b
}

func encInt8(v int64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, uint64(v))
	return b
}

// arrayHeader writes the binary array header for a one-dimensional array.
func arrayHeader(b []byte, n int, elemOID uint32) []byte {
	b = binary.BigEndian.AppendUint32(b, 1) // ndim
	b = binary.BigEndian.AppendUint32(b, 0) // has nulls
	b = binary.BigEndian.AppendUint32(b, elemOID)
	b = binary.BigEndian.AppendUint32(b, uint32(n))
	b = binary.BigEndian.AppendUint32(b, 1) // lower bound
	return b
}

func encInt4Array(vs []int32) []byte {
	b := arrayHeader(make([]byte, 0, 20+8*len(vs)), len(vs), oidInt4)
	for _, v := range vs {
		b = binary.BigEndian.AppendUint32(b, 4)
		b = binary.BigEndian.AppendUint32(b, uint32(v))
	}
	return b
}

func encInt8Array(vs []int64) []byte {
	b := arrayHeader(make([]byte, 0, 20+12*len(vs)), len(vs), oidInt8)
	for _, v := range vs {
		b = binary.BigEndian.AppendUint32(b, 8)
		b = binary.BigEndian.AppendUint64(b, uint64(v))
	}
	return b
}

func encTextArray(vs []string) []byte {
	size := 20
	for _, v := range vs {
		size += 4 + len(v)
	}
	b := arrayHeader(make([]byte, 0, size), len(vs), oidText)
	for _, v := range vs {
		b = binary.BigEndian.AppendUint32(b, uint32(len(v)))
		b = append(b, v...)
	}
	return b
}

// Decoding. All decoders take the raw binary column value (nil = SQL NULL).

func decInt4(b []byte) int32 { return int32(binary.BigEndian.Uint32(b)) }
func decInt8(b []byte) int64 { return int64(binary.BigEndian.Uint64(b)) }
func decBool(b []byte) bool  { return len(b) == 1 && b[0] == 1 }

// decTextArray calls fn for each element of a one-dimensional text[] (binary format).
func decTextArray(b []byte, fn func(elem []byte)) {
	if len(b) < 12 {
		return
	}
	ndim := binary.BigEndian.Uint32(b[0:4])
	if ndim == 0 {
		return
	}
	n := int(binary.BigEndian.Uint32(b[12:16]))
	p := 20
	for i := 0; i < n && p+4 <= len(b); i++ {
		l := int(int32(binary.BigEndian.Uint32(b[p : p+4])))
		p += 4
		if l < 0 {
			fn(nil)
			continue
		}
		fn(b[p : p+l])
		p += l
	}
}
