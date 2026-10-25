<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Mapper;

use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Domain\View\ArticlePageView;

final class ArticlesResultMapper
{
    public function __construct(
        private readonly ArticleSummaryResultMapper $articleSummaryResultMapper,
    ) {
    }

    public function toResult(ArticlePageView $page): ArticlesResult
    {
        return new ArticlesResult(
            articles: $this->articleSummaryResultMapper->toResultList($page->articles),
            articlesCount: $page->count,
        );
    }
}
