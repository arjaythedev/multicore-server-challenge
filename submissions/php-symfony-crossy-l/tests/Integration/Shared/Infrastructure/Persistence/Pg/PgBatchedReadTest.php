<?php

declare(strict_types=1);

namespace App\Tests\Integration\Shared\Infrastructure\Persistence\Pg;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleAuthorshipMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticlePageViewMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleSummaryViewMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleViewMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticlePageRepository;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticleRepository;
use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentAuthorshipMapper;
use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentViewMapper;
use App\Module\Comment\Infrastructure\Persistence\Pg\Repository\PgCommentRepository;
use App\Module\Profile\Infrastructure\Persistence\Pg\Mapper\ProfileUserMapper;
use App\Module\Profile\Infrastructure\Persistence\Pg\Repository\PgProfileRepository;
use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Persistence\Pg\PgQueryFailedException;
use App\Tests\Support\RunsCoroutines;
use App\Tests\Support\SeededSamples;
use Closure;
use PHPUnit\Framework\Attributes\RequiresPhpExtension;
use PHPUnit\Framework\TestCase;
use Swoole\Coroutine;
use Swoole\Coroutine\WaitGroup;
use Throwable;

/**
 * Reads that find the worker's connections busy share a statement, and each request still gets exactly its own rows.
 */
#[RequiresPhpExtension('swoole')]
final class PgBatchedReadTest extends TestCase
{
    use RunsCoroutines;

    public function testReadsThatWaitForAConnectionRunInOneStatement(): void
    {
        $answers = $this->readWhileTheOnlyConnectionIsBusy(10);

        self::assertSame(range(1, 10), array_column($answers, 'n'), 'Every request got its own row.');
        self::assertCount(1, array_unique(array_column($answers, 'at')), 'One statement ran, so one statement time.');
    }

    public function testNoMoreThanTheMostOneStatementServesShareOne(): void
    {
        $answers = $this->readWhileTheOnlyConnectionIsBusy(BatchedRead::MAX + 8);

        self::assertSame(range(1, BatchedRead::MAX + 8), array_column($answers, 'n'));
        self::assertCount(2, array_unique(array_column($answers, 'at')), 'The first 32 waiting ran together, the 8 after them together.');
    }

    public function testARequestThatFailsTheStatementIsTheOnlyOneToHearOfIt(): void
    {
        $connection = new PgConnection(self::databaseUrl(), 1);
        $divide = new BatchedRead('SELECT 100 / $1::int AS quotient', ['int']);
        $outcomes = [];

        $this->inCoroutines(function () use ($connection, $divide, &$outcomes): void {
            $group = new WaitGroup();
            $this->occupy($connection, $group);

            foreach ([1, 0, 4, 5] as $divisor) {
                $group->add();
                Coroutine::create(static function () use ($connection, $divide, $divisor, $group, &$outcomes): void {
                    try {
                        $outcomes[$divisor] = (int) $connection->readBatched($divide, [$divisor])[0]['quotient'];
                    } catch (PgQueryFailedException) {
                        $outcomes[$divisor] = 'failed';
                    }

                    $group->done();
                });
            }

            $group->wait();
        });

        ksort($outcomes);
        self::assertSame([0 => 'failed', 1 => 100, 4 => 25, 5 => 20], $outcomes);
    }

    public function testAWriteAndTheReadsWaitingWithItAllFinish(): void
    {
        $connection = new PgConnection(self::databaseUrl(), 1);
        $probe = new BatchedRead('SELECT $1::int AS n', ['int']);
        $answers = [];
        $written = false;

        $this->inCoroutines(function () use ($connection, $probe, &$answers, &$written): void {
            $group = new WaitGroup();
            $this->occupy($connection, $group);

            foreach (range(1, 6) as $number) {
                $group->add();
                Coroutine::create(static function () use ($connection, $probe, $number, $group, &$answers): void {
                    $answers[] = (int) $connection->readBatched($probe, [$number])[0]['n'];
                    $group->done();
                });

                if ($number === 3) {
                    $group->add();
                    Coroutine::create(static function () use ($connection, $group, &$written): void {
                        $connection->transaction(static function () use ($connection, &$written): void {
                            $connection->write('SELECT 1', []);
                            $written = true;
                        });
                        $group->done();
                    });
                }
            }

            $group->wait();
        });

        sort($answers);
        self::assertSame(range(1, 6), $answers);
        self::assertTrue($written);
    }

