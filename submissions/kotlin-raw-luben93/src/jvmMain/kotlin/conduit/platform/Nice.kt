package conduit.platform

import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.ValueLayout
import java.lang.invoke.MethodHandle

/**
 * Per-thread nice value through the FFM API (no JNI, no dependencies). On Linux, nice is a per-thread attribute:
 * setpriority(PRIO_PROCESS, gettid(), n) lowers just the calling thread. Needs --enable-native-access=ALL-UNNAMED;
 * any failure leaves the priority unchanged.
 */
internal object Nice {
    private const val SYS_GETTID = 186L // x86_64
    private const val PRIO_PROCESS = 0

    private val handles: Pair<MethodHandle, MethodHandle>? = try {
        val linker = Linker.nativeLinker()
        val libc = linker.defaultLookup()
        val syscall = linker.downcallHandle(
            libc.find("syscall").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG),
        )
        val setpriority = linker.downcallHandle(
            libc.find("setpriority").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT),
        )
        syscall to setpriority
    } catch (_: Throwable) {
        null
    }

    fun set(nice: Int) {
        val (syscall, setpriority) = handles ?: return
        try {
            val tid = (syscall.invokeWithArguments(SYS_GETTID) as Long).toInt()
            setpriority.invokeWithArguments(PRIO_PROCESS, tid, nice)
        } catch (_: Throwable) {
        }
    }
}
