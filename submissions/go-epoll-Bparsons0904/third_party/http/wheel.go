package http

// Timeouts use a timing wheel with one bucket per second, so a loop never
// scans all its connections. Each connection is filed, through an intrusive
// list, under one second no later than its deadline. Extending a deadline (the
// common case: another request on a keep-alive connection) only stores the
// new value; the connection is refiled when its bucket comes due. Only a
// shorter deadline relinks it at once.

const (
	wheelSize = 128 // seconds: more than any timeout, so buckets never wrap onto live deadlines
	wheelMask = wheelSize - 1
	// maxTimeout is the longest timeout the wheel supports: a deadline lies
	// at most maxTimeout+1 seconds (see after), plus a second of tick lag,
	// past the last bucket run.
	maxTimeout = wheelSize - 3
)

// after returns the deadline for a timeout of sec seconds from now. Loop time
// is whole seconds rounded up (now > the true time), so one more second makes
// the connection last at least the full timeout, never less.
func (l *loop) after(sec uint32) uint32 { return l.now + sec + 1 }

func (l *loop) setDeadline(s int32, c *conn, d uint32) {
	if d <= l.ticked {
		d = l.ticked + 1
	}
	c.deadline = d
	if c.wsec != 0 && c.wsec <= d {
		return
	}
	l.wheelUnlink(c)
	l.wheelLink(s, c, d)
}

func (l *loop) wheelLink(s int32, c *conn, sec uint32) {
	b := sec & wheelMask
	c.wsec, c.wprev, c.wnext = sec, -1, l.wheel[b]
	if c.wnext >= 0 {
		l.conn(c.wnext).wprev = s
	}
	l.wheel[b] = s
}

func (l *loop) wheelUnlink(c *conn) {
	if c.wsec == 0 {
		return
	}
	if c.wprev >= 0 {
		l.conn(c.wprev).wnext = c.wnext
	} else {
		l.wheel[c.wsec&wheelMask] = c.wnext
	}
	if c.wnext >= 0 {
		l.conn(c.wnext).wprev = c.wprev
	}
	c.wsec, c.wprev, c.wnext = 0, -1, -1
}

// expire runs the buckets of every second up to now: connections whose
// deadline has passed time out, the others are refiled under their deadline.
func (l *loop) expire() {
	for l.ticked < l.now {
		l.ticked++
		b := l.ticked & wheelMask
		s := l.wheel[b]
		l.wheel[b] = -1
		for s >= 0 {
			c := l.conn(s)
			next := c.wnext
			c.wsec, c.wprev, c.wnext = 0, -1, -1
			if c.deadline > l.ticked {
				l.wheelLink(s, c, c.deadline)
			} else {
				l.timeout(s, c)
			}
			s = next
		}
	}
}

func (l *loop) timeout(s int32, c *conn) {
	if c.op >= 0 {
		// The Op owns the connection until it returns (it may be writing to it).
		l.setDeadline(s, c, l.after(l.readSec))
		return
	}
	if c.flags&fLingering == 0 {
		l.count.timeouts++
	}
	l.closeConn(s, c)
}
