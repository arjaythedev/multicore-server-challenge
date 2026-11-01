package conduit.crypto

import java.lang.management.ManagementFactory

internal actual fun threadCpuNanos(): Long = ManagementFactory.getThreadMXBean().currentThreadCpuTime
