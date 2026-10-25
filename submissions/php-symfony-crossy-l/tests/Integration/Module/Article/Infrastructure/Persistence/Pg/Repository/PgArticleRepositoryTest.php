<?php

declare(strict_types=1);

namespace App\Tests\Integration\Module\Article\Infrastructure\Persistence\Pg\Repository;

use App\Module\Article\Infrastructure\Persistence\Pg\Repository\PgArticleRepository;
use App\Tests\Integration\Shared\Trait\RunsInRolledBackTransaction;
use App\Tests\Support\ReferenceReader;
use App\Tests\Support\SeededSamples;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

/**
 * An article read by slug or by id equals what the reference statement of SPEC.md returns.
 */
final class PgArticleRepositoryTest extends KernelTestCase
{
    use RunsInRolledBackTransaction;

    public function testAnArticleBySlugMatchesTheReference(): void
    {
        $reference = new ReferenceReader($this->connection);
        $found = 0;

        foreach ((new SeededSamples($this->connection))->articleSlugs() as $slug) {
            foreach ($this->viewersOf($slug) as $viewerId) {
                $expected = $reference->articleBySlug($slug, $viewerId);
                $found += $expected === null ? 0 : 1;

                self::assertEquals($expected, $this->repository()->findBySlug($slug, $viewerId), "slug $slug, viewer $viewerId");
            }
        }

        self::assertGreaterThan(0, $found, 'No sampled slug named an article.');
        self::assertNull($this->repository()->findBySlug('no-such-article', 0));
    }

    public function testAnArticleByIdMatchesTheReference(): void
    {
        $reference = new ReferenceReader($this->connection);
        $ids = array_map(intval(...), pg_fetch_all_columns($this->connection->read('SELECT id FROM articles ORDER BY md5(id::text) LIMIT 8', []), 0));

        foreach ([...$ids, 0, 99999999] as $id) {
            foreach ((new SeededSamples($this->connection))->viewerIds() as $viewerId) {
                self::assertEquals($reference->articleById($id, $viewerId), $this->repository()->findById($id, $viewerId), "id $id, viewer $viewerId");
            }
        }
    }

    public function testAFavoriteAndAFollowMadeInTheSameTransactionShowInTheNextRead(): void
    {
        $article = pg_fetch_assoc($this->connection->read('SELECT id, slug, author_id FROM articles ORDER BY id DESC LIMIT 1', []));
        self::assertIsArray($article);
        $viewerId = (int) pg_fetch_result($this->connection->read('SELECT id FROM users WHERE id <> $1 ORDER BY id LIMIT 1', [$article['author_id']]), 0, 0);
        $this->connection->write('INSERT INTO favorites (user_id, article_id) VALUES ($1, $2)', [$viewerId, $article['id']]);
        $this->connection->write('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)', [$viewerId, $article['author_id']]);

        $view = $this->repository()->findBySlug((string) $article['slug'], $viewerId);

        self::assertNotNull($view);
        self::assertTrue($view->favorited);
        self::assertTrue($view->author->following);
        self::assertEquals((new ReferenceReader($this->connection))->articleBySlug((string) $article['slug'], $viewerId), $view);
    }

    /**
     * The anonymous viewer, the author, someone who favorited the article, someone who follows the author,
     * and a few others.
     *
     * @return list<int>
     */
    private function viewersOf(string $slug): array
    {
        $ints = fn (string $sql): array => array_map(intval(...), pg_fetch_all_columns($this->connection->read($sql, [$slug]), 0));

        return array_values(array_unique([
            ...(new SeededSamples($this->connection))->viewerIds(),
            ...$ints('SELECT a.author_id FROM articles a WHERE a.slug = $1'),
            ...$ints('SELECT f.user_id FROM favorites f JOIN articles a ON a.id = f.article_id WHERE a.slug = $1 ORDER BY f.user_id LIMIT 2'),
            ...$ints('SELECT fo.follower_id FROM follows fo JOIN articles a ON a.author_id = fo.followee_id WHERE a.slug = $1 ORDER BY fo.follower_id LIMIT 2'),
        ]));
    }

    private function repository(): PgArticleRepository
    {
        $repository = self::getContainer()->get(PgArticleRepository::class);
        self::assertInstanceOf(PgArticleRepository::class, $repository);

        return $repository;
    }
}
