using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;

/// <summary>A client connection, indexed by its fd. <see cref="Gen"/> changes whenever the fd closes, so a reply for
/// a connection that has gone (and maybe come back as another client) is dropped.</summary>
struct Conn
{
    public int Gen;
    /// <summary>A request is waiting on the database or bcrypt; anything that arrives meanwhile waits in <see cref="In"/>.</summary>
    public bool Busy;
    /// <summary>Close once <see cref="Out"/> is sent.</summary>
    public bool CloseAfterSend;
    /// <summary>The client sent all it will (it shut down its side): answer what it asked, then close.</summary>
    public bool PeerDone;
    /// <summary>Reading is paused: <see cref="In"/> is full of requests not answered yet.</summary>
    public bool Paused;
    public byte[]? In;
    public int InLength;
    public byte[]? Out;
    public int OutStart, OutEnd;
}

/// <summary>
/// One thread's event loop: its own listener (SO_REUSEPORT spreads the connections over the loops), its clients, and
/// a share of the Postgres connections. Reads and writes from every loop wait in the <see cref="Hub"/>'s queues and run
/// on whichever loop's connection is idle; the answer comes back to the loop holding the client through its inbox, a
/// lock-free stack with an eventfd to wake it. Loop.Http.cs serves the clients, Loop.Routes.cs checks requests and
/// queues them, Loop.Batch.cs runs read batches, Loop.Postgres.cs write groups and the connections, Loop.Replies.cs
/// turns rows into JSON.
/// </summary>
sealed unsafe partial class Loop
{
    public static Conn[] Conns = [];

    // an epoll event's data is the client's fd, or one of these tags (plus the Postgres connection's index)
    const ulong ListenerTag = 1UL << 40, PgTag = 2UL << 40, WakeTag = 3UL << 40;
    /// <summary>The largest request: 1 MB of body and its head. More is answered 413.</summary>
    const int MaxRequest = (1 << 20) + (32 << 10);
    const uint ClientEvents = Native.EpollIn | Native.EpollRdHup;
    /// <summary>The response's body is written from here; its head goes just before it, so both leave in one send.</summary>
    internal const int HeadRoom = 256;
    /// <summary>Connections taken per listener wake-up, so a burst of connects can't starve the loop's clients.</summary>
    const int MaxAccepts = 256;

    readonly Hub _hub;
    readonly int _epfd, _wakeFd;
    readonly Socket _listener;
    /// <summary>The readers, then the writers.</summary>
    readonly Pg[] _pgs;
    readonly int _readers;
    readonly bool[] _pgWatchingOut;
    readonly byte[] _receive = new byte[MaxRequest];
    byte[] _response = new byte[256 << 10];
    /// <summary>Unescaped body fields, and decoded query values and paths.</summary>
    byte[] _scratch = new byte[64 << 10];
    readonly Stack<Job> _spareJobs = new();
    /// <summary>Reads or writes went back in the queue after a failure: they have waited already, so they leave this pass.</summary>
    bool _hurry;

    /// <summary>This loop's idle readers and writers as of its last pass, for <see cref="Hub"/> to pick a loop to wake.</summary>
    public int IdleReaders, IdleWriters;
    /// <summary>Jobs handed back by other loops and the bcrypt threads, newest first, linked through Job.InboxNext.</summary>
    Job? _inbox;
    /// <summary>1 while the eventfd has been signalled and the loop hasn't woken for it yet.</summary>
    int _wakePending;

    public Loop(Hub hub, int index, string host, int port, PgSettings db, int readers, int writers)
    {
        _hub = hub;
        _epfd = Native.epoll_create1(0);
        if (_epfd < 0) throw new InvalidOperationException("epoll_create1 failed");
        var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        s.SetRawSocketOption(Native.SolSocket, Native.SoReusePort, BitConverter.GetBytes(1));
        s.Bind(new IPEndPoint(IPAddress.Parse(host), port));
        s.Listen(65535); // the kernel caps it at net.core.somaxconn
        s.Blocking = false;
        _listener = s;
        Native.Watch(_epfd, Native.EpollCtlAdd, (int)s.Handle, Native.EpollIn, ListenerTag);
        _wakeFd = Native.EventFd();
        Native.Watch(_epfd, Native.EpollCtlAdd, _wakeFd, Native.EpollIn, WakeTag);
        _readers = readers;
        _pgs = new Pg[readers + writers];
        _pgWatchingOut = new bool[_pgs.Length];
        for (int i = 0; i < _pgs.Length; i++)
        {
            _pgs[i] = new Pg(db, writer: i >= readers);
            Reconnect(i);
        }
    }

