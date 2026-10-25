package conduit

import io.netty.channel.{IoHandler, IoHandlerFactory}
import io.netty.util.concurrent.ThreadAwareExecutor
import io.netty.util.collection.IntObjectHashMap

/** Netty's epoll and io_uring handlers find a channel's registration in an `IntObjectHashMap`, keyed by its file
  * descriptor (epoll) or by a counter (io_uring). That map hashes an int to itself, probes linearly and deletes by
  * shifting the following entries back, so with tens of thousands of connections, whose keys are dense, the entries
  * form one long run of slots and every deregistration scans to its end: ~4 µs per closed connection, 7% of the CPU
  * when most requests come on new connections.
  *
  * [[factory]] wraps Netty's handler factory and gives each new handler a map that scrambles its keys (`get`, `put`
  * and `remove` are all the handlers use), which breaks the run up. The map lives in a private field, so this needs
  * reflection; if that fails (a Netty version without the field) the handler keeps its own.
  */
object Registrations:
  def factory(inner: IoHandlerFactory, handlerClass: Class[? <: IoHandler]): IoHandlerFactory = new IoHandlerFactory:
    override def newHandler(executor: ThreadAwareExecutor): IoHandler =
      val handler = inner.newHandler(executor)
      try
        val field = handlerClass.getDeclaredField("registrations")
        field.setAccessible(true)
        if field.get(handler).asInstanceOf[IntObjectHashMap[?]].isEmpty then field.set(handler, ScrambledIntMap[AnyRef]())
      catch case e: ReflectiveOperationException => Log.warn("Netty's registrations map left as it is", "error" -> e.toString)
      handler

    override def isChangingThreadSupported: Boolean = inner.isChangingThreadSupported

  /** An `IntObjectHashMap` whose keys go through a bijection (murmur3's finalizer) on the way in. */
  final class ScrambledIntMap[V] extends IntObjectHashMap[V](4096):
    override def get(key: Int): V = super.get(scramble(key))
    override def put(key: Int, value: V): V = super.put(scramble(key), value)
    override def remove(key: Int): V = super.remove(scramble(key))
    override def containsKey(key: Int): Boolean = super.containsKey(scramble(key))

  private[conduit] def scramble(key: Int): Int =
    var h = key
    h ^= h >>> 16
    h *= 0x85ebca6b
    h ^= h >>> 13
    h *= 0xc2b2ae35
    h ^ (h >>> 16)
