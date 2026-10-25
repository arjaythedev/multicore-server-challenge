using System;

namespace CodeFusion.Security;

/// <summary>Settings of a <see cref="BcryptQueue"/>.</summary>
public sealed class BcryptQueueOptions
{
    /// <summary>
    /// Worker threads. Default: one per processor. That gave the most sign-ins a second on an AMD EPYC and a Google
    /// Axion; on an Intel Xeon with two hyperthreads per core, half as many was 6 to 13% better. Set fewer to leave
    /// CPU for the rest of a server's work.
    /// </summary>
    public int Threads { get; init; } = Environment.ProcessorCount;

    /// <summary>Hashes one worker runs interleaved, 1 to <see cref="Bcrypt.MaxLanes"/>. Default 5.</summary>
    public int Lanes { get; init; } = Bcrypt.MaxLanes;

    /// <summary>
    /// How long a worker that took a hash waits for more to share its run, measured from that hash's arrival. Zero
    /// (the default) runs whatever is waiting at once; hashes still share a run whenever a backlog forms. A window
    /// helps when hashes arrive further apart than one takes: a server with logins tens of milliseconds apart spent
    /// a third of the CPU per login with 200 ms, at the cost of up to that much latency.
    /// </summary>
    public TimeSpan BatchWindow { get; init; } = TimeSpan.Zero;

    /// <summary>
    /// Hashes allowed to wait. Past that a call fails at once with <see cref="BcryptQueueFullException"/>, so an
    /// overload can't build up minutes of queued work. Default (null): 256 per thread, several seconds of work at cost 10.
    /// </summary>
    public int? MaxQueued { get; init; }
}
