package conduit.db

import conduit.platform.readTextFile

/**
 * How busy the CPUs this process may run on are (/proc/stat per-CPU lines, restricted to Cpus_allowed_list of
 * /proc/self/status): [sample] is the percentage of the time since the previous call. -1 when the files are unreadable.
 */
internal class BoxCpu {
    private val cpus: Set<Int>? = allowedCpus(readTextFile("/proc/self/status"))
    private var lastBusy = 0L
    private var lastTotal = 0L
    private var primed = false

    fun sample(): Int {
        val text = readTextFile("/proc/stat") ?: return -1
        val (busy, total) = busyAndTotal(text, cpus) ?: return -1
        val db = busy - lastBusy
        val dt = total - lastTotal
        val had = primed
        lastBusy = busy
        lastTotal = total
        primed = true
        if (!had || dt <= 0L) return -1
        return (100 * db / dt).toInt().coerceIn(0, 100)
    }

    companion object {
        /** "Cpus_allowed_list:\t0-7,9" -> {0..7, 9}; null when there is no such line (all CPUs count). */
        fun allowedCpus(status: String?): Set<Int>? {
            val line = status?.lineSequence()?.firstOrNull { it.startsWith("Cpus_allowed_list:") } ?: return null
            val out = HashSet<Int>()
            for (part in line.substringAfter(':').trim().split(',')) {
                val p = part.trim()
                if (p.isEmpty()) continue
                val dash = p.indexOf('-')
                if (dash < 0) out.add(p.toIntOrNull() ?: return null)
                else {
                    val a = p.substring(0, dash).toIntOrNull() ?: return null
                    val b = p.substring(dash + 1).toIntOrNull() ?: return null
                    for (c in a..b) out.add(c)
                }
            }
            return out.takeIf { it.isNotEmpty() }
        }

        /** (busy jiffies, total jiffies) summed over the per-CPU lines of [cpus] (all when null); idle = idle + iowait. */
        fun busyAndTotal(stat: String, cpus: Set<Int>?): Pair<Long, Long>? {
            var busy = 0L
            var total = 0L
            var seen = false
            for (line in stat.lineSequence()) {
                if (!line.startsWith("cpu") || line.length < 4 || !line[3].isDigit()) continue
                val f = line.trim().split(' ').filter { it.isNotEmpty() }
                val id = f[0].substring(3).toIntOrNull() ?: continue
                if (cpus != null && id !in cpus) continue
                if (f.size < 5) continue
                var sum = 0L
                for (i in 1 until minOf(f.size, 9)) sum += f[i].toLongOrNull() ?: 0L // user..steal (guest is inside user)
                val idle = (f[4].toLongOrNull() ?: 0L) + (if (f.size > 5) f[5].toLongOrNull() ?: 0L else 0L)
                total += sum
                busy += sum - idle
                seen = true
            }
            return if (seen) busy to total else null
        }
    }
}

/**
 * READ_GATHER_AUTO (default on): the read gather window ([DbConfig.gatherMicros], the floor) widens in [stepMs] steps
 * towards [maxMs] while the box is busy and narrows again when it is not. A wider window sends bigger batches, and the
 * statements get cheaper per request with batch size (lab, 180k users: Postgres 91 -> 75 -> 69 -> 64 us per request at
 * 30/60/90/120 ms, box CPU 93% -> 80% -> 76% -> 72%); what it costs is latency, which is only worth paying when the CPUs are
 * the bottleneck. Decided once per second from [BoxCpu]: busy >= [highPct] widens, busy <= [lowPct] narrows.
 */
internal class GatherTuner(
    val floorMs: Int,
    val maxMs: Int,
    private val stepMs: Int,
    private val highPct: Int,
    private val lowPct: Int,
) {
    private val cpu = BoxCpu()

    /** The window for the next second given the current one, or [currentMs] when no decision (no sample). */
    fun next(currentMs: Int): Int {
        val busy = cpu.sample()
        return decide(currentMs, busy)
    }

    fun decide(currentMs: Int, busyPct: Int): Int = when {
        busyPct < 0 -> currentMs
        busyPct >= highPct -> minOf(maxMs, currentMs + stepMs)
        busyPct <= lowPct -> maxOf(floorMs, currentMs - stepMs)
        else -> currentMs
    }
}
