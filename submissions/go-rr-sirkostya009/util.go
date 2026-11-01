package main

import "unsafe"

func unsafeBytes(s string) []byte { return unsafe.Slice(unsafe.StringData(s), len(s)) }

func unsafeString(b []byte) string { return unsafe.String(unsafe.SliceData(b), len(b)) }
