package conduit

import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.{FunctionDescriptor, Linker}
import java.lang.invoke.MethodHandle
import java.security.SecureRandom
import java.util.concurrent.{Executor, LinkedBlockingDeque, TimeUnit}
import scala.annotation.static
import scala.util.control.NonFatal

/** Hashes and checks passwords on threads of their own: a bcrypt hash at cost 10 takes ~55 ms of CPU, which would
  * stall every connection of an event loop. The answer goes back to the loop that asked (`loop`).
  *
  * Up to four hashes run at once on a thread, interleaved ([[Bcrypt.crypt4]]): ~15 ms of CPU each instead of ~55. So
  * a lone one waits up to `waitMillis` for others to join it: one thread at a time collects a batch while the others
  * hash theirs. Logins are ~0.1% of the load's requests, so their latency doesn't reach its p99; their CPU goes to
  * Postgres instead.
  *
  * With `nice` above 0 the threads lower their own scheduling priority (Linux's nice value, which a thread may raise
  * for itself without privileges): when the box's CPUs are all busy, a hash waits rather than Postgres or an event
  * loop, whose requests the load's latency limits count.
  */
final class Passwords(threads: Int, waitMillis: Int, nice: Int = 0):
  import Passwords.*

  private val queue = LinkedBlockingDeque[Job]()
  private val collecting = Object()

  for i <- 1 to threads do
    val t = Thread(() => { if nice > 0 then lowerPriority(nice); work() }, s"bcrypt-$i")
    t.setDaemon(true)
    t.start()

  /** A new hash of `password` (at most 72 bytes), given to `done` on `loop`; null if hashing failed. */
  def hash(password: Array[Byte], loop: Executor, done: String => Unit): Unit =
    queue.put(Job(password, null, Bcrypt.Cost, loop, hashed = done, checked = null))

  /** Whether `password` matches the stored hash, given to `done` on `loop`. */
  def check(password: Array[Byte], stored: String, loop: Executor, done: Boolean => Unit): Unit =
    val s = Bcrypt.parse(stored)
    if s == null then loop.execute(() => done(false))
    else queue.put(Job(password, s, s.cost, loop, hashed = null, checked = done))

  private def work(): Unit =
    val random = SecureRandom()
    val batch = new Array[Job](4)
    while true do
      val n = collect(batch)
      try run(batch, n, random)
      catch
        case NonFatal(e) =>
          Log.error("bcrypt failed", e, "hashes" -> n)
          for i <- 0 until n do batch(i).answer(null)
      java.util.Arrays.fill(batch.asInstanceOf[Array[AnyRef]], null)

  /** Takes the next job and up to three more of the same cost into `batch`, waiting up to `waitMillis` for them:
    * their number.
    */
  private def collect(batch: Array[Job]): Int = collecting.synchronized:
    batch(0) = queue.take()
    var n = 1
    val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(waitMillis)
    var more = true
    while more && n < batch.length do
      val left = deadline - System.nanoTime()
      val next = if left > 0 then queue.poll(left, TimeUnit.NANOSECONDS) else queue.poll()
      if next == null then more = false
      else if next.cost != batch(0).cost then
        queue.putFirst(next) // another cost: the next batch's
        more = false
      else
        batch(n) = next
        n += 1
    n

  private def run(batch: Array[Job], n: Int, random: SecureRandom): Unit =
    for i <- 0 until n do if batch(i).stored == null then batch(i).salt = Bcrypt.salt(random)
    if n == 1 then batch(0).answer(Bcrypt.crypt(batch(0).password, batch(0).salt, batch(0).cost))
    else
      // Four lanes; with fewer jobs, the last one fills the rest (they cost no more time, and two or three jobs in
      // four lanes still take less CPU each than one at a time).
      val lanes = Array.tabulate(4)(i => batch(math.min(i, n - 1)))
      val raw = Bcrypt.crypt4(lanes.map(_.password), lanes.map(_.salt), batch(0).cost)
      for i <- 0 until n do batch(i).answer(raw(i))

object Passwords:
  @static private val linker = Linker.nativeLinker()
  /** libc's `gettid` and `setpriority`, or null where there are none (macOS has no `gettid`). */
  @static private val gettid: MethodHandle = downcall("gettid", FunctionDescriptor.of(JAVA_INT))
  @static private val setpriority: MethodHandle = downcall("setpriority", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT))

  private def downcall(name: String, descriptor: FunctionDescriptor): MethodHandle =
    linker.defaultLookup().find(name).map(linker.downcallHandle(_, descriptor)).orElse(null)

  /** Sets this thread's nice value (`setpriority(PRIO_PROCESS, gettid(), nice)`); logs if it can't. */
  private def lowerPriority(nice: Int): Unit =
    val ok =
      if gettid == null || setpriority == null then false
      else
        val tid: Int = gettid.invokeExact().asInstanceOf[Int]
        val result: Int = setpriority.invokeExact(0, tid, nice).asInstanceOf[Int]
        result == 0
    if !ok then Log.warn("couldn't lower the bcrypt thread's priority", "nice" -> nice)

  /** A hash to make (`stored` null: a new salt at [[Bcrypt.Cost]]) or to check against `stored`. */
  private final class Job(
      val password: Array[Byte],
      val stored: Bcrypt.Stored,
      val cost: Int,
      loop: Executor,
      hashed: String => Unit,
      checked: Boolean => Unit,
  ):
    var salt: Array[Byte] = if stored == null then null else stored.salt

    /** Hands the answer for [[Bcrypt.crypt]]'s bytes (null: it failed) to the loop. */
    def answer(computed: Array[Byte]): Unit =
      if stored == null then
        val hash = if computed == null then null else Bcrypt.format(salt, cost, computed)
        loop.execute(() => hashed(hash))
      else
        val ok = computed != null && stored.matches(computed)
        loop.execute(() => checked(ok))
