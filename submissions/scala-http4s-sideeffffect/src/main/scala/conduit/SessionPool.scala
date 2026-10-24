package conduit

import cats.effect.std.Queue
import cats.effect.{IO, Poll, Resource}
import cats.syntax.all.*
import skunk.Session
import skunk.data.TransactionStatus

import scala.concurrent.duration.*

/** Sessions for read-only requests and for requests that write. */
final case class Db(read: Resource[IO, Session[IO]], write: Resource[IO, Session[IO]])

/** A fixed set of long-lived skunk sessions in a queue.
  *
  * `Session.pooled` returns every session with its "full" recycler, which runs `UNLISTEN *` and `RESET ALL`: two extra
  * round trips per checkout, and two more statements for Postgres, the busiest process on the box. This app never
  * listens or sets anything, so a returned session only has to be healthy and outside a transaction, which skunk tracks
  * without any I/O.
  *
  * Each slot in the queue holds an open session, or nothing when its session is gone (it failed, or never opened).
  * Sessions are (re)opened by whoever takes an empty slot, while acquiring, where the request can be cancelled and an
  * error (Postgres is down, say) fails just that request. Releasing never waits on the network beyond a bounded close.
  */
object SessionPool:

  private type Slot = Option[(Session[IO], IO[Unit])]

  def apply(size: Int, session: Resource[IO, Session[IO]]): Resource[IO, Resource[IO, Session[IO]]] =
    def acquire(queue: Queue[IO, Slot])(poll: Poll[IO]): IO[(Session[IO], IO[Unit])] =
      poll(queue.take).flatMap {
        case Some(open) => IO.pure(open)
        case None => poll(session.allocated).guaranteeCase(outcome => queue.offer(None).unlessA(outcome.isSuccess))
      }

    def release(queue: Queue[IO, Slot])(open: (Session[IO], IO[Unit])): IO[Unit] =
      val (s, close) = open
      (s.isHealthy, s.transactionStatus.get).flatMapN { (healthy, status) =>
        if healthy && status == TransactionStatus.Idle then queue.offer(Some(open))
        else close.attempt.timeoutTo(5.seconds, IO.unit) *> queue.offer(None)
      }

    // Open every session up front, but a session that fails to open (or Postgres being down) only leaves its slot
    // empty: nothing already opened leaks, and the app still starts.
    val opened = Resource.make(
      Queue
        .bounded[IO, Slot](size)
        .flatTap(queue => session.allocated.attempt.flatMap(open => queue.offer(open.toOption)).parReplicateA_(size))
    )(queue => queue.tryTakeN(None).flatMap(_.traverse_(_.traverse_((_, close) => close.attempt))))

    opened.map(queue => Resource.makeFull(acquire(queue))(release(queue)).map(_._1))
