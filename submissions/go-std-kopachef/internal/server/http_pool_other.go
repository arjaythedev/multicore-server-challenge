//go:build !linux

package server

import (
	"context"
	"errors"
	"net"
	"net/http"
)

func servePooledCompactListener(_ context.Context, listener net.Listener, _ http.Handler) error {
	listener.Close()
	return errors.New("HTTP_WORKERS requires Linux")
}
