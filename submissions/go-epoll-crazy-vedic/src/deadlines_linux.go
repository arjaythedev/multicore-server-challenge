package main

// Intrusive timer wheel: one node per live socket, no per-refresh allocation,
// and no scan of the descriptor table on every timer tick. A long deadline
// can span multiple wheel rotations; its absolute value remains authoritative.

func (r *eventLoop) removeDeadline(fd int) {
	c := &r.conns[fd]
	if c.timerSlot < 0 {
		return
	}
	if c.timerPrev >= 0 {
		r.conns[c.timerPrev].timerNext = c.timerNext
	} else {
		r.timers[c.timerSlot] = c.timerNext
	}
	if c.timerNext >= 0 {
		r.conns[c.timerNext].timerPrev = c.timerPrev
	}
	c.timerSlot, c.timerPrev, c.timerNext = -1, -1, -1
}

func (r *eventLoop) setDeadline(fd int, deadline int64) {
	c := &r.conns[fd]
	r.removeDeadline(fd)
	c.deadline = deadline
	resolution := max(int64(1), r.tick.Milliseconds())
	tick := max(r.timerTick, (deadline+resolution-1)/resolution)
	slot := int32(tick % int64(len(r.timers)))
	head := r.timers[slot]
	c.timerSlot, c.timerPrev, c.timerNext = slot, -1, head
	if head >= 0 {
		r.conns[head].timerPrev = int32(fd)
	}
	r.timers[slot] = int32(fd)
}

func (r *eventLoop) expire() {
	through := r.now / max(int64(1), r.tick.Milliseconds())
	for r.timerTick <= through {
		slot := r.timerTick % int64(len(r.timers))
		head := r.timers[slot]
		r.timers[slot] = -1
		r.timerTick++
		for head >= 0 {
			fd := int(head)
			c := &r.conns[fd]
			head = c.timerNext
			c.timerSlot, c.timerPrev, c.timerNext = -1, -1, -1
			if !c.open {
				continue
			}
			if r.now >= c.deadline {
				r.close(fd)
			} else {
				r.setDeadline(fd, c.deadline)
			}
		}
	}
}