    public function testTheRepositoriesAnswerTheSameWhenTheirReadsAreBatched(): void
    {
        $sampling = new PgConnection(self::databaseUrl(), 1);
        $samples = new SeededSamples($sampling);
        $viewers = \array_slice($samples->viewerIds(), 0, 4);

        $reads = [];
        $sequential = $this->repositories($sampling);
        $concurrent = $this->repositories(new PgConnection(self::databaseUrl(), 1));

        foreach ($viewers as $viewerId) {
            foreach ($samples->articleSlugs() as $slug) {
                $reads["article $slug $viewerId"] = static fn (array $r): mixed => $r['article']->findBySlug($slug, $viewerId);
            }

            foreach ($samples->commentedSlugs() as $slug) {
                $reads["comments $slug $viewerId"] = static fn (array $r): mixed => $r['comment']->findNewestBySlug($slug, $viewerId);
            }

            foreach ($samples->authors() as $username) {
                $reads["profile $username $viewerId"] = static fn (array $r): mixed => $r['profile']->findByUsername($username, $viewerId);
            }

            foreach (\array_slice(SeededSamples::WINDOWS, 0, 4) as [$limit, $offset]) {
                $reads["feed $viewerId $limit $offset"] = static fn (array $r): mixed => $r['page']->findFeedPage($viewerId, $limit, $offset);
                $reads["all $viewerId $limit $offset"] = static fn (array $r): mixed => $r['page']->findPage(ArticleFilter::none(), $viewerId, $limit, $offset);

                foreach ($samples->tags() as $tag) {
                    $reads["tag $tag $viewerId $limit $offset"] = static fn (array $r): mixed => $r['page']->findPage(ArticleFilter::byTag($tag), $viewerId, $limit, $offset);
                }

                foreach ($samples->authors() as $username) {
                    $reads["author $username $viewerId $limit $offset"] = static fn (array $r): mixed => $r['page']->findPage(ArticleFilter::byAuthor($username), $viewerId, $limit, $offset);
                }

                foreach ($samples->favoriters() as $username) {
                    $reads["favorited $username $viewerId $limit $offset"] = static fn (array $r): mixed => $r['page']->findPage(ArticleFilter::favoritedBy($username), $viewerId, $limit, $offset);
                }
            }
        }

        $expected = array_map(static fn (Closure $read): mixed => $read($sequential), $reads);
        $actual = [];

        $this->inCoroutines(function () use ($reads, $concurrent, &$actual): void {
            $group = new WaitGroup();

            foreach ($reads as $label => $read) {
                $group->add();
                Coroutine::create(static function () use ($label, $read, $concurrent, $group, &$actual): void {
                    try {
                        $actual[$label] = $read($concurrent);
                    } catch (Throwable $failure) {
                        $actual[$label] = $failure;
                    }

                    $group->done();
                });
            }

            $group->wait();
        });

        self::assertGreaterThan(200, \count($reads));

        foreach ($expected as $label => $answer) {
            self::assertEquals($answer, $actual[$label] ?? null, $label);
        }
    }

    /**
     * Starts $count reads of a probe while the worker's only connection is busy, and returns each one's row, by the
     * number it asked for.
     *
     * @return list<array{n: int, at: string}>
     */
    private function readWhileTheOnlyConnectionIsBusy(int $count): array
    {
        $connection = new PgConnection(self::databaseUrl(), 1);
        $probe = new BatchedRead('SELECT $1::int AS n, statement_timestamp()::text AS at', ['int']);
        $answers = [];

        $this->inCoroutines(function () use ($connection, $probe, $count, &$answers): void {
            $group = new WaitGroup();
            $this->occupy($connection, $group);

            foreach (range(1, $count) as $number) {
                $group->add();
                Coroutine::create(static function () use ($connection, $probe, $number, $group, &$answers): void {
                    $rows = $connection->readBatched($probe, [$number]);
                    self::assertCount(1, $rows);
                    $answers[$number] = ['n' => (int) $rows[0]['n'], 'at' => (string) $rows[0]['at']];
                    $group->done();
                });
            }

            $group->wait();
        });

        ksort($answers);

        return array_values($answers);
    }

    /**
     * A statement that holds the connection for a moment, so that what is started after it has to wait.
     */
    private function occupy(PgConnection $connection, WaitGroup $group): void
    {
        $group->add();
        Coroutine::create(static function () use ($connection, $group): void {
            $connection->read('SELECT pg_sleep(0.2)', []);
            $group->done();
        });
    }

    /**
     * @return array{article: PgArticleRepository, comment: PgCommentRepository, profile: PgProfileRepository, page: PgArticlePageRepository}
     */
    private function repositories(PgConnection $connection): array
    {
        $profiles = new ProfileViewMapper();

        return [
            'article' => new PgArticleRepository($connection, new ArticleViewMapper($profiles), new ArticleAuthorshipMapper()),
            'comment' => new PgCommentRepository($connection, new CommentViewMapper($profiles), new CommentAuthorshipMapper()),
            'profile' => new PgProfileRepository($connection, $profiles, new ProfileUserMapper()),
            'page' => new PgArticlePageRepository($connection, new ArticlePageViewMapper(new ArticleSummaryViewMapper($profiles))),
        ];
    }
}
