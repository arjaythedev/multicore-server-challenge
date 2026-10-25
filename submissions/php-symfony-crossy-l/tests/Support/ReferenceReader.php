<?php

declare(strict_types=1);

namespace App\Tests\Support;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Domain\Model\ArticleFilterKind;
use App\Module\Article\Domain\View\ArticlePageView;
use App\Module\Article\Domain\View\ArticleView;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleSummaryViewMapper;
use App\Module\Article\Infrastructure\Persistence\Pg\Mapper\ArticleViewMapper;
use App\Module\Comment\Domain\View\CommentViewList;
use App\Module\Comment\Infrastructure\Persistence\Pg\Mapper\CommentViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use PgSql\Result;

/**
 * Answers the repositories' questions by running SPEC.md's reference statements one after the other. The rows become
 * views through the repositories' own mappers, so what is compared is the SQL.
 */
final class ReferenceReader
{
    private readonly ArticleViewMapper $articles;

    private readonly ArticleSummaryViewMapper $summaries;

    private readonly CommentViewMapper $comments;

    public function __construct(
        private readonly PgConnection $connection,
    ) {
        $profiles = new ProfileViewMapper();

        $this->articles = new ArticleViewMapper($profiles);
        $this->summaries = new ArticleSummaryViewMapper($profiles);
        $this->comments = new CommentViewMapper($profiles);
    }

    public function articlePage(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlePageView
    {
        $page = [$viewerId, $limit, $offset];

        [$pageResult, $countResult] = match ($filter->kind) {
            ArticleFilterKind::None => [
                $this->connection->read(ReferenceSql::PAGE_ALL, $page),
                $this->connection->read(ReferenceSql::COUNT_ALL, []),
            ],
            ArticleFilterKind::Tag => [
                $this->connection->read(ReferenceSql::PAGE_BY_TAG, [...$page, $filter->value]),
                $this->connection->read(ReferenceSql::COUNT_BY_TAG, [$filter->value]),
            ],
            ArticleFilterKind::Author => [
                $this->connection->read(ReferenceSql::PAGE_BY_AUTHOR, [...$page, $filter->value]),
                $this->connection->read(ReferenceSql::COUNT_BY_AUTHOR, [$filter->value]),
            ],
            ArticleFilterKind::FavoritedBy => [
                $this->connection->read(ReferenceSql::PAGE_FAVORITED_BY, [...$page, $filter->value]),
                $this->connection->read(ReferenceSql::COUNT_FAVORITED_BY, [$filter->value]),
            ],
        };

        return new ArticlePageView($this->summaries->toViewList(self::rows($pageResult)), (int) pg_fetch_result($countResult, 0, 0));
    }

    public function feedPage(int $viewerId, int $limit, int $offset): ArticlePageView
    {
        return new ArticlePageView(
            $this->summaries->toViewList(self::rows($this->connection->read(ReferenceSql::PAGE_FEED, [$viewerId, $limit, $offset]))),
            (int) pg_fetch_result($this->connection->read(ReferenceSql::COUNT_FEED, [$viewerId]), 0, 0),
        );
    }

    public function articleBySlug(string $slug, int $viewerId): ?ArticleView
    {
        return $this->article($this->connection->read(ReferenceSql::ARTICLE_BY_SLUG, [$viewerId, $slug]));
    }

    public function articleById(int $id, int $viewerId): ?ArticleView
    {
        return $this->article($this->connection->read(ReferenceSql::ARTICLE_BY_ID, [$viewerId, $id]));
    }

    public function commentsOfArticle(string $slug, int $viewerId): ?CommentViewList
    {
        $row = pg_fetch_row($this->connection->read(ReferenceSql::ARTICLE_ID_BY_SLUG, [$slug]));

        if ($row === false) {
            return null;
        }

        return $this->comments->toViewList(self::rows($this->connection->read(ReferenceSql::COMMENTS_OF_ARTICLE, [$viewerId, (int) $row[0]])));
    }

    private function article(Result $result): ?ArticleView
    {
        $row = pg_fetch_assoc($result);

        return $row === false ? null : $this->articles->toView($row);
    }

    /**
     * @return list<array<array-key, string|null>>
     */
    private static function rows(Result $result): array
    {
        return array_values(pg_fetch_all($result));
    }
}
