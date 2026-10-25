<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Result;

/**
 * A page of a list, and how many articles the whole list holds, counted up to 1,000.
 */
final readonly class ArticlesResult
{
    public function __construct(
        public ArticleSummaryResultList $articles,
        public int $articlesCount,
    ) {
    }
}
