package conduit

import io.netty.channel.EventLoop

import java.util.concurrent.TimeUnit

/** A diagnostic, on with `-Dconduit.lagMonitor=true`: how long the event loop goes without getting to its tasks. A task
  * reschedules itself 10 ms after each run and measures how much later than that it ran, which is how long the
  * loop was busy or blocked (GC pauses included). Logs every 10 s.
  */
object LagMonitor:
  private val PeriodNanos = 10_000_000L
  private val ReportEveryNanos = 10_000_000_000L

  def start(loop: EventLoop): Unit =
    var last = System.nanoTime()
    var reported = last
    var maxLag = 0L
    var ticks, over10, over50, over100 = 0
    loop.scheduleWithFixedDelay(
      () => {
        val now = System.nanoTime()
        val lag = now - last - PeriodNanos
        last = now
        ticks += 1
        if lag > maxLag then maxLag = lag
        if lag > 10_000_000 then over10 += 1
        if lag > 50_000_000 then over50 += 1
        if lag > 100_000_000 then over100 += 1
        if now - reported >= ReportEveryNanos then
          Log.info(
            "loop lag",
            "loop" -> Thread.currentThread.getName,
            "maxMs" -> math.round(maxLag / 1e5) / 10.0,
            "ticks" -> ticks,
            "over10ms" -> over10,
            "over50ms" -> over50,
            "over100ms" -> over100,
          )
          reported = now
          maxLag = 0
          ticks = 0; over10 = 0; over50 = 0; over100 = 0
      },
      PeriodNanos,
      PeriodNanos,
      TimeUnit.NANOSECONDS,
    )
