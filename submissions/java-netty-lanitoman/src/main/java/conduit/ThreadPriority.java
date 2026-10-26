package conduit;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;

/**
 * Lowers the calling thread's CPU priority (its nice value). On Linux, nice belongs to each thread:
 * setpriority(PRIO_PROCESS, gettid(), n) affects only the caller. Called through the Foreign Function API (no JNI);
 * anywhere this fails (not Linux, no native access) the priority simply stays as it is.
 */
public final class ThreadPriority {
    private static final long SYS_GETTID = 186;                // x86-64
    private static final int PRIO_PROCESS = 0;

    private ThreadPriority() {
    }

    /** Sets the calling thread's nice value (0 = normal, 19 = lowest). Returns false if it couldn't. */
    public static boolean setNice(int nice) {
        try {
            Linker linker = Linker.nativeLinker();
            MethodHandle syscall = linker.downcallHandle(linker.defaultLookup().find("syscall").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG));
            MethodHandle setpriority = linker.downcallHandle(linker.defaultLookup().find("setpriority").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT,
                            ValueLayout.JAVA_INT));
            int threadId = (int) (long) syscall.invokeExact(SYS_GETTID);
            return (int) setpriority.invokeExact(PRIO_PROCESS, threadId, nice) == 0;
        } catch (Throwable e) {
            return false;
        }
    }
}
