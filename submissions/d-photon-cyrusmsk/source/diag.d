/// Rate-limited diagnostics. stderr writes are synchronous and can stall a
/// scheduler, so the first few failures are logged and later ones are sampled.
module conduit.diag;

import core.atomic : atomicOp;
import std.stdio : stderr;

private shared int g_logged;

void logError(string prefix, Throwable error) nothrow
{
    const count = atomicOp!"+="(g_logged, 1);
    if (count > 10 && count % 1000 != 0)
        return;
    try
        stderr.writeln(prefix, error);
    catch (Throwable)
    {
    }
}
