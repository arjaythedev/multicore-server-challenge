<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Mapper;

use App\Module\Article\Domain\View\ArticlePageView;

/**
 * A page from the rows of a list statement, each of which carries the size of the whole list in its `total` column.
 */
final class ArticlePageViewMapper
{
    public function __construct(
        private readonly ArticleSummaryViewMapper $articleSummaryViewMapper,
    ) {
    }

    /**
     * @param list<array<array-key, string|null>> $rows
     */
    public function toView(array $rows): ArticlePageView
    {
        return new ArticlePageView(
            articles: $this->articleSummaryViewMapper->toViewList($rows),
            count: $rows === [] ? 0 : (int) $rows[0]['total'],
        );
    }
}
