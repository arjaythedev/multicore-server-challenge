<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Article\Infrastructure\Persistence\Pg\Repository;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticlePageRepository;
use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use App\Tests\Support\ReferenceReader;
use App\Tests\Support\SeededSamples;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * Every page the repository returns, with its count, equals what the reference statements of SPEC.md return
 * for the same viewer, filter and window.
 */
final class PgArticlePageRepositoryTest extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    public function testTheListOfAllArticlesMatchesTheReference(): void
    {
        $this->assertMatchesReference(static fn (): array => [ArticleFilter::none()]);
    }

    public function testTheListsOfATagMatchTheReference(): void
    {
        $this->assertMatchesReference(fn (): array => array_map(ArticleFilter::byTag(...), $this->samples()->tags()));
    }

    public function testTheListsOfAnAuthorMatchTheReference(): void
    {
        $this->assertMatchesReference(fn (): array => array_map(ArticleFilter::byAuthor(...), $this->samples()->authors()));
    }

    public function testTheListsOfAUsersFavoritesMatchTheReference(): void
    {
        $this->assertMatchesReference(fn (): array => array_map(ArticleFilter::favoritedBy(...), $this->samples()->favoriters()));
    }

    public function testTheFeedsMatchTheReference(): void
    {
        $reference = new ReferenceReader($this->connection);
        $reached = 0;

        foreach ($this->samples()->viewerIds() as $viewerId) {
            foreach (SeededSamples::WINDOWS as [$limit, $offset]) {
                $expected = $reference->feedPage($viewerId, $limit, $offset);
                $reached += $expected->articles->isEmpty() ? 0 : 1;

                self::assertEquals($expected, $this->repository()->findFeedPage($viewerId, $limit, $offset), "feed of viewer $viewerId, limit $limit, offset $offset");
            }
        }

        self::assertGreaterThan(0, $reached, 'No sampled feed held an article.');
    }

    public function testAPageBeyondTheEndIsEmptyAndStillCounted(): void
    {
        $page = $this->repository()->findPage(ArticleFilter::none(), 0, 10, 10000000);

        self::assertTrue($page->articles->isEmpty());
        self::assertSame(1000, $page->count);
    }

    public function testTheCountStopsAtOneThousand(): void
    {
        self::assertSame(1000, $this->repository()->findPage(ArticleFilter::none(), 0, 1, 0)->count);
    }

    public function testAnUnknownTagOrUserNamesAnEmptyListWithACountOfZero(): void
    {
        foreach ([ArticleFilter::byTag('no-such-tag'), ArticleFilter::byAuthor('no-such-user'), ArticleFilter::favoritedBy('no-such-user')] as $filter) {
            $page = $this->repository()->findPage($filter, 0, 10, 0);

            self::assertTrue($page->articles->isEmpty());
            self::assertSame(0, $page->count);
        }
    }

    public function testAFavoriteAndAFollowMadeInTheSameTransactionShowInTheNextPage(): void
    {
        $newest = pg_fetch_assoc($this->connection->read('SELECT id, author_id FROM articles ORDER BY id DESC LIMIT 1', []));
        self::assertIsArray($newest);
        $viewerId = (int) pg_fetch_result($this->connection->read('SELECT id FROM users WHERE id <> $1 ORDER BY id LIMIT 1', [$newest['author_id']]), 0, 0);
        $this->connection->write('INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [$viewerId, $newest['id']]);
        $this->connection->write('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [$viewerId, $newest['author_id']]);

        $first = $this->repository()->findPage(ArticleFilter::none(), $viewerId, 10, 0)->articles->at(0);

        self::assertNotNull($first);
        self::assertTrue($first->favorited);
        self::assertTrue($first->author->following);
        self::assertEquals(
            (new ReferenceReader($this->connection))->articlePage(ArticleFilter::none(), $viewerId, 10, 0),
            $this->repository()->findPage(ArticleFilter::none(), $viewerId, 10, 0),
        );
    }

    /**
     * @param callable(): list<ArticleFilter> $filters
     */
    private function assertMatchesReference(callable $filters): void
    {
        $reference = new ReferenceReader($this->connection);
        $reached = 0;

        foreach ($filters() as $filter) {
            foreach ($this->samples()->viewerIds() as $viewerId) {
                foreach (SeededSamples::WINDOWS as [$limit, $offset]) {
                    $expected = $reference->articlePage($filter, $viewerId, $limit, $offset);
                    $reached += $expected->articles->isEmpty() ? 0 : 1;

                    self::assertEquals(
                        $expected,
                        $this->repository()->findPage($filter, $viewerId, $limit, $offset),
                        \sprintf('%s "%s", viewer %d, limit %d, offset %d', $filter->kind->name, $filter->value, $viewerId, $limit, $offset),
                    );
                }
            }
        }

        self::assertGreaterThan(0, $reached, 'No sampled page held an article.');
    }

    private function samples(): SeededSamples
    {
        return new SeededSamples($this->connection);
    }

    private function repository(): PgArticlePageRepository
    {
        $repository = self::getContainer()->get(PgArticlePageRepository::class);
        self::assertInstanceOf(PgArticlePageRepository::class, $repository);

        return $repository;
    }
}
