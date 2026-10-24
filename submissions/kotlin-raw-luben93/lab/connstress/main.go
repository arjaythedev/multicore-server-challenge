// connstress: opens N keep-alive connections to a Conduit server, does one GET on each, holds them all idle,
// then reuses every connection once more. Reports connect/first-byte latency percentiles and failures.
// Exercises the server's accept path (backlog, SO_REUSEPORT), per-connection memory and fd handling.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	target := flag.String("target", "127.0.0.1:3000", "host:port")
	n := flag.Int("n", 10000, "connections")
	rate := flag.Int("rate", 2000, "new connections per second")
	hold := flag.Duration("hold", 20*time.Second, "idle time before the second round")
	srcs := flag.Int("srcs", 4, "source addresses 127.0.0.(2..srcs+1) to spread ephemeral ports")
	path := flag.String("path", "/api/tags", "request path")
	flag.Parse()

	conns := make([]net.Conn, *n)
	readers := make([]*bufio.Reader, *n)
	lat := make([]time.Duration, *n)
	var fails, okc atomic.Int64
	var errMu sync.Mutex
	errs := map[string]int{}
	note := func(e error) {
		errMu.Lock()
		s := e.Error()
		if i := strings.LastIndex(s, ": "); i >= 0 {
			s = s[i+2:]
		}
		errs[s]++
		errMu.Unlock()
		fails.Add(1)
	}
	req := []byte("GET " + *path + " HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n")
	do := func(i int) error {
		if _, err := conns[i].Write(req); err != nil {
			return err
		}
		resp, err := http.ReadResponse(readers[i], nil)
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		return nil
	}

	start := time.Now()
	var wg sync.WaitGroup
	tick := time.Second / time.Duration(*rate)
	for i := 0; i < *n; i++ {
		time.Sleep(tick)
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			d := net.Dialer{Timeout: 10 * time.Second, KeepAlive: -1,
				LocalAddr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, byte(2+i%*srcs))}}
			t0 := time.Now()
			c, err := d.Dial("tcp", *target)
			if err != nil {
				note(err)
				return
			}
			c.SetDeadline(time.Now().Add(15 * time.Second))
			conns[i] = c
			readers[i] = bufio.NewReaderSize(c, 4096)
			if err := do(i); err != nil {
				note(err)
				c.Close()
				conns[i] = nil
				return
			}
			lat[i] = time.Since(t0)
			okc.Add(1)
		}(i)
	}
	wg.Wait()
	ramp := time.Since(start)
	ls := []time.Duration{}
	for _, l := range lat {
		if l > 0 {
			ls = append(ls, l)
		}
	}
	sort.Slice(ls, func(a, b int) bool { return ls[a] < ls[b] })
	pct := func(p float64) time.Duration {
		if len(ls) == 0 {
			return 0
		}
		return ls[int(float64(len(ls)-1)*p)]
	}
	fmt.Printf("round1: %d ok, %d failed in %v; connect+first response p50=%v p99=%v max=%v\n",
		okc.Load(), fails.Load(), ramp.Round(time.Millisecond), pct(0.5), pct(0.99), pct(1))
	if len(errs) > 0 {
		fmt.Println("  errors:", errs)
	}
	fmt.Printf("holding %d idle connections for %v (check server RSS / fds now)\n", okc.Load(), *hold)
	os.Stdout.Sync()
	time.Sleep(*hold)

	var ok2, fail2 atomic.Int64
	errs = map[string]int{}
	t1 := time.Now()
	for i := 0; i < *n; i++ {
		if conns[i] == nil {
			continue
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			conns[i].SetDeadline(time.Now().Add(15 * time.Second))
			if err := do(i); err != nil {
				note(err)
				fail2.Add(1)
			} else {
				ok2.Add(1)
			}
			conns[i].Close()
		}(i)
	}
	wg.Wait()
	fmt.Printf("round2 (reuse after idle): %d ok, %d failed in %v\n", ok2.Load(), fail2.Load(), time.Since(t1).Round(time.Millisecond))
	if len(errs) > 0 {
		fmt.Println("  errors:", errs)
	}
}
