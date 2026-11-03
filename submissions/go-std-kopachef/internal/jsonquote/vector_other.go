//go:build !amd64 || purego

package jsonquote

func firstJSONSpecial(value string) int { return firstJSONSpecialScalar(value) }
