//go:build amd64 && !purego

package jsonquote

func firstJSONSpecial(value string) int {
	if len(value) < 16 {
		return firstJSONSpecialScalar(value)
	}
	return firstJSONSpecialSSE2(value)
}

// firstJSONSpecialSSE2 requires at least 16 bytes. All loads remain within the
// input string, including the final overlapping block. SSE2 is baseline amd64.
//
//go:noescape
func firstJSONSpecialSSE2(value string) int
