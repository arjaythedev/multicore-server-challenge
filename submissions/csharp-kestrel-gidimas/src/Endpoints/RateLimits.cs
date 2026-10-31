namespace Conduit.Endpoints;

public static class RateLimits
{
    /// <summary>
    /// Concurrency limit for endpoints that run bcrypt (register, login). Each hash costs tens of milliseconds of CPU,
    /// so a login spike is capped instead of starving every other request; past the queue, requests get 503.
    /// </summary>
    public const string PasswordHashing = "password-hashing";
}
