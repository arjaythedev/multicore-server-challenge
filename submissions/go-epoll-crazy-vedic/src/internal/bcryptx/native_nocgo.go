//go:build !cgo

package bcryptx

const nativeCompiled = false

func processNative([]*Request) bool { return false }
