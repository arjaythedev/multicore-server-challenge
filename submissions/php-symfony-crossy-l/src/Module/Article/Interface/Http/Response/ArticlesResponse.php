<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Response;

/**
 * {"articles": [Article without body], "articlesCount": <count up to 1,000>}
 */
final readonly class ArticlesResponse
{
    /**
     * @param list<ArticleSummaryResponse> $articles
     */
    public function __construct(
        public array $articles,
        public int $articlesCount,
    ) {
    }
}
