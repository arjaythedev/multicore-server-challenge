//go:build linux

package main

import (
	"context"
	"encoding/binary"
	"errors"
	"math/bits"
	"net"
	"strconv"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	inlineFrameCap = 512
	slotWaitTTL    = 30 * time.Second
)

const (
	flagActive uint8 = 1 << iota
	flagShutting
	flagSending100
	flagSent100
	flagHalfClosed
	flagQueuedRead
	flagWaitingSlot
)

var (
	bootEpoch    = time.Now()
	http100Bytes = []byte("HTTP/1.1 100 Continue\r\n\r\n")
)

func clockNano() int64 {
	return int64(time.Since(bootEpoch))
}

type pollerOptions struct {
	bindHost   string
	bindPort   int
	loopCount  int
	activeCap  int
	queueCap   int
	maxSockets int
	fdLimit    int
	readTTL    time.Duration
	writeTTL   time.Duration
	idleTTL    time.Duration
	drainTTL   time.Duration
}

func readPollerOptions(cpus, activeCap, queueCap, maxSockets, fdLimit int) (pollerOptions, error) {
	opts := pollerOptions{
		bindHost:   readEnvStr("HOST", "0.0.0.0"),
		activeCap:  activeCap,
		queueCap:   queueCap,
		maxSockets: maxSockets,
		fdLimit:    fdLimit,
		readTTL:    15 * time.Second,
		writeTTL:   15 * time.Second,
		idleTTL:    75 * time.Second,
		drainTTL:   10 * time.Second,
	}
	var err error
	if opts.bindPort, err = readEnvRange("PORT", 3000, 1, 65535); err != nil {
		return opts, err
	}
	if opts.loopCount, err = readEnvRange("EPOLL_LOOPS", min(4, max(1, cpus/4)), 1, 16); err != nil {
		return opts, err
	}
	opts.loopCount = min(opts.loopCount, activeCap+queueCap)
	return opts, nil
}

type taskRouter interface {
	startWorkers()
	enqueueTask(ctx *reqCtx) bool
	stopWorkers()
}

type netServer struct {
	opts         pollerOptions
	router       taskRouter
	workers      []*pollWorker
	openConns    atomic.Int64
	pendingBytes atomic.Int64
	listenAddr   string
}

type sockEntry struct {
	gen       uint32
	epMask    uint32
	expireMS  int32
	bufUsed   uint32
	smallSlot int32
	largeSlot int32
	taskSlot  int32
	frameSent uint16
	frameIdx  int8
	stateBits uint8
}

func (s *sockEntry) hasFlag(f uint8) bool { return s.stateBits&f != 0 }
func (s *sockEntry) addFlag(f uint8)      { s.stateBits |= f }
func (s *sockEntry) dropFlag(f uint8)     { s.stateBits &^= f }

type pendingFD struct {
	fd  int32
	gen uint32
}

type reqCtx struct {
	loop     *pollWorker
	nextDone *reqCtx
	slotIdx  int
	sockFD   int
	sockGen  uint32

	inlineBuf []byte
	rawFrame  []byte
	smallSlot int
	largeSlot int
	wire      httpFrame
	req       httpReq

	plan     queryPlan
	queuedAt int64
	canceled uint32

	reply       httpReply
	hdrBuf      [256]byte
	hdrLen      int
	bytesSent   int
	readyToSend bool
	heldBytes   int64
}

type pollWorker struct {
	srv             *netServer
	loopID          int
	epFD, lFD, evFD int
	epEvents        [512]unix.EpollEvent

	table        []sockEntry
	activeBitmap []uint64
	highestFD    int
	bitmapCursor int

	tasks       []reqCtx
	freeTasks   []int
	inUseTasks  int
	doneStack   atomic.Pointer[reqCtx]
	wakePending atomic.Bool

	smallPool, largePool []byte
	freeSmall, freeLarge []int
	scratch              [arenaChunkBytes]byte

	readRing                      []pendingFD
	readHead, readTail, readCount int
	parkRing                      []pendingFD
	parkHead, parkTail, parkCount int

	bootTime           time.Time
	nowMS, nextSweepMS int64
	sweepInterval      time.Duration
	draining           bool
	drainDeadlineMS    int64
	acceptPaused       bool
	retryAcceptMS      int64
	lFDClosed          bool
	staticFrames       [13][]byte
	staticSec          int64
	clockSec           int64
	signer             *tokenSigner
}

