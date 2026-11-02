//go:build linux

package server

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"syscall"
	"time"
)

// The reactor owns registration, idle expiry and the connection registry.
// A worker exclusively owns session fields between dispatch and completion.
// One-shot readiness prevents two workers from serving the same connection.
type pooledConnection struct {
	session            *compactSession
	raw                syscall.RawConn
	ctx                context.Context
	cancel             context.CancelFunc
	id                 int32
	active             bool
	readyNext          *pooledConnection
	idlePrev, idleNext *pooledConnection
	idleUntil          time.Time
}

type pooledCompletion struct {
	connection *pooledConnection
	keep       bool
}

// Intrusive one-second buckets avoid one long-lived Go timer per idle socket.
// Idle expiry is rounded up, so an idle connection closes after 75-76 seconds.
type pooledIdleWheel struct {
	buckets [76]pooledConnection
	origin  time.Time
	tick    int64
}

func (w *pooledIdleWheel) remove(p *pooledConnection) {
	if p.idlePrev != nil {
		p.idlePrev.idleNext = p.idleNext
		p.idleNext.idlePrev = p.idlePrev
		p.idlePrev, p.idleNext = nil, nil
	}
}

func (w *pooledIdleWheel) add(p *pooledConnection, until time.Time) {
	w.remove(p)
	p.idleUntil = until
	b := &w.buckets[(int64(until.Sub(w.origin)/time.Second)+1)%int64(len(w.buckets))]
	if b.idleNext == nil {
		b.idleNext, b.idlePrev = b, b
	}
	p.idlePrev, p.idleNext = b.idlePrev, b
	b.idlePrev.idleNext = p
	b.idlePrev = p
}

func (w *pooledIdleWheel) expire(now time.Time, closeConnection func(*pooledConnection)) {
	for w.tick < int64(now.Sub(w.origin)/time.Second) {
		w.tick++
		b := &w.buckets[w.tick%int64(len(w.buckets))]
		last := b.idlePrev
		for b.idleNext != nil && b.idleNext != b {
			p := b.idleNext
			final := p == last
			w.remove(p)
			if !p.idleUntil.After(now) {
				closeConnection(p)
			} else {
				w.add(p, p.idleUntil)
			}
			if final {
				break
			}
		}
	}
}

func pooledPollControl(epoll, operation int, p *pooledConnection) error {
	// The registration's payload is a monotonic ID rather than an OS fd.
	// A stale event for a closed/reused fd cannot activate a new connection.
	event := syscall.EpollEvent{Events: syscall.EPOLLIN | syscall.EPOLLRDHUP | syscall.EPOLLONESHOT, Fd: p.id}
	var controlErr error
	if err := p.raw.Control(func(fd uintptr) {
		controlErr = syscall.EpollCtl(epoll, operation, int(fd), &event)
	}); err != nil {
		return err
	}
	return controlErr
}

