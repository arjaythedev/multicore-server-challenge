<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Repository;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Domain\Model\ArticleFilterKind;
use App\Module\Article\Domain\Repository\ArticlePageRepositoryInterface;
use App\Module\Article\Domain\View\ArticlePageView;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticlePageViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

/**
 * One statement returns a page and the size of its list. Every statement takes $1 = viewer, $2 = limit, $3 = offset
 * and, where there is one, $4 = the filter value. The page is cut first as a list of ids, then each article of it is
 * read by index lookups; OFFSET 0 keeps Postgres from folding that back into a join. Every row carries the list's
 * size, and a page with no articles is one row without article columns.
 */
final class PgArticlePageRepository implements ArticlePageRepositoryInterface
{
    private const string WITH_TOTAL = 'WITH total AS (';

    private const string PAGE_OF = <<<'SQL'
        ) SELECT total.n AS total, r.*
          FROM total
          LEFT JOIN LATERAL (
            SELECT l.*
              FROM (
        SQL;

    private const string READ_EACH = <<<'SQL'
        ) p
              CROSS JOIN LATERAL (
                SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
                       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
                               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                       COALESCE((SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id), false) AS favorited,
                       u.username, u.bio, u.image,
                       COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id), false) AS following
                  FROM articles a
                  JOIN users u ON u.id = a.author_id
                 WHERE a.id = p.id
                 OFFSET 0) l
             ORDER BY p.id DESC) r ON true
         ORDER BY r.id DESC NULLS LAST
        SQL;

    private const string COUNT_ALL = 'SELECT count(*) AS n FROM (SELECT 1 FROM articles a LIMIT 1000) s';

    private const string IDS_ALL = 'SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3';

    private const string COUNT_BY_TAG = 'SELECT count(*) AS n FROM (SELECT 1 FROM article_tags at'
        . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s';

    private const string IDS_BY_TAG = 'SELECT at.article_id AS id FROM article_tags at'
        . ' WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3';

    private const string COUNT_BY_AUTHOR = 'SELECT count(*) AS n FROM (SELECT 1 FROM articles a'
        . ' WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s';

    private const string IDS_BY_AUTHOR = 'SELECT a.id FROM articles a'
        . ' WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3';

    private const string COUNT_FAVORITED_BY = 'SELECT count(*) AS n FROM (SELECT 1 FROM favorites f'
        . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s';

    private const string IDS_FAVORITED_BY = 'SELECT f.article_id AS id FROM favorites f'
        . ' WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3';

    private const string COUNT_FEED = 'SELECT count(*) AS n FROM (SELECT 1 FROM articles a'
        . ' WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s';

    private const string IDS_FEED = 'SELECT x.id FROM follows fo CROSS JOIN LATERAL'
        . ' (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x'
        . ' WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3';

    private const string PAGE_ALL = self::WITH_TOTAL . self::COUNT_ALL . self::PAGE_OF . self::IDS_ALL . self::READ_EACH;

    private const string PAGE_BY_TAG = self::WITH_TOTAL . self::COUNT_BY_TAG . self::PAGE_OF . self::IDS_BY_TAG . self::READ_EACH;

    private const string PAGE_BY_AUTHOR = self::WITH_TOTAL . self::COUNT_BY_AUTHOR . self::PAGE_OF . self::IDS_BY_AUTHOR . self::READ_EACH;

    private const string PAGE_FAVORITED_BY = self::WITH_TOTAL . self::COUNT_FAVORITED_BY . self::PAGE_OF . self::IDS_FAVORITED_BY . self::READ_EACH;

    private const string PAGE_FEED = self::WITH_TOTAL . self::COUNT_FEED . self::PAGE_OF . self::IDS_FEED . self::READ_EACH;

    private readonly BatchedRead $all;

    private readonly BatchedRead $byTag;

    private readonly BatchedRead $byAuthor;

    private readonly BatchedRead $favoritedBy;

    private readonly BatchedRead $feed;

    public function __construct(
        private readonly PgConnection $connection,
        private readonly ArticlePageViewMapper $pageViewMapper,
    ) {
        $this->all = new BatchedRead(self::PAGE_ALL, ['bigint', 'bigint', 'bigint']);
        $this->byTag = new BatchedRead(self::PAGE_BY_TAG, ['bigint', 'bigint', 'bigint', 'text']);
        $this->byAuthor = new BatchedRead(self::PAGE_BY_AUTHOR, ['bigint', 'bigint', 'bigint', 'text']);
        $this->favoritedBy = new BatchedRead(self::PAGE_FAVORITED_BY, ['bigint', 'bigint', 'bigint', 'text']);
        $this->feed = new BatchedRead(self::PAGE_FEED, ['bigint', 'bigint', 'bigint']);
    }

    public function findPage(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlePageView
    {
        $page = [$viewerId, $limit, $offset];

        return $this->pageViewMapper->toView(match ($filter->kind) {
            ArticleFilterKind::None => $this->connection->readBatched($this->all, $page),
            ArticleFilterKind::Tag => $this->connection->readBatched($this->byTag, [...$page, $filter->value]),
            ArticleFilterKind::Author => $this->connection->readBatched($this->byAuthor, [...$page, $filter->value]),
            ArticleFilterKind::FavoritedBy => $this->connection->readBatched($this->favoritedBy, [...$page, $filter->value]),
        });
    }

    public function findFeedPage(int $viewerId, int $limit, int $offset): ArticlePageView
    {
        return $this->pageViewMapper->toView($this->connection->readBatched($this->feed, [$viewerId, $limit, $offset]));
    }
}
