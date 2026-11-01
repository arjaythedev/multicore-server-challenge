package main

import "testing"

// pgconn sends a nil parameter slice as NULL, so every non-NULL value must encode to a non-nil slice, also when
// it is empty and the buffer has not been allocated yet.
func TestEmptyParamsAreNotNull(t *testing.T) {
	s := ""
	for _, c := range []struct {
		name string
		oid  uint32
		arg  any
	}{
		{"string", oidText, ""},
		{"*string", oidText, &s},
		{"bool", oidBool, false},
		{"int64", oidInt8, int64(0)},
		{"int64 as int4", oidInt4, int64(0)},
		{"[]int64", oidInt8Array, []int64(nil)},
		{"[]string", oidText, []string(nil)},
	} {
		got, null, err := appendParam(nil, c.oid, c.arg)
		if err != nil || null || got == nil {
			t.Errorf("%s: got %v null=%v err=%v, want a non-nil value", c.name, got, null, err)
		}
	}
	var np *string
	if _, null, _ := appendParam(nil, oidText, np); !null {
		t.Errorf("nil *string must be NULL")
	}
	if _, null, _ := appendParam(nil, oidText, nil); !null {
		t.Errorf("nil must be NULL")
	}
}
