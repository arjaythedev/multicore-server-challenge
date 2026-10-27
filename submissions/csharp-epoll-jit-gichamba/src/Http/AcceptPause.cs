namespace Conduit.Http;

/// <summary>
/// The pause after accept fails for lack of descriptors. Retrying at once would spin, since the pending connection
/// stays pending; the loop keeps serving its open connections meanwhile. It holds a deadline and answers from the clock
/// value the caller passes in. Used by one loop thread only.
/// </summary>
internal sealed class AcceptPause {
    /// <summary>Pause deadline in clock milliseconds; 0 means no pause.</summary>
    private long _until;

    /// <summary>Starts a pause of <paramref name="ms"/> milliseconds at <paramref name="nowMs"/>.</summary>
    public void Start(long nowMs, int ms) => _until = nowMs + ms;

    /// <summary>True while accepts must be skipped.</summary>
    public bool IsPaused(long nowMs) => _until != 0 && nowMs < _until;

    /// <summary>
    /// True once, when a pause has just ended. The listener is edge-triggered, so the caller must then
    /// accept everything that queued up during the pause.
    /// </summary>
    public bool TakeExpired(long nowMs) {
        if (_until == 0 || nowMs < _until) {
            return false;
        }

        _until = 0;
        return true;
    }

    /// <summary>Milliseconds an epoll wait may sleep before the pause ends, or -1 when there is no pause.</summary>
    public int TimeoutMs(long nowMs) => _until == 0 ? -1 : (int)Math.Max(0, _until - nowMs);
}
