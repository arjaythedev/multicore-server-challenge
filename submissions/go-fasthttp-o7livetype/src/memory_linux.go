package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// systemMemory returns the RAM this process may use: the cgroup limit if one is
// set, otherwise the machine's total. PostgreSQL shares it, so the server sizes
// its Go memory limit from it instead of from a fixed number.
func systemMemory() int64 {
	total := int64(0)
	if f, err := os.Open("/proc/meminfo"); err == nil {
		s := bufio.NewScanner(f)
		for s.Scan() {
			if rest, ok := strings.CutPrefix(s.Text(), "MemTotal:"); ok {
				kb, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64)
				total = kb << 10
				break
			}
		}
		f.Close()
	}
	if b, err := os.ReadFile("/sys/fs/cgroup/memory.max"); err == nil {
		if n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && n > 0 && (total == 0 || n < total) {
			total = n
		}
	}
	return total
}

// goMemoryLimit is the default Go soft memory limit: a share of RAM, capped.
func goMemoryLimit(share int64, ceiling int64) int64 {
	mem := systemMemory()
	if mem <= 0 {
		return ceiling
	}
	return max(256<<20, min(ceiling, mem*share/16))
}
