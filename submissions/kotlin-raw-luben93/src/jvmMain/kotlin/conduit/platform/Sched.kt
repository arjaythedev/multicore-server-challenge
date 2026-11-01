package conduit.platform

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout
import java.lang.invoke.MethodHandle

/**
 * SCHED_BATCH for the JVM, through FFM (as the Native build does): a thread woken by epoll or a futex no longer
 * preempts a running Postgres backend on a saturated box. [batchSelf] covers the threads we start; [startSweep] puts
 * every other thread of the process (G1 workers, the C1/C2 compiler threads, the VM thread) in the class too, once now and
 * once a second after (HotSpot starts those lazily). SCHED_BATCH=0 turns it all off. Any failure leaves the class alone.
 */
internal object Sched {
    private const val SYS_SCHED_SETSCHEDULER = 144L // x86_64
    private const val SCHED_BATCH = 3L

    val enabled: Boolean = System.getenv("SCHED_BATCH")?.trim() != "0"

    private val syscall: MethodHandle? = if (!enabled) null else try {
        val linker = Linker.nativeLinker()
        linker.downcallHandle(
            linker.defaultLookup().find("syscall").orElseThrow(),
            FunctionDescriptor.of(
                ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG,
                ValueLayout.ADDRESS,
            ),
            Linker.Option.firstVariadicArg(1),
        )
    } catch (_: Throwable) {
        null
    }

    /** struct sched_param { int sched_priority = 0 } */
    private val param: MemorySegment = Arena.global().allocate(4)

    private fun set(tid: Long) {
        val h = syscall ?: return
        try {
            h.invokeWithArguments(SYS_SCHED_SETSCHEDULER, tid, SCHED_BATCH, param)
        } catch (_: Throwable) {
        }
    }

    /** The calling thread (tid 0). */
    fun batchSelf() = set(0L)

    private fun sweepOnce(done: HashSet<Int>) {
        val names = java.io.File("/proc/self/task").list() ?: return
        val now = HashSet<Int>(names.size * 2)
        for (n in names) {
            val tid = n.toIntOrNull() ?: continue
            now.add(tid)
            if (done.add(tid)) set(tid.toLong())
        }
        done.retainAll(now)
    }

    fun startSweep() {
        if (syscall == null) return
        val done = HashSet<Int>()
        sweepOnce(done)
        val t = Thread {
            while (true) {
                try {
                    Thread.sleep(1000)
                    sweepOnce(done)
                } catch (_: Throwable) {
                }
            }
        }
        t.name = "sched-sweep"
        t.isDaemon = true
        t.start()
    }
}
