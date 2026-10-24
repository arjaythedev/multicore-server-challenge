package conduit

import cats.effect.std.Queue
import cats.effect.{IO, Resource}
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
  * without any I/O. A session that fails that check is closed and replaced.
  */
object SessionPool:

  private type Slot = (Session[IO], IO[Unit])

  def apply(size: Int, session: Resource[IO, Session[IO]]): Resource[IO, Resource[IO, Session[IO]]] =
    def open: IO[Slot] =
      session.allocated.handleErrorWith(_ => IO.sleep(1.second) *> open)

    def recycle(slot: Slot): IO[Slot] =
      val (s, close) = slot
      (s.isHealthy, s.transactionStatus.get).flatMapN { (healthy, status) =>
        if healthy && status == TransactionStatus.Idle then IO.pure(slot)
        else close.attempt *> open
      }

    Resource
      .make(
        Queue.bounded[IO, Slot](size).flatTap(queue => session.allocated.flatMap(queue.offer).parReplicateA_(size))
      )(queue => queue.tryTakeN(None).flatMap(_.traverse_((_, close) => close.attempt)))
      .map(queue =>
        Resource.makeFull[IO, Slot](poll => poll(queue.take))(slot => recycle(slot).flatMap(queue.offer)).map(_._1)
      )
