<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\View;

/**
 * A page of a list of articles, with how many articles the whole list holds, counted up to 1,000.
 */
readonly class ArticlePageView
{
    public function __construct(
        public ArticleSummaryViewList $articles,
        public int $count,
    ) {
    }
}