func newNetServer(opts pollerOptions, makeRouter func(*netServer) taskRouter) (*netServer, error) {
	if opts.loopCount < 1 || opts.activeCap < 1 || opts.queueCap < 1 || opts.maxSockets < 1 ||
		opts.fdLimit < opts.maxSockets || opts.readTTL <= 0 || opts.writeTTL <= 0 || opts.idleTTL <= 0 {
		return nil, errors.New("invalid poller configuration")
	}
	opts.loopCount = min(opts.loopCount, opts.activeCap+opts.queueCap)
	srv := &netServer{opts: opts}
	teardown := func() {
		for _, pw := range srv.workers {
			pw.closeFDs()
		}
	}

	slotTotal := opts.activeCap + opts.queueCap
	for id := 0; id < opts.loopCount; id++ {
		lfd, actualPort, err := createListenerFD(opts.bindHost, opts.bindPort, opts.loopCount > 1)
		if err != nil {
			teardown()
			return nil, err
		}
		opts.bindPort = actualPort
		pw := &pollWorker{
			srv:       srv,
			loopID:    id,
			lFD:       lfd,
			epFD:      -1,
			evFD:      -1,
			bootTime:  time.Now(),
			staticSec: -1,
			clockSec:  -1,
		}
		pw.staticFrames[0] = http100Bytes
		srv.workers = append(srv.workers, pw)

		if pw.epFD, err = unix.EpollCreate1(unix.EPOLL_CLOEXEC); err != nil {
			teardown()
			return nil, err
		}
		if pw.evFD, err = unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC); err != nil {
			teardown()
			return nil, err
		}
		for _, fd := range [2]int{pw.lFD, pw.evFD} {
			ev := unix.EpollEvent{Events: unix.EPOLLIN, Fd: int32(fd)}
			if err = unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_ADD, fd, &ev); err != nil {
				teardown()
				return nil, err
			}
		}

		loopSlots := slotTotal / opts.loopCount
		if id < slotTotal%opts.loopCount {
			loopSlots++
		}
		initTable := min(opts.fdLimit, 65536)
		pw.table = make([]sockEntry, initTable)
		pw.activeBitmap = make([]uint64, (initTable+63)/64)
		ringSize := min(opts.fdLimit, 131072)
		pw.readRing = make([]pendingFD, ringSize)
		pw.parkRing = make([]pendingFD, ringSize)
		pw.tasks = make([]reqCtx, loopSlots)
		pw.freeTasks = make([]int, loopSlots)

		smallCnt := max(64, 2048/opts.loopCount)
		largeCnt := max(1, 32/opts.loopCount)
		pw.smallPool = make([]byte, smallCnt*arenaChunkBytes)
		pw.largePool = make([]byte, largeCnt*limitFrameBytes)
		pw.freeSmall = make([]int, smallCnt)
		pw.freeLarge = make([]int, largeCnt)
		for i := range pw.freeSmall {
			pw.freeSmall[i] = i
		}
		for i := range pw.freeLarge {
			pw.freeLarge[i] = i
		}

		inlineSlab := make([]byte, loopSlots*inlineFrameCap)
		for i := range pw.tasks {
			pw.freeTasks[i] = i
			pw.tasks[i].loop = pw
			pw.tasks[i].slotIdx = i
			pw.tasks[i].smallSlot = -1
			pw.tasks[i].largeSlot = -1
			pw.tasks[i].inlineBuf = inlineSlab[i*inlineFrameCap : (i+1)*inlineFrameCap]
		}
		pw.sweepInterval = max(time.Millisecond, min(250*time.Millisecond, min(opts.readTTL, min(opts.writeTTL, opts.idleTTL))/2))
	}

	srv.router = makeRouter(srv)
	srv.listenAddr = net.JoinHostPort(opts.bindHost, strconv.Itoa(opts.bindPort))
	return srv, nil
}

func (s *netServer) ListenAddr() string { return s.listenAddr }

func createListenerFD(host string, port int, reusePort bool) (int, int, error) {
	resolved, err := net.ResolveTCPAddr("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return -1, 0, err
	}
	domain := unix.AF_INET
	var bindAddr unix.Sockaddr
	if ip4 := resolved.IP.To4(); ip4 != nil {
		sa := &unix.SockaddrInet4{Port: port}
		copy(sa.Addr[:], ip4)
		bindAddr = sa
	} else {
		domain = unix.AF_INET6
		sa := &unix.SockaddrInet6{Port: port}
		copy(sa.Addr[:], resolved.IP.To16())
		if resolved.Zone != "" {
			netIf, err := net.InterfaceByName(resolved.Zone)
			if err != nil {
				return -1, 0, err
			}
			sa.ZoneId = uint32(netIf.Index)
		}
		bindAddr = sa
	}

	fd, err := unix.Socket(domain, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, 0, err
	}
	cleanup := func(e error) (int, int, error) {
		unix.Close(fd)
		return -1, 0, e
	}
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
		return cleanup(err)
	}
	if reusePort {
		if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); err != nil {
			return cleanup(err)
		}
	}
	_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
	_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_KEEPALIVE, 1)
	_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPIDLE, 60)
	_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPINTVL, 30)
	_ = unix.SetsockoptInt(fd, unix.IPPROTO_TCP, unix.TCP_KEEPCNT, 3)

	if err := unix.Bind(fd, bindAddr); err != nil {
		return cleanup(err)
	}
	if err := unix.Listen(fd, 65535); err != nil {
		return cleanup(err)
	}
	if port == 0 {
		localSA, err := unix.Getsockname(fd)
		if err != nil {
			return cleanup(err)
		}
		switch v := localSA.(type) {
		case *unix.SockaddrInet4:
			port = v.Port
		case *unix.SockaddrInet6:
			port = v.Port
		}
	}
	return fd, port, nil
}

func (s *netServer) Run(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	s.router.startWorkers()

	resCh := make(chan error, len(s.workers))
	stopWait := make(chan struct{})
	waitExited := make(chan struct{})
	go func() {
		defer close(waitExited)
		select {
		case <-runCtx.Done():
			for _, pw := range s.workers {
				pw.signalEventFD()
			}
		case <-stopWait:
		}
	}()
	for _, pw := range s.workers {
		go func() { resCh <- pw.pollLoop(runCtx) }()
	}

	var firstErr error
	for range s.workers {
		if err := <-resCh; err != nil && firstErr == nil {
			firstErr = err
			cancel()
		}
	}
	s.router.stopWorkers()
	close(stopWait)
	<-waitExited
	for _, pw := range s.workers {
		pw.closeFDs()
	}
	return firstErr
}

