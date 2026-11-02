//go:build !amd64 || purego

package bcryptlane

// Five retains the portable implementation when amd64 assembly is unavailable.
func Five(passwords [5][]byte, salts [5][16]byte, cost uint) [5][23]byte {
	return Sum5(passwords, salts, cost)
}
