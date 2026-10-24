package conduit

import cats.effect.std.Queue
import cats.effect.{Deferred, IO, Resource}
import cats.syntax.all.*
import fs2.{Chunk, Stream}

/** Merges concurrent lookups of the same kind into one database statement: the "DataLoader" pattern, with fs2.
  *
  * A caller enqueues its key with a `Deferred` and waits on it. One stream takes whatever is queued as a chunk, runs
  * the whole chunk as one statement, and completes each caller with its own result. There is no timer: when the server
  * is idle a chunk holds one key, so nothing waits; under load the keys that arrive while earlier batches run form the
  * next chunk. Every caller gets its own row, read by a statement that started after it asked: nothing is cached or
  * shared between requests (rule 5).
  *
  * @param lookup
  *   runs one statement for the keys and returns the value for each key that has one, by the key's index in the list
  */
final class Batcher[K, V] private (queue: Queue[IO, (K, Deferred[IO, Either[Throwable, Option[V]]])]):
  def apply(key: K): IO[Option[V]] =
    Deferred[IO, Either[Throwable, Option[V]]].flatMap(result => queue.offer(key -> result) *> result.get.rethrow)

object Batcher:
  def apply[K, V](maxBatch: Int, concurrency: Int)(lookup: List[K] => IO[Map[Int, V]]): Resource[IO, Batcher[K, V]] =
    for
      queue <- Resource.eval(Queue.unbounded[IO, (K, Deferred[IO, Either[Throwable, Option[V]]])])
      _ <- Stream
        .fromQueueUnterminated(queue, maxBatch)
        .chunks
        .parEvalMapUnordered(concurrency)(run(lookup))
        .compile
        .drain
        .background
    yield new Batcher(queue)

  private def run[K, V](lookup: List[K] => IO[Map[Int, V]])(
      batch: Chunk[(K, Deferred[IO, Either[Throwable, Option[V]]])]
  ): IO[Unit] =
    lookup(batch.map(_._1).toList).attempt.flatMap {
      case Right(found) =>
        batch.zipWithIndex.traverse_ { case ((_, result), i) => result.complete(Right(found.get(i))) }
      case Left(error) =>
        batch.traverse_((_, result) => result.complete(Left(error)))
    }

/** The lookups that go through a [[Batcher]]: an article, an article's comments (`None`: no such article), and a
  * viewer's feed page with its capped count.
  */
final case class Lookups(
    article: ((Long, String)) => IO[Option[Sql.ArticleRow]],
    comments: ((Long, String)) => IO[Option[List[Sql.CommentRow]]],
    feed: ((Long, Sql.Page)) => IO[(List[Sql.ArticleRow], Long)]
)
