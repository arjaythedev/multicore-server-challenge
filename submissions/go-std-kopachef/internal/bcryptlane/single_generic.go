//go:build !amd64 || purego

package bcryptlane

// Single computes one complete bcrypt checksum with the portable Blowfish kernel.
func Single(password []byte, salt [16]byte, cost uint) [23]byte {
	return standardSingle(password, salt, cost)
}
