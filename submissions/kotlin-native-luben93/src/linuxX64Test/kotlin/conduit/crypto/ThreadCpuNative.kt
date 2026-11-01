package conduit.crypto

import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import platform.posix.CLOCK_THREAD_CPUTIME_ID
import platform.posix.clock_gettime
import platform.posix.timespec

internal actual fun threadCpuNanos(): Long = memScoped {
    val t = alloc<timespec>()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, t.ptr)
    t.tv_sec * 1_000_000_000L + t.tv_nsec
}