    public void Run()
    {
        const int MaxEvents = 1024;
        EpollEvent* events = stackalloc EpollEvent[MaxEvents];
        long wait = WaitNanos(long.MaxValue, 0, AnyBroken());
        while (true)
        {
            int n = Native.EpollWait(_epfd, events, MaxEvents, wait);
            for (int i = 0; i < n; i++)
            {
                ulong data = events[i].Data;
                uint ready = events[i].Events;
                if (data >= WakeTag) OnWake();
                else if (data >= PgTag) OnPg((int)(data - PgTag), ready);
                else if (data >= ListenerTag) OnListener();
                else OnClient((int)data, ready);
            }
            long now = Stopwatch.GetTimestamp();
            long due = Pass(now);
            wait = WaitNanos(due, now, AnyBroken());
        }
    }

    /// <summary>
    /// The end of every pass: idle connections take what waits in the hub (a read batch once its oldest read has
    /// waited Hub.BatchWindow, a write group after Hub.GroupWindow), what was queued is sent, dropped connections
    /// come back. Returns when waiting work will be due (long.MaxValue: none).
    /// </summary>
    long Pass(long now)
    {
        // published before taking, so a loop that queues meanwhile either sees an idle connection here and wakes
        // this loop, or queued before the take below (Hub fences between its queueing and its read of these)
        Publish();
        long due = long.MaxValue;
        for (int i = 0; i < _readers; i++)
            if (_pgs[i].Idle && !StartBatch(_pgs[i], now, ref due)) break;
        for (int i = _readers; i < _pgs.Length; i++)
            if (_pgs[i].Idle && !StartGroup(_pgs[i], now, ref due)) break;
        _hurry = false;
        if (Volatile.Read(ref _hub.LiveReaders) == 0 && _hub.ReadsWaiting > 0)
        {
            _taken.Clear();
            _hub.TakeAllReads(_taken);
            foreach (Job job in _taken) AnswerError(job, 503, Errors.DatabaseBusy);
            _taken.Clear();
        }
        if (Volatile.Read(ref _hub.LiveWriters) == 0 && _hub.WritesWaiting > 0)
        {
            // writes wait for a writer to reconnect, then fail
            _taken.Clear();
            _hub.TakeWritesQueuedBefore(now - Hub.DownWaitMs * Stopwatch.Frequency / 1000, _taken);
            foreach (Job job in _taken) AnswerError(job, 503, Errors.DatabaseBusy);
            _taken.Clear();
            due = Math.Min(due, now + Stopwatch.Frequency / 10);
        }
        for (int i = 0; i < _pgs.Length; i++) FlushPg(i);
        for (int i = 0; i < _pgs.Length; i++)
        {
            Pg pg = _pgs[i];
            if (pg.Connecting && Environment.TickCount64 >= pg.ConnectDeadline)
            {
                Console.Error.WriteLine("postgres: connection timed out");
                pg.Close();
            }
            else if (pg.Broken && !pg.Connecting && Environment.TickCount64 >= pg.RetryAt) Reconnect(i);
        }
        Publish();
        return due;
    }

    void Publish()
    {
        int r = 0, w = 0;
        for (int i = 0; i < _pgs.Length; i++)
            if (_pgs[i].Idle)
            {
                if (i < _readers) r++;
                else w++;
            }
        Interlocked.Exchange(ref IdleReaders, r);
        Interlocked.Exchange(ref IdleWriters, w);
    }

    /// <summary>How long the next epoll wait may sleep, in nanoseconds: until <paramref name="due"/> (a Stopwatch
    /// timestamp; long.MaxValue for no deadline), and a second at most while a Postgres connection is down so it
    /// reconnects. -1 waits for events only.</summary>
    internal static long WaitNanos(long due, long now, bool broken)
    {
        long nanos = -1;
        if (due != long.MaxValue)
        {
            long ticks = Math.Clamp(due - now, 0, Stopwatch.Frequency);
            nanos = (ticks * 1_000_000_000 + Stopwatch.Frequency - 1) / Stopwatch.Frequency;
        }
        if (broken && (nanos < 0 || nanos > 1_000_000_000)) nanos = 1_000_000_000;
        return nanos;
    }

