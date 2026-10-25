<?php

declare(strict_types=1);

namespace App\Module\Comment\Infrastructure\Persistence\Pg\Repository;

use App\Module\Comment\Domain\Model\CommentAuthorship;
use App\Module\Comment\Domain\Model\NewComment;
use App\Module\Comment\Domain\Repository\CommentRepositoryInterface;
use App\Module\Comment\Domain\View\CommentView;
use App\Module\Comment\Domain\View\CommentViewList;
use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentAuthorshipMapper;
use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use UnexpectedValueException;

final class PgCommentRepository implements CommentRepositoryInterface
{
    private const string ARTICLE_ID_BY_SLUG = 'SELECT id FROM articles WHERE slug = $1';

    /**
     * $1 = viewer, $2 = slug. An article without comments is one row with NULL comment columns; no row is no article.
     */
    private const string NEWEST_BY_SLUG = <<<'SQL'
        SELECT a.id AS article_id, r.*
          FROM articles a
          LEFT JOIN LATERAL (
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id), false) AS following
              FROM comments c JOIN users u ON u.id = c.author_id
             WHERE c.article_id = a.id
             ORDER BY c.created_at DESC, c.id DESC
             LIMIT 100) r ON true
         WHERE a.slug = $2
         ORDER BY r.created_at DESC NULLS LAST, r.id DESC NULLS LAST
        SQL;

    private const string INSERT = <<<'SQL'
        WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
                   RETURNING id, body, created_at, updated_at, author_id)
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false AS following
          FROM c JOIN users u ON u.id = c.author_id
        SQL;

    private const string AUTHORSHIP_ON_ARTICLE = <<<'SQL'
        SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
         WHERE c.id = $1 AND a.slug = $2
        SQL;

    private const string DELETE = 'DELETE FROM comments WHERE id = $1';

    private readonly BatchedRead $newestBySlug;

    public function __construct(
        private readonly PgConnection $connection,
        private readonly CommentViewMapper $viewMapper,
        private readonly CommentAuthorshipMapper $authorshipMapper,
    ) {
        $this->newestBySlug = new BatchedRead(self::NEWEST_BY_SLUG, ['bigint', 'text']);
    }

    public function findArticleIdBySlug(string $slug): ?int
    {
        $row = pg_fetch_row($this->connection->read(self::ARTICLE_ID_BY_SLUG, [$slug]));

        return $row === false ? null : (int) $row[0];
    }

    public function findNewestBySlug(string $slug, int $viewerId): ?CommentViewList
    {
        $rows = $this->connection->readBatched($this->newestBySlug, [$viewerId, $slug]);

        return $rows === [] ? null : $this->viewMapper->toViewList($rows);
    }

    /** The author of a new comment comes back as not followed. */
    public function add(NewComment $comment): CommentView
    {
        $row = pg_fetch_assoc($this->connection->write(self::INSERT, [$comment->articleId, $comment->authorId, $comment->body]));

        if ($row === false) {
            throw new UnexpectedValueException('The insert returned no row.');
        }

        return $this->viewMapper->toView($row);
    }

    public function findAuthorshipOnArticle(int $commentId, string $slug): ?CommentAuthorship
    {
        $row = pg_fetch_assoc($this->connection->read(self::AUTHORSHIP_ON_ARTICLE, [$commentId, $slug]));

        return $row === false ? null : $this->authorshipMapper->toDomain($row);
    }

    public function delete(int $commentId): void
    {
        $this->connection->write(self::DELETE, [$commentId]);
    }
}
