package server

import (
	"context"
	"errors"
	"net"
	"time"
)

// Keep existing connections alive across temporary accept failures, including
// descriptor exhaustion. Like net/http.Server, retry with bounded backoff;
// shutdown can interrupt the delay. Successful accepts allocate no timer.
func acceptCompact(ctx context.Context, listener net.Listener) (net.Conn, error) {
	var delay time.Duration
	for {
		connection, err := listener.Accept()
		if err == nil || ctx.Err() != nil {
			return connection, err
		}
		var temporary interface{ Temporary() bool }
		if !errors.As(err, &temporary) || !temporary.Temporary() {
			return nil, err
		}
		if delay == 0 {
			delay = 5 * time.Millisecond
		} else {
			delay = min(2*delay, time.Second)
		}
		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		}
	}
}