func (pw *pollWorker) signalEventFD() {
	var val [8]byte
	binary.NativeEndian.PutUint64(val[:], 1)
	for {
		if _, err := unix.Write(pw.evFD, val[:]); err != unix.EINTR {
			return
		}
	}
}

func (pw *pollWorker) closeFDs() {
	if !pw.lFDClosed && pw.lFD >= 0 {
		unix.Close(pw.lFD)
		pw.lFDClosed = true
	}
	if pw.epFD >= 0 {
		unix.Close(pw.epFD)
	}
	if pw.evFD >= 0 {
		unix.Close(pw.evFD)
	}
}

func (pw *pollWorker) activeTask(s *sockEntry) *reqCtx {
	if s.taskSlot < 0 {
		return nil
	}
	return &pw.tasks[s.taskSlot]
}

func (pw *pollWorker) bufferedBytes(s *sockEntry) []byte {
	if s.bufUsed == 0 {
		return nil
	}
	if s.smallSlot >= 0 {
		off := int(s.smallSlot) * arenaChunkBytes
		return pw.smallPool[off : off+int(s.bufUsed) : off+arenaChunkBytes]
	}
	if s.largeSlot >= 0 {
		off := int(s.largeSlot) * limitFrameBytes
		return pw.largePool[off : off+int(s.bufUsed) : off+limitFrameBytes]
	}
	return nil
}

func (pw *pollWorker) growFDTable(fd int) bool {
	if fd < len(pw.table) {
		return true
	}
	if fd >= pw.srv.opts.fdLimit {
		return false
	}
	newLen := len(pw.table)
	for newLen <= fd {
		newLen *= 2
	}
	newLen = min(newLen, pw.srv.opts.fdLimit)
	nextTab := make([]sockEntry, newLen)
	copy(nextTab, pw.table)
	pw.table = nextTab
	nextMap := make([]uint64, (newLen+63)/64)
	copy(nextMap, pw.activeBitmap)
	pw.activeBitmap = nextMap
	return true
}

func (pw *pollWorker) pollLoop(ctx context.Context) error {
	var fatalErr error
	for {
		if fatalErr != nil {
			pw.harvestCompleted()
			if pw.inUseTasks == 0 {
				return fatalErr
			}
			var tmp [8]byte
			_, _ = unix.Read(pw.evFD, tmp[:])
			continue
		}
		timeoutMS := int(pw.sweepInterval / time.Millisecond)
		if pw.doneStack.Load() != nil || pw.readCount > 0 {
			timeoutMS = 0
		}
		cnt, err := unix.EpollWait(pw.epFD, pw.epEvents[:], timeoutMS)
		if err == unix.EINTR {
			continue
		}
		pw.nowMS = time.Since(pw.bootTime).Milliseconds()
		if err != nil {
			fatalErr = err
			pw.initiateDrain(true)
			continue
		}
		if ctx.Err() != nil && !pw.draining {
			pw.initiateDrain(false)
		}

		for i := 0; i < cnt; i++ {
			ev := pw.epEvents[i]
			fd := int(ev.Fd)
			if fd == pw.evFD {
				var tmp [8]byte
				for {
					if _, e := unix.Read(fd, tmp[:]); e != unix.EINTR {
						break
					}
				}
				pw.harvestCompleted()
				continue
			}
			if fd == pw.lFD {
				if !pw.draining {
					pw.acceptConns()
				}
				continue
			}
			if fd < 0 || fd >= len(pw.table) {
				continue
			}
			s := &pw.table[fd]
			if !s.hasFlag(flagActive) || s.gen != uint32(ev.Pad) {
				continue
			}
			if ev.Events&(unix.EPOLLERR|unix.EPOLLHUP) != 0 {
				pw.dropConn(fd)
				continue
			}
			if ev.Events&unix.EPOLLRDHUP != 0 {
				s.addFlag(flagHalfClosed)
			}
			if s.taskSlot < 0 && s.frameIdx < 0 {
				if ev.Events&(unix.EPOLLIN|unix.EPOLLRDHUP) != 0 {
					pw.readIn(fd)
				}
				continue
			}
			t := pw.activeTask(s)
			if t != nil && !t.readyToSend {
				if ev.Events&unix.EPOLLRDHUP != 0 {
					pw.updateInterest(fd, 0)
				} else if ev.Events&unix.EPOLLIN != 0 {
					pw.updateInterest(fd, unix.EPOLLRDHUP)
				}
				continue
			}
			if ev.Events&unix.EPOLLOUT != 0 {
				pw.writeOut(fd)
			} else if ev.Events&unix.EPOLLRDHUP != 0 {
				pw.updateInterest(fd, unix.EPOLLOUT)
			}
		}

		pw.harvestCompleted()
		pw.processPendingReads()
		if pw.nowMS >= pw.nextSweepMS {
			pw.nextSweepMS = pw.nowMS + pw.sweepInterval.Milliseconds()
			pw.sweepExpired()
		}
		if pw.draining {
			if pw.inUseTasks == 0 {
				return nil
			}
			if pw.nowMS >= pw.drainDeadlineMS {
				topWord := min(len(pw.activeBitmap)-1, pw.highestFD>>6)
				for wIdx := 0; wIdx <= topWord; wIdx++ {
					for bitsWord := pw.activeBitmap[wIdx]; bitsWord != 0; bitsWord &= bitsWord - 1 {
						pw.dropConn((wIdx << 6) | bits.TrailingZeros64(bitsWord))
					}
				}
			}
		} else if pw.acceptPaused && pw.nowMS >= pw.retryAcceptMS && pw.srv.openConns.Load() < int64(pw.srv.opts.maxSockets) {
			pw.acceptPaused = false
			pw.setListenerMask(unix.EPOLLIN)
		}
	}
}

