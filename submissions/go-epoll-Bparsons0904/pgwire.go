package main

import (
	"encoding/binary"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"
)

// Binary parameters and results over pgconn pipelines. Only the types the statements use are supported.

const (
	oidBool        = 16
	oidInt8        = 20
	oidInt2        = 21
	oidInt4        = 23
	oidText        = 25
	oidVarchar     = 1043
	oidTimestamptz = 1184
	oidInt8Array   = 1016
	oidInt4Array   = 1007

	pgEpochMicros = 946684800_000000 // 2000-01-01 UTC in Unix microseconds
)

// prepared is a statement parsed on one connection.
type prepared struct {
	sd         *pgconn.StatementDescription
	pfmt, rfmt []int16
}

func newPrepared(sd *pgconn.StatementDescription) *prepared {
	p := &prepared{sd: sd, pfmt: make([]int16, len(sd.ParamOIDs)), rfmt: make([]int16, len(sd.Fields))}
	for i := range p.pfmt {
		p.pfmt[i] = 1
	}
	for i := range p.rfmt {
		p.rfmt[i] = 1
	}
	return p
}

func appendArrayHeader(b []byte, elem uint32, n int) []byte {
	b = binary.BigEndian.AppendUint32(b, 1) // dimensions
	b = binary.BigEndian.AppendUint32(b, 0) // no nulls
	b = binary.BigEndian.AppendUint32(b, elem)
	b = binary.BigEndian.AppendUint32(b, uint32(n))
	return binary.BigEndian.AppendUint32(b, 1) // lower bound
}

// appendParam appends the binary form of arg for a parameter of type oid. A nil argument or nil pointer is NULL
// (ok false).
func appendParam(b []byte, oid uint32, arg any) (out []byte, null bool, err error) {
	out, null, err = appendParamBytes(b, oid, arg)
	if !null && err == nil && out == nil {
		out = []byte{} // pgconn sends a nil slice as NULL; an empty value must not be
	}
	return out, null, err
}

func appendParamBytes(b []byte, oid uint32, arg any) (out []byte, null bool, err error) {
	switch v := arg.(type) {
	case nil:
		return b, true, nil
	case int64:
		return appendIntParam(b, oid, v)
	case int:
		return appendIntParam(b, oid, int64(v))
	case string:
		return append(b, v...), false, nil
	case *string:
		if v == nil {
			return b, true, nil
		}
		return append(b, *v...), false, nil
	case bool:
		if v {
			return append(b, 1), false, nil
		}
		return append(b, 0), false, nil
	case []int64:
		if oid == oidInt4Array {
			b = appendArrayHeader(b, oidInt4, len(v))
			for _, x := range v {
				b = binary.BigEndian.AppendUint32(b, 4)
				b = binary.BigEndian.AppendUint32(b, uint32(x))
			}
			return b, false, nil
		}
		b = appendArrayHeader(b, oidInt8, len(v))
		for _, x := range v {
			b = binary.BigEndian.AppendUint32(b, 8)
			b = binary.BigEndian.AppendUint64(b, uint64(x))
		}
		return b, false, nil
	case []string:
		b = appendArrayHeader(b, oidText, len(v))
		for _, x := range v {
			b = binary.BigEndian.AppendUint32(b, uint32(len(x)))
			b = append(b, x...)
		}
		return b, false, nil
	}
	return b, false, fmt.Errorf("unsupported parameter type %T", arg)
}

func appendIntParam(b []byte, oid uint32, v int64) ([]byte, bool, error) {
	switch oid {
	case oidInt4:
		return binary.BigEndian.AppendUint32(b, uint32(v)), false, nil
	case oidInt2:
		return binary.BigEndian.AppendUint16(b, uint16(v)), false, nil
	case oidInt8:
		return binary.BigEndian.AppendUint64(b, uint64(v)), false, nil
	}
	return b, false, fmt.Errorf("integer for parameter type %d", oid)
}

// pgRows reads the rows of one statement's result.
type pgRows struct {
	src rowSource
	row [][]byte
	ar  *arena // where decoded text goes; nil for heap strings
	err error  // first malformed value met by the typed readers below
}

// rowSource is what pgRows needs of a result: *pgconn.ResultReader, or a replay of captured rows.
type rowSource interface {
	NextRow() bool
	Values() [][]byte
}

func (r *pgRows) Next() bool {
	if r.src.NextRow() {
		r.row = r.src.Values()
		return true
	}
	return false
}

// RawValues are the current row's column bytes (binary format; text columns are the UTF-8 text itself).
func (r *pgRows) RawValues() [][]byte { return r.row }

var errShort = fmt.Errorf("short binary value")

func scanInt(v []byte) (int64, error) {
	switch len(v) {
	case 8:
		return int64(binary.BigEndian.Uint64(v)), nil
	case 4:
		return int64(int32(binary.BigEndian.Uint32(v))), nil
	case 2:
		return int64(int16(binary.BigEndian.Uint16(v))), nil
	}
	return 0, errShort
}

// Typed readers of the current row's columns. A NULL or malformed value in a column that is not nullable sets
// err, which the statement's reader returns through rows.Err().

func (r *pgRows) Err() error { return r.err }

func (r *pgRows) fail(err error) {
	if r.err == nil {
		r.err = err
	}
}

func (r *pgRows) i64(i int) int64 {
	v := r.row[i]
	n, err := scanInt(v)
	if err != nil {
		r.fail(err)
	}
	return n
}

// ni64 returns the value and whether it is not NULL.
func (r *pgRows) ni64(i int) (int64, bool) {
	if r.row[i] == nil {
		return 0, false
	}
	return r.i64(i), true
}

func (r *pgRows) boolean(i int) bool {
	v := r.row[i]
	if len(v) != 1 {
		r.fail(errShort)
		return false
	}
	return v[0] != 0
}

// micros returns a timestamptz as microseconds since the Unix epoch.
func (r *pgRows) micros(i int) int64 {
	v := r.row[i]
	if len(v) != 8 {
		r.fail(errShort)
		return 0
	}
	return int64(binary.BigEndian.Uint64(v)) + pgEpochMicros
}

func (r *pgRows) str(i int) string {
	v := r.row[i]
	if v == nil {
		r.fail(errNull)
		return ""
	}
	return r.ar.str(v)
}

func (r *pgRows) nstr(i int) nstr {
	v := r.row[i]
	if v == nil {
		return nstr{}
	}
	return nstr{r.ar.str(v), true}
}

// texts decodes a one-dimensional text[] column.
func (r *pgRows) texts(i int) []string {
	v := r.row[i]
	if len(v) < 12 {
		r.fail(errShort)
		return nil
	}
	if binary.BigEndian.Uint32(v) == 0 {
		return nil
	}
	if len(v) < 20 {
		r.fail(errShort)
		return nil
	}
	n := int(binary.BigEndian.Uint32(v[12:]))
	out := r.ar.strings(n)
	p := 20
	for j := 0; j < n; j++ {
		if p+4 > len(v) {
			r.fail(errShort)
			return nil
		}
		l := int(int32(binary.BigEndian.Uint32(v[p:])))
		p += 4
		if l < 0 {
			continue
		}
		if p+l > len(v) {
			r.fail(errShort)
			return nil
		}
		out[j] = r.ar.str(v[p : p+l])
		p += l
	}
	return out
}

var errNull = fmt.Errorf("NULL in a column that is not nullable")

// nstr is a nullable text value.
type nstr struct {
	s  string
	ok bool
}
