<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Repository;

use App\Module\Article\Domain\Model\ArticleAuthorship;
use App\Module\Article\Domain\Model\ArticleChanges;
use App\Module\Article\Domain\Model\NewArticle;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Module\Article\Domain\View\ArticleView;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleAuthorshipMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Persistence\Pg\PgValue;

/**
 * The slug is the lower-cased title with each run of characters other than ASCII letters and digits turned into a
 * hyphen, trimmed, then a hyphen and the article's id. Postgres computes it.
 */
final class PgArticleRepository implements ArticleRepositoryInterface
{
    /**
     * $1 = viewer; whether the viewer favorited the article or follows its author is an index probe.
     */
    private const string FULL_SELECT = <<<'SQL'
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
               ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
                       FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               COALESCE((SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id), false) AS favorited,
               u.username, u.bio, u.image,
               COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id), false) AS following
          FROM articles a
          JOIN users u ON u.id = a.author_id
        SQL;

    private const string BY_SLUG = self::FULL_SELECT . ' WHERE a.slug = $2';

    private const string BY_ID = self::FULL_SELECT . ' WHERE a.id = $2';

    private const string ID_BY_SLUG = 'SELECT id FROM articles WHERE slug = $1';

    private const string AUTHORSHIP_BY_SLUG = 'SELECT id, author_id FROM articles WHERE slug = $1';

    private const string INSERT = <<<'SQL'
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id
        SQL;

    private const string INSERT_TAGS = 'INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING';

    private const string INSERT_ARTICLE_TAGS = 'INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])';

    private const string UPDATE = <<<'SQL'
        UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
               slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
               updated_at = now()
         WHERE id = $1
        SQL;

    private const string DELETE = 'DELETE FROM articles WHERE id = $1';

    private readonly BatchedRead $bySlug;

    public function __construct(
        private readonly PgConnection $connection,
        private readonly ArticleViewMapper $viewMapper,
        private readonly ArticleAuthorshipMapper $authorshipMapper,
    ) {
        $this->bySlug = new BatchedRead(self::BY_SLUG, ['bigint', 'text']);
    }

    public function findBySlug(string $slug, int $viewerId): ?ArticleView
    {
        $rows = $this->connection->readBatched($this->bySlug, [$viewerId, $slug]);

        return $rows === [] ? null : $this->viewMapper->toView($rows[0]);
    }

    public function findById(int $id, int $viewerId): ?ArticleView
    {
        $row = pg_fetch_assoc($this->connection->read(self::BY_ID, [$viewerId, $id]));

        return $row === false ? null : $this->viewMapper->toView($row);
    }

    public function findIdBySlug(string $slug): ?int
    {
        $row = pg_fetch_row($this->connection->read(self::ID_BY_SLUG, [$slug]));

        return $row === false ? null : (int) $row[0];
    }

    public function findAuthorshipBySlug(string $slug): ?ArticleAuthorship
    {
        $row = pg_fetch_assoc($this->connection->read(self::AUTHORSHIP_BY_SLUG, [$slug]));

        return $row === false ? null : $this->authorshipMapper->toDomain($row);
    }

    public function add(NewArticle $article): int
    {
        return $this->connection->transaction(function () use ($article): int {
            $inserted = $this->connection->write(self::INSERT, [$article->authorId, $article->title, $article->description, $article->body]);
            $id = (int) pg_fetch_result($inserted, 0, 0);

            if ($article->tagList !== []) {
                $tagNames = PgValue::textArrayParam($article->tagList);
                $this->connection->write(self::INSERT_TAGS, [$tagNames]);
                $this->connection->write(self::INSERT_ARTICLE_TAGS, [$id, $tagNames]);
            }

            return $id;
        });
    }

    public function update(int $id, ArticleChanges $changes): void
    {
        $this->connection->write(self::UPDATE, [$id, $changes->title, $changes->description, $changes->body]);
    }

    public function delete(int $id): void
    {
        $this->connection->write(self::DELETE, [$id]);
    }
}