func (pw *pollWorker) initiateDrain(abortInFlight bool) {
	if !pw.draining {
		pw.draining = true
		pw.drainDeadlineMS = pw.nowMS + pw.srv.opts.drainTTL.Milliseconds()
		pw.lFDClosed = true
		_ = unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_DEL, pw.lFD, nil)
		_ = unix.Close(pw.lFD)
	}
	topWord := min(len(pw.activeBitmap)-1, pw.highestFD>>6)
	for wIdx := 0; wIdx <= topWord; wIdx++ {
		for bitsWord := pw.activeBitmap[wIdx]; bitsWord != 0; bitsWord &= bitsWord - 1 {
			fd := (wIdx << 6) | bits.TrailingZeros64(bitsWord)
			s := &pw.table[fd]
			if s.hasFlag(flagActive) && (abortInFlight || s.taskSlot < 0) {
				pw.dropConn(fd)
			}
		}
	}
}

func (pw *pollWorker) setListenerMask(mask uint32) {
	_ = unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_MOD, pw.lFD, &unix.EpollEvent{Events: mask, Fd: int32(pw.lFD)})
}

func (pw *pollWorker) updateInterest(fd int, mask uint32) {
	s := &pw.table[fd]
	if !s.hasFlag(flagActive) {
		return
	}
	if s.hasFlag(flagHalfClosed) {
		mask &^= unix.EPOLLRDHUP
	}
	if s.epMask == mask {
		return
	}
	ev := unix.EpollEvent{Events: mask, Fd: int32(fd), Pad: int32(s.gen)}
	if unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_MOD, fd, &ev) != nil {
		pw.dropConn(fd)
	} else {
		s.epMask = mask
	}
}

func (pw *pollWorker) acceptConns() {
	for range 256 {
		if pw.srv.openConns.Load() >= int64(pw.srv.opts.maxSockets) {
			pw.acceptPaused = true
			pw.setListenerMask(0)
			return
		}
		fd, _, err := unix.Accept4(pw.lFD, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
		if err != nil {
			if err == unix.EINTR || err == unix.ECONNABORTED {
				continue
			}
			if err == unix.EMFILE || err == unix.ENFILE {
				pw.acceptPaused = true
				pw.retryAcceptMS = pw.nowMS + 1000
				pw.setListenerMask(0)
			}
			return
		}
		if !pw.growFDTable(fd) {
			unix.Close(fd)
			continue
		}
		reserved := false
		for {
			cur := pw.srv.openConns.Load()
			if cur >= int64(pw.srv.opts.maxSockets) {
				break
			}
			if pw.srv.openConns.CompareAndSwap(cur, cur+1) {
				reserved = true
				break
			}
		}
		if !reserved {
			unix.Close(fd)
			pw.acceptPaused = true
			pw.setListenerMask(0)
			return
		}
		if fd > pw.highestFD {
			pw.highestFD = fd
		}
		pw.activeBitmap[fd>>6] |= uint64(1) << (uint(fd) & 63)
		s := &pw.table[fd]
		nextGen := s.gen + 1
		*s = sockEntry{
			gen:       nextGen,
			epMask:    unix.EPOLLIN | unix.EPOLLRDHUP,
			expireMS:  int32(pw.nowMS + pw.srv.opts.readTTL.Milliseconds()),
			smallSlot: -1,
			largeSlot: -1,
			taskSlot:  -1,
			frameIdx:  -1,
			stateBits: flagActive,
		}
		ev := unix.EpollEvent{Events: s.epMask, Fd: int32(fd), Pad: int32(nextGen)}
		if unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_ADD, fd, &ev) != nil {
			pw.dropConn(fd)
		}
	}
}