    // ---- the inbox

    /// <summary>Wakes the loop from its epoll wait (any thread); one signal until it has woken.</summary>
    public void Wake()
    {
        if (Interlocked.Exchange(ref _wakePending, 1) == 0) Native.Signal(_wakeFd);
    }

    /// <summary>Hands a job back to this loop (any thread).</summary>
    void Deliver(Job job, byte mail)
    {
        job.Mail = mail;
        Job? head;
        do
        {
            head = Volatile.Read(ref _inbox);
            job.InboxNext = head;
        } while (Interlocked.CompareExchange(ref _inbox, job, head) != head);
        Wake();
    }

    /// <summary>Called on a bcrypt thread: the job's hash or check is done.</summary>
    public void Hashed(Job job) => Deliver(job, Job.Hashed);

    void OnWake()
    {
        Native.Drain(_wakeFd);
        Volatile.Write(ref _wakePending, 0);
        Job? taken = Interlocked.Exchange(ref _inbox, null);
        // the stack is newest first; answer in the order they came
        Job? fifo = null;
        while (taken != null)
        {
            Job next = taken.InboxNext!;
            taken.InboxNext = fifo;
            fifo = taken;
            taken = next;
        }
        while (fifo != null)
        {
            Job job = fifo;
            fifo = job.InboxNext;
            job.InboxNext = null;
            if (job.Mail == Job.Hashed) AfterBcrypt(job);
            else Delivered(job);
        }
    }

    /// <summary>Another loop's answer to one of this loop's clients: sent as written there.</summary>
    void Delivered(Job job)
    {
        int fd = job.Fd;
        if (job.Status != 0 && Conns[fd].Gen == job.Gen)
        {
            Conns[fd].Busy = false;
            Respond(fd, job.Status, job.Out, job.OutEnd);
            Resume(fd, job.Gen);
        }
        Spare(job);
    }

    /// <summary>
    /// Answers a job with the body at [HeadRoom, <paramref name="end"/>) of this loop's response buffer: sent here when
    /// the client is this loop's, else copied into the job and handed to its loop. The job goes spare either way.
    /// </summary>
    void Answer(Job job, int status, int end)
    {
        if (job.Owner == this)
        {
            int fd = job.Fd;
            if (Conns[fd].Gen == job.Gen)
            {
                Conns[fd].Busy = false;
                Respond(fd, status, end);
                Resume(fd, job.Gen);
            }
            Spare(job);
            return;
        }
        if (job.Closed) status = 0; // nothing worth copying; its loop just spares it
        else job.SetOut(_response, HeadRoom, end);
        job.Status = status;
        job.Owner.Deliver(job, Job.Answered);
    }

    /// <summary>Answers a job with a whole body, such as one of <see cref="Errors"/>.</summary>
    void AnswerError(Job job, int status, ReadOnlySpan<byte> body)
    {
        int at = HeadRoom;
        Json.Raw(Room(at, body.Length), ref at, body);
        Answer(job, status, at);
    }

    /// <summary>A job whose client has gone: back to its loop's spares.</summary>
    void Discard(Job job)
    {
        if (job.Owner == this) Spare(job);
        else
        {
            job.Status = 0;
            job.Owner.Deliver(job, Job.Answered);
        }
    }

    /// <summary>A job for the request, reused from <see cref="_spareJobs"/> when one is there; the connection waits
    /// on it from now on.</summary>
    Job NewJob(int fd, byte kind, long viewer)
    {
        Job job = _spareJobs.Count > 0 ? _spareJobs.Pop() : new Job { Owner = this };
        job.Reset();
        job.Fd = fd;
        job.Gen = Conns[fd].Gen;
        job.Kind = kind;
        job.Viewer = viewer;
        Conns[fd].Busy = true;
        return job;
    }

    void Spare(Job job) => _spareJobs.Push(job);

    /// <summary>The response buffer with room for <paramref name="need"/> bytes from <paramref name="at"/>.</summary>
    internal byte[] Room(int at, int need)
    {
        if (_response.Length - at < need) Array.Resize(ref _response, Math.Max(_response.Length * 2, at + need));
        return _response;
    }

    /// <summary>The scratch buffer, at least <paramref name="need"/> bytes.</summary>
    byte[] Scratch(int need)
    {
        if (_scratch.Length < need) _scratch = new byte[Math.Max(need, _scratch.Length * 2)];
        return _scratch;
    }
}
