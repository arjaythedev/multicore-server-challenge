<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Comment\Infrastructure\Persistence\Pg\Repository;

use App\Module\Comment\Infrastructure\Persistence\Pg\Repository\PgCommentRepository;
use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use App\Tests\Support\ReferenceReader;
use App\Tests\Support\SeededSamples;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * An article's comments, found by its slug, equal what the reference statements of SPEC.md return: the
 * article's id, then its newest 100 comments.
 */
final class PgCommentRepositoryTest extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    public function testTheNewestCommentsMatchTheReference(): void
    {
        $reference = new ReferenceReader($this->connection);
        $capped = false;
        $empty = false;

        foreach ((new SeededSamples($this->connection))->commentedSlugs() as $slug) {
            foreach ($this->viewersOf($slug) as $viewerId) {
                $expected = $reference->commentsOfArticle($slug, $viewerId);
                $capped = $capped || $expected?->count() === 100;
                $empty = $empty || $expected?->isEmpty() === true;

                self::assertEquals($expected, $this->repository()->findNewestBySlug($slug, $viewerId), "slug $slug, viewer $viewerId");
            }
        }

        self::assertTrue($capped, 'No sampled article had more than 100 comments.');
        self::assertTrue($empty, 'No sampled article had no comments.');
    }

    public function testAnUnknownSlugIsNotAnArticleWithNoComments(): void
    {
        self::assertNull($this->repository()->findNewestBySlug('no-such-article', 0));
    }

    public function testAnArticleWithoutCommentsIsAnEmptyList(): void
    {
        $slug = (string) pg_fetch_result($this->connection->read('SELECT slug FROM articles a WHERE NOT EXISTS (SELECT 1 FROM comments c WHERE c.article_id = a.id) ORDER BY id LIMIT 1', []), 0, 0);

        $comments = $this->repository()->findNewestBySlug($slug, 0);

        self::assertNotNull($comments);
        self::assertTrue($comments->isEmpty());
    }

    /**
     * The anonymous viewer, the spread of viewers, and the users who follow a commenter of the article.
     *
     * @return list<int>
     */
    private function viewersOf(string $slug): array
    {
        $followers = array_map(intval(...), pg_fetch_all_columns($this->connection->read(<<<'SQL'
            SELECT DISTINCT fo.follower_id
              FROM follows fo
              JOIN comments c ON c.author_id = fo.followee_id
              JOIN articles a ON a.id = c.article_id
             WHERE a.slug = $1
             ORDER BY fo.follower_id LIMIT 3
            SQL, [$slug]), 0));

        return array_values(array_unique([...(new SeededSamples($this->connection))->viewerIds(), ...$followers]));
    }

    private function repository(): PgCommentRepository
    {
        $repository = self::getContainer()->get(PgCommentRepository::class);
        self::assertInstanceOf(PgCommentRepository::class, $repository);

        return $repository;
    }
}
