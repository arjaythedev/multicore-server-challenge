package main

import (
	"os"
	"strconv"

	"golang.org/x/sys/unix"
)

// batchSched puts every thread of the process under SCHED_BATCH. The threads keep their CPU share, but
// their frequent wakeups no longer preempt busy Postgres backends. Threads started later inherit it.
func batchSched() error {
	for range 2 { // a thread started during the first pass may have missed it
		ents, err := os.ReadDir("/proc/self/task")
		if err != nil {
			return err
		}
		for _, e := range ents {
			tid, err := strconv.Atoi(e.Name())
			if err != nil {
				continue
			}
			attr, err := unix.SchedGetAttr(tid, 0)
			if err != nil {
				return err
			}
			attr.Policy = unix.SCHED_BATCH // keeping its nice, which only privileged callers may lower
			if err := unix.SchedSetAttr(tid, attr, 0); err != nil {
				return err
			}
		}
	}
	return nil
}