func (pw *pollWorker) readIn(fd int) {
	s := &pw.table[fd]
	if !s.hasFlag(flagActive) || s.taskSlot >= 0 || s.frameIdx >= 0 {
		return
	}
	if len(pw.freeTasks) == 0 {
		pw.parkConn(fd)
		return
	}
	var slice []byte
	if s.bufUsed > 0 {
		slice = pw.bufferedBytes(s)
		var parsed httpFrame
		if frameLen := scanHTTPFrame(slice, &parsed); frameLen != 0 {
			pw.activateTask(fd, slice, frameLen, parsed)
			return
		}
	}
	n, err := unix.Read(fd, pw.scratch[:])
	if err == unix.EINTR {
		return
	}
	if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
		pw.updateInterest(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
		return
	}
	if err != nil {
		pw.dropConn(fd)
		return
	}
	if n == 0 {
		if s.bufUsed > 0 {
			pw.sendStaticError(fd, 400, true, false)
		} else {
			pw.dropConn(fd)
		}
		return
	}
	if s.bufUsed == 0 {
		s.expireMS = int32(pw.nowMS + pw.srv.opts.readTTL.Milliseconds())
		slice = pw.scratch[:n]
	} else {
		if !pw.appendToBuffer(s, pw.scratch[:n]) {
			pw.sendStaticError(fd, 503, true, false)
			return
		}
		slice = pw.bufferedBytes(s)
	}
	var parsed httpFrame
	if frameLen := scanHTTPFrame(slice, &parsed); frameLen != 0 {
		pw.activateTask(fd, slice, frameLen, parsed)
		return
	}
	if s.bufUsed == 0 && !pw.appendToBuffer(s, slice) {
		pw.sendStaticError(fd, 503, true, false)
		return
	}
	if parsed.parsedHeaders && parsed.wantsContinue && !s.hasFlag(flagSent100) {
		s.addFlag(flagSent100 | flagSending100)
		s.frameIdx = 0
		s.frameSent = 0
		pw.writeOut(fd)
		return
	}
	pw.updateInterest(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
}

func (pw *pollWorker) activateTask(fd int, raw []byte, frameLen int, parsed httpFrame) {
	s := &pw.table[fd]
	if frameLen < 0 {
		pw.sendStaticError(fd, -frameLen, true, parsed.isHead)
		return
	}
	if len(pw.freeTasks) == 0 {
		if !pw.discardConsumed(s, raw, frameLen) {
			pw.sendStaticError(fd, 503, true, parsed.isHead)
			return
		}
		pw.sendStaticError(fd, 503, parsed.shouldClose, parsed.isHead)
		return
	}
	idx := pw.freeTasks[len(pw.freeTasks)-1]
	pw.freeTasks = pw.freeTasks[:len(pw.freeTasks)-1]
	t := &pw.tasks[idx]
	t.plan.clearState()
	t.nextDone = nil
	t.sockFD = fd
	t.sockGen = s.gen
	t.smallSlot = -1
	t.largeSlot = -1
	t.queuedAt = clockNano()
	t.canceled = 0
	t.reply = httpReply{}
	t.hdrLen = 0
	t.bytesSent = 0
	t.readyToSend = false
	t.heldBytes = 0

	if frameLen <= len(t.inlineBuf) {
		t.rawFrame = t.inlineBuf[:frameLen]
		copy(t.rawFrame, raw[:frameLen])
		remapHTTPFrame(&t.wire, t.rawFrame, raw, parsed)
		if !pw.discardConsumed(s, raw, frameLen) {
			pw.freeTasks = append(pw.freeTasks, idx)
			pw.sendStaticError(fd, 503, true, parsed.isHead)
			return
		}
	} else if s.smallSlot >= 0 {
		t.smallSlot = int(s.smallSlot)
		t.rawFrame = raw[:frameLen]
		t.wire = parsed
		leftover := raw[frameLen:]
		s.bufUsed = 0
		s.smallSlot = -1
		if len(leftover) > 0 && !pw.appendToBuffer(s, leftover) {
			pw.freeSmall = append(pw.freeSmall, t.smallSlot)
			t.smallSlot = -1
			pw.freeTasks = append(pw.freeTasks, idx)
			pw.sendStaticError(fd, 503, true, parsed.isHead)
			return
		}
	} else if s.largeSlot >= 0 {
		t.largeSlot = int(s.largeSlot)
		t.rawFrame = raw[:frameLen]
		t.wire = parsed
		leftover := raw[frameLen:]
		s.bufUsed = 0
		s.largeSlot = -1
		s.smallSlot = -1
		if len(leftover) > 0 && !pw.appendToBuffer(s, leftover) {
			pw.freeLarge = append(pw.freeLarge, t.largeSlot)
			t.largeSlot = -1
			pw.freeTasks = append(pw.freeTasks, idx)
			pw.sendStaticError(fd, 503, true, parsed.isHead)
			return
		}
	} else {
		if frameLen <= arenaChunkBytes && len(pw.freeSmall) > 0 {
			sm := pw.freeSmall[len(pw.freeSmall)-1]
			pw.freeSmall = pw.freeSmall[:len(pw.freeSmall)-1]
			t.smallSlot = sm
			off := sm * arenaChunkBytes
			t.rawFrame = pw.smallPool[off : off+frameLen]
			copy(t.rawFrame, raw[:frameLen])
		} else {
			t.rawFrame = append([]byte(nil), raw[:frameLen]...)
		}
		remapHTTPFrame(&t.wire, t.rawFrame, raw, parsed)
		if !pw.discardConsumed(s, raw, frameLen) {
			if t.smallSlot >= 0 {
				pw.freeSmall = append(pw.freeSmall, t.smallSlot)
				t.smallSlot = -1
			}
			pw.freeTasks = append(pw.freeTasks, idx)
			pw.sendStaticError(fd, 503, true, parsed.isHead)
			return
		}
	}

	s.taskSlot = int32(idx)
	s.dropFlag(flagSent100)
	s.expireMS = int32(pw.nowMS + 23000)
	pw.inUseTasks++
	if !pw.srv.router.enqueueTask(t) {
		t.readyToSend = true
		finishWith(t, 503, msgServerBusy)
		t.hdrLen = len(writeHTTPHeader(t.hdrBuf[:0], &t.reply, t.wire.shouldClose, t.wire.isHTTP10))
		pw.writeOut(fd)
	} else if t.readyToSend {
		pw.startReply(t)
	}
}

func (pw *pollWorker) discardConsumed(s *sockEntry, raw []byte, count int) bool {
	leftover := raw[count:]
	if len(leftover) == 0 {
		pw.freeConnBuffers(s)
		return true
	}
	if s.bufUsed > 0 {
		buf := pw.bufferedBytes(s)
		copy(buf[:cap(buf)], leftover)
		s.bufUsed = uint32(len(leftover))
		return true
	}
	return pw.appendToBuffer(s, leftover)
}

func (pw *pollWorker) appendToBuffer(s *sockEntry, data []byte) bool {
	curUsed := int(s.bufUsed)
	if len(data) > limitFrameBytes-curUsed {
		return false
	}
	curBuf := pw.bufferedBytes(s)
	if cap(curBuf)-curUsed < len(data) {
		var nextBuf []byte
		smIdx, lgIdx := -1, -1
		if curUsed+len(data) <= arenaChunkBytes && len(pw.freeSmall) > 0 {
			smIdx = pw.freeSmall[len(pw.freeSmall)-1]
			pw.freeSmall = pw.freeSmall[:len(pw.freeSmall)-1]
			off := smIdx * arenaChunkBytes
			nextBuf = pw.smallPool[off : off : off+arenaChunkBytes]
		}
		if nextBuf == nil && len(pw.freeLarge) > 0 {
			lgIdx = pw.freeLarge[len(pw.freeLarge)-1]
			pw.freeLarge = pw.freeLarge[:len(pw.freeLarge)-1]
			off := lgIdx * limitFrameBytes
			nextBuf = pw.largePool[off : off : off+limitFrameBytes]
		}
		if nextBuf == nil {
			return false
		}
		copy(nextBuf[:curUsed], curBuf)
		pw.freeConnBuffers(s)
		s.smallSlot = int32(smIdx)
		s.largeSlot = int32(lgIdx)
		curBuf = nextBuf
	}
	expanded := curBuf[:curUsed+len(data)]
	copy(expanded[curUsed:], data)
	s.bufUsed = uint32(curUsed + len(data))
	return true
}

func (pw *pollWorker) freeConnBuffers(s *sockEntry) {
	if s.smallSlot >= 0 {
		pw.freeSmall = append(pw.freeSmall, int(s.smallSlot))
	}
	if s.largeSlot >= 0 {
		pw.freeLarge = append(pw.freeLarge, int(s.largeSlot))
	}
	s.bufUsed = 0
	s.smallSlot = -1
	s.largeSlot = -1
}

func unpackTaskRequest(t *reqCtx) bool {
	wf := &t.wire
	if len(wf.verb) == 0 {
		if scanHTTPFrame(t.rawFrame, wf) <= 0 {
			finishWith(t, 400, msgBadRequest)
			t.wire.shouldClose = true
			return false
		}
	}
	t.req = httpReq{authHeader: wf.authVal, authCount: wf.authHeaders, body: wf.payload}
	t.req.bindURI(wf.verb, wf.uri)
	if wf.isChunked {
		t.req.body = unpackChunkedBody(wf.payload)
	}
	return true
}

func (pw *pollWorker) recycleTask(t *reqCtx) {
	if t.smallSlot >= 0 {
		pw.freeSmall = append(pw.freeSmall, t.smallSlot)
		t.smallSlot = -1
	}
	if t.largeSlot >= 0 {
		pw.freeLarge = append(pw.freeLarge, t.largeSlot)
		t.largeSlot = -1
	}
	if t.heldBytes != 0 {
		pw.srv.pendingBytes.Add(-t.heldBytes)
		t.heldBytes = 0
	}
	t.reply = httpReply{}
	t.req = httpReq{}
	t.rawFrame = nil
	pw.freeTasks = append(pw.freeTasks, t.slotIdx)
	pw.inUseTasks--
	pw.resumeParkedConn()
}

func (pw *pollWorker) parkConn(fd int) {
	s := &pw.table[fd]
	if s.hasFlag(flagWaitingSlot) {
		return
	}
	if pw.parkCount == len(pw.parkRing) {
		pw.dropConn(fd)
		return
	}
	s.addFlag(flagWaitingSlot)
	pw.updateInterest(fd, 0)
	s.expireMS = max(s.expireMS, int32(pw.nowMS+slotWaitTTL.Milliseconds()))
	pw.parkRing[pw.parkTail] = pendingFD{int32(fd), s.gen}
	pw.parkTail = (pw.parkTail + 1) % len(pw.parkRing)
	pw.parkCount++
}

func (pw *pollWorker) resumeParkedConn() {
	for pw.parkCount > 0 {
		entry := pw.parkRing[pw.parkHead]
		pw.parkHead = (pw.parkHead + 1) % len(pw.parkRing)
		pw.parkCount--
		s := &pw.table[entry.fd]
		if !s.hasFlag(flagActive) || s.gen != entry.gen || !s.hasFlag(flagWaitingSlot) {
			continue
		}
		s.dropFlag(flagWaitingSlot)
		pw.enqueuePendingRead(int(entry.fd))
		return
	}
}

func (s *netServer) formatTaskHeader(t *reqCtx) {
	bodyLen := int64(len(t.reply.payload))
	if bodyLen > maxRetainedBytes {
		for {
			cur := s.pendingBytes.Load()
			if bodyLen > 16<<20 || cur+bodyLen > 256<<20 {
				finishWith(t, 503, msgServerBusy)
				bodyLen = int64(len(t.reply.payload))
				break
			}
			if s.pendingBytes.CompareAndSwap(cur, cur+bodyLen) {
				t.heldBytes = bodyLen
				break
			}
		}
	}
	t.hdrLen = len(writeHTTPHeader(t.hdrBuf[:0], &t.reply, t.wire.shouldClose, t.wire.isHTTP10))
}

func (s *netServer) completeInline(t *reqCtx) {
	s.formatTaskHeader(t)
	t.readyToSend = true
}

func (pw *pollWorker) pushCompleted(head, tail *reqCtx) {
	for {
		curHead := pw.doneStack.Load()
		tail.nextDone = curHead
		if pw.doneStack.CompareAndSwap(curHead, head) {
			if pw.wakePending.CompareAndSwap(false, true) {
				pw.signalEventFD()
			}
			return
		}
	}
}

func (s *netServer) completeAsync(t *reqCtx) {
	s.formatTaskHeader(t)
	t.loop.pushCompleted(t, t)
}

func (s *netServer) completeAsyncBatch(batch []*reqCtx) {
	var first, last [16]*reqCtx
	var loopMask uint16
	for _, t := range batch {
		s.formatTaskHeader(t)
		lid := t.loop.loopID
		if first[lid] == nil {
			t.nextDone = nil
			first[lid] = t
			last[lid] = t
			loopMask |= 1 << lid
		} else {
			t.nextDone = first[lid]
			first[lid] = t
		}
	}
	for i := range s.workers {
		if loopMask&(1<<i) != 0 {
			s.workers[i].pushCompleted(first[i], last[i])
		}
	}
}

func (pw *pollWorker) harvestCompleted() {
	for {
		pw.wakePending.Store(false)
		top := pw.doneStack.Swap(nil)
		if top == nil {
			return
		}
		var ordered *reqCtx
		for cur := top; cur != nil; {
			nxt := cur.nextDone
			cur.nextDone = ordered
			ordered = cur
			cur = nxt
		}
		for cur := ordered; cur != nil; {
			nxt := cur.nextDone
			cur.nextDone = nil
			pw.startReply(cur)
			cur = nxt
		}
	}
}

func (pw *pollWorker) startReply(t *reqCtx) {
	t.readyToSend = true
	if t.smallSlot >= 0 {
		pw.freeSmall = append(pw.freeSmall, t.smallSlot)
		t.smallSlot = -1
	}
	if t.largeSlot >= 0 {
		pw.freeLarge = append(pw.freeLarge, t.largeSlot)
		t.largeSlot = -1
	}
	t.rawFrame = nil
	t.req = httpReq{}
	s := &pw.table[t.sockFD]
	if !s.hasFlag(flagActive) || s.gen != t.sockGen || int(s.taskSlot) != t.slotIdx {
		pw.recycleTask(t)
		return
	}
	s.expireMS = int32(pw.nowMS + pw.srv.opts.writeTTL.Milliseconds())
	pw.writeOut(t.sockFD)
}

func (pw *pollWorker) writeOut(fd int) {
	s := &pw.table[fd]
	if !s.hasFlag(flagActive) {
		return
	}
	var chunks [2][]byte
	var targetLen, offset int
	var t *reqCtx
	if s.frameIdx >= 0 {
		staticBuf := pw.staticFrames[s.frameIdx]
		offset = int(s.frameSent)
		chunks[0] = staticBuf[offset:]
		targetLen = len(staticBuf)
	} else {
		t = pw.activeTask(s)
		if t == nil || !t.readyToSend {
			return
		}
		offset = t.bytesSent
		body := t.reply.payload
		if t.wire.isHead {
			body = nil
		}
		targetLen = t.hdrLen + len(body)
		if offset < t.hdrLen {
			chunks[0] = t.hdrBuf[offset:t.hdrLen]
			chunks[1] = body
		} else {
			chunks[0] = body[offset-t.hdrLen:]
		}
	}

	var wrote int
	var err error
	for {
		wrote, err = unix.SendmsgBuffers(fd, chunks[:], nil, nil, unix.MSG_NOSIGNAL)
		if err != unix.EINTR {
			break
		}
	}
	if wrote > 0 {
		offset += wrote
	}
	if s.frameIdx >= 0 {
		s.frameSent = uint16(offset)
	} else {
		t.bytesSent = offset
	}
	if err != nil && err != unix.EAGAIN && err != unix.EWOULDBLOCK {
		pw.dropConn(fd)
		return
	}
	if offset < targetLen {
		pw.updateInterest(fd, unix.EPOLLOUT|unix.EPOLLRDHUP)
		return
	}
	if s.frameIdx >= 0 {
		s.frameIdx = -1
		s.frameSent = 0
		if s.hasFlag(flagSending100) {
			s.dropFlag(flagSending100)
			pw.updateInterest(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
			return
		}
	} else {
		if t.wire.shouldClose {
			s.addFlag(flagShutting)
		}
		s.taskSlot = -1
		pw.recycleTask(t)
	}
	if s.hasFlag(flagShutting) || pw.draining {
		pw.dropConn(fd)
		return
	}
	if s.bufUsed > 0 || s.hasFlag(flagHalfClosed) {
		s.expireMS = int32(pw.nowMS + pw.srv.opts.readTTL.Milliseconds())
		pw.enqueuePendingRead(fd)
	} else {
		s.expireMS = int32(pw.nowMS + pw.srv.opts.idleTTL.Milliseconds())
		pw.updateInterest(fd, unix.EPOLLIN|unix.EPOLLRDHUP)
	}
}

func (pw *pollWorker) buildStaticErrors() {
	slot := 1
	for _, code := range [4]int{400, 413, 417, 503} {
		for variant := range 3 {
			payload := msgBadRequest
			if code == 503 {
				payload = msgServerBusy
			}
			rep := httpReply{code: code, payload: payload}
			raw := writeHTTPHeader(nil, &rep, variant != 0, false)
			if variant != 2 {
				raw = append(raw, rep.payload...)
			}
			pw.staticFrames[slot] = raw
			slot++
		}
	}
}

func staticErrorOffset(code int) int8 {
	switch code {
	case 413:
		return 4
	case 417:
		return 7
	case 503:
		return 10
	default:
		return 1
	}
}

func (pw *pollWorker) sendStaticError(fd, code int, closeConn, isHead bool) {
	s := &pw.table[fd]
	if closeConn || isHead {
		pw.freeConnBuffers(s)
	}
	s.dropFlag(flagSending100 | flagSent100)
	if closeConn || isHead {
		s.addFlag(flagShutting)
	} else {
		s.dropFlag(flagShutting)
	}
	s.frameSent = 0
	var delta int8
	if closeConn {
		delta = 1
	}
	if isHead {
		delta = 2
	}
	if curSec := pw.nowMS / 1000; pw.staticSec != curSec {
		pw.buildStaticErrors()
		pw.staticSec = curSec
	}
	s.frameIdx = staticErrorOffset(code) + delta
	s.expireMS = int32(pw.nowMS + pw.srv.opts.writeTTL.Milliseconds())
	pw.writeOut(fd)
}

func (pw *pollWorker) enqueuePendingRead(fd int) {
	s := &pw.table[fd]
	if s.hasFlag(flagQueuedRead) {
		return
	}
	if pw.readCount == len(pw.readRing) {
		pw.dropConn(fd)
		return
	}
	s.addFlag(flagQueuedRead)
	pw.readRing[pw.readTail] = pendingFD{int32(fd), s.gen}
	pw.readTail = (pw.readTail + 1) % len(pw.readRing)
	pw.readCount++
}

func (pw *pollWorker) processPendingReads() {
	for range min(64, pw.readCount) {
		entry := pw.readRing[pw.readHead]
		pw.readHead = (pw.readHead + 1) % len(pw.readRing)
		pw.readCount--
		s := &pw.table[entry.fd]
		if !s.hasFlag(flagActive) || s.gen != entry.gen {
			continue
		}
		s.dropFlag(flagQueuedRead)
		if s.taskSlot < 0 && s.frameIdx < 0 {
			pw.readIn(int(entry.fd))
		}
	}
}

func (pw *pollWorker) dropConn(fd int) {
	s := &pw.table[fd]
	if !s.hasFlag(flagActive) {
		return
	}
	pw.activeBitmap[fd>>6] &^= uint64(1) << (uint(fd) & 63)
	_ = unix.EpollCtl(pw.epFD, unix.EPOLL_CTL_DEL, fd, nil)
	_ = unix.Close(fd)
	pw.freeConnBuffers(s)
	if t := pw.activeTask(s); t != nil {
		atomic.StoreUint32(&t.canceled, 1)
		if t.readyToSend {
			pw.recycleTask(t)
		}
	}
	curGen := s.gen
	*s = sockEntry{gen: curGen, smallSlot: -1, largeSlot: -1, taskSlot: -1, frameIdx: -1}
	pw.srv.openConns.Add(-1)
}

func (pw *pollWorker) sweepExpired() {
	if curSec := pw.nowMS / 1000; curSec != pw.clockSec {
		pw.clockSec = curSec
		refreshClockHeader()
	}
	topWord := min(len(pw.activeBitmap)-1, pw.highestFD>>6)
	if topWord < 0 {
		return
	}
	if pw.bitmapCursor > topWord {
		pw.bitmapCursor = 0
	}
	now32 := int32(pw.nowMS)
	stopWord := min(topWord, pw.bitmapCursor+511)
	for wIdx := pw.bitmapCursor; wIdx <= stopWord; wIdx++ {
		for bitsWord := pw.activeBitmap[wIdx]; bitsWord != 0; bitsWord &= bitsWord - 1 {
			fd := (wIdx << 6) | bits.TrailingZeros64(bitsWord)
			s := &pw.table[fd]
			if s.hasFlag(flagActive) && now32 >= s.expireMS {
				pw.dropConn(fd)
			}
		}
	}
	if stopWord >= topWord {
		pw.bitmapCursor = 0
	} else {
		pw.bitmapCursor = stopWord + 1
	}
}
