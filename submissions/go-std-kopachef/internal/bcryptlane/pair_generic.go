//go:build !amd64 || purego

package bcryptlane

func Pair(passwords [2][]byte, salts [2][16]byte, cost uint) [2][23]byte {
	return Sum2(passwords, salts, cost)
}