func servePooledCompactListener(parent context.Context, listener net.Listener, handler http.Handler) error {
	epoll, err := syscall.EpollCreate1(syscall.EPOLL_CLOEXEC)
	if err != nil {
		listener.Close()
		return err
	}
	ctx, cancel := context.WithCancel(parent)
	jobs := make(chan *pooledConnection, compactHTTPWorkers)
	completed := make(chan pooledCompletion, compactHTTPWorkers)
	accepted := make(chan net.Conn, 1024)
	acceptError := make(chan error, 1)
	acceptDone := make(chan struct{})
	connections := make(map[int32]*pooledConnection)
	wheel := pooledIdleWheel{origin: time.Now()}
	var workers sync.WaitGroup
	var parents [32]context.Context
	var parentCancels [32]context.CancelFunc
	if compactContextParent == "sharded" {
		for i := range parents {
			parents[i], parentCancels[i] = context.WithCancel(ctx)
		}
	}
	go func() {
		defer close(acceptDone)
		for {
			connection, err := acceptCompact(ctx, listener)
			if err != nil {
				acceptError <- err
				return
			}
			select {
			case accepted <- connection:
			case <-ctx.Done():
				connection.Close()
				return
			}
		}
	}()
	go func() {
		select {
		case <-ctx.Done():
			listener.Close()
		case <-acceptDone:
		}
	}()
	closeConnection := func(p *pooledConnection) {
		wheel.remove(p)
		delete(connections, p.id)
		if p.cancel != nil {
			p.cancel()
		}
		p.session.connection.Close()
	}
	defer func() {
		cancel()
		listener.Close()
		<-acceptDone
		for len(accepted) != 0 {
			(<-accepted).Close()
		}
		for _, p := range connections {
			closeConnection(p)
		}
		workers.Wait()
		for _, stop := range parentCancels {
			if stop != nil {
				stop()
			}
		}
		syscall.Close(epoll)
	}()
	for range compactHTTPWorkers {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case p := <-jobs:
					if ctx.Err() != nil {
						return
					}
					keep := func() (keep bool) {
						defer func() {
							if failure := recover(); failure != nil {
								log.Printf("pooled HTTP handler panic: %v", failure)
								keep = false
							}
						}()
						return p.session.serveOne(p.ctx, handler)
					}()
					select {
					case completed <- pooledCompletion{p, keep}:
					case <-ctx.Done():
						return
					}
				}
			}
		}()
	}
	var nextID int32
	var readyHead, readyTail *pooledConnection
	dispatch := func(p *pooledConnection) {
		wheel.remove(p)
		p.active = true
		// Preserve ordering when there is already an admission backlog.
		if readyHead == nil {
			select {
			case jobs <- p:
				return
			default:
			}
		}
		if readyTail == nil {
			readyHead = p
		} else {
			readyTail.readyNext = p
		}
		readyTail = p
	}
	events := make([]syscall.EpollEvent, 1024)
	for ctx.Err() == nil {
		// Finish ownership transfers before touching a completed session.
		for range 4096 {
			select {
			case result := <-completed:
				p := result.connection
				if !result.keep {
					closeConnection(p)
					continue
				}
				if p.session.reader.Buffered() > 0 {
					dispatch(p)
					continue
				}
				p.active = false
				if err := pooledPollControl(epoll, syscall.EPOLL_CTL_MOD, p); err != nil {
					closeConnection(p)
					continue
				}
				wheel.add(p, time.Now().Add(75*time.Second))
			default:
				goto completionsDrained
			}
		}
	completionsDrained:
		for range 1024 {
			select {
			case connection := <-accepted:
				system, ok := connection.(syscall.Conn)
				if !ok {
					connection.Close()
					return fmt.Errorf("pooled HTTP requires syscall.Conn, got %T", connection)
				}
				raw, err := system.SyscallConn()
				if err != nil {
					connection.Close()
					return err
				}
				for {
					nextID++
					if nextID != 0 && connections[nextID] == nil {
						break
					}
				}
				p := &pooledConnection{session: newCompactSession(connection), raw: raw, ctx: ctx, id: nextID}
				p.session.pooled = true
				if compactContextParent == "connection" {
					p.ctx, p.cancel = context.WithCancel(ctx)
				} else if compactContextParent == "sharded" {
					p.ctx = parents[uint32(nextID)%uint32(len(parents))]
				}
				connections[p.id] = p
				if err := pooledPollControl(epoll, syscall.EPOLL_CTL_ADD, p); err != nil {
					closeConnection(p)
					return err
				}
				wheel.add(p, time.Now().Add(75*time.Second))
			default:
				goto acceptsDrained
			}
		}
	acceptsDrained:
		for readyHead != nil {
			p := readyHead
			next := p.readyNext
			// Clear the reactor-owned link before publishing to a worker.
			p.readyNext = nil
			select {
			case jobs <- p:
				readyHead = next
				if next == nil {
					readyTail = nil
				}
			default:
				p.readyNext = next
				goto readyDrained
			}
		}
	readyDrained:
		wheel.expire(time.Now(), closeConnection)
		select {
		case err := <-acceptError:
			if parent.Err() != nil || errors.Is(err, net.ErrClosed) {
				return http.ErrServerClosed
			}
			return err
		default:
		}
		// A short bounded wait also services accepts and completions without
		// adding an eventfd write syscall for every completed response.
		n, err := syscall.EpollWait(epoll, events, 1)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		for _, event := range events[:n] {
			if p := connections[event.Fd]; p != nil && !p.active {
				dispatch(p)
			}
		}
	}
	return http.ErrServerClosed
}
