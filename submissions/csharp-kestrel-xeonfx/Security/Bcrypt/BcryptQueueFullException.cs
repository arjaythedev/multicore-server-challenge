using System;

namespace CodeFusion.Security;

/// <summary>
/// A <see cref="BcryptQueue"/> refused a hash because <see cref="BcryptQueueOptions.MaxQueued"/> were already
/// waiting. A server usually answers 503 with Retry-After: the hash would have waited too long anyway.
/// </summary>
public sealed class BcryptQueueFullException : Exception
{
    /// <summary>A queue-full error with the default message.</summary>
    public BcryptQueueFullException() : base("too many bcrypt hashes are waiting") { }

    /// <summary>A queue-full error with <paramref name="message"/>.</summary>
    public BcryptQueueFullException(string message) : base(message) { }

    /// <summary>A queue-full error with <paramref name="message"/> and its cause.</summary>
    public BcryptQueueFullException(string message, Exception innerException) : base(message, innerException) { }
}
