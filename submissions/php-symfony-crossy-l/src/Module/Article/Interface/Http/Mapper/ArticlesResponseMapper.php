<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Interface\Http\Response\ArticlesResponse;

final class ArticlesResponseMapper
{
    public function __construct(
        private readonly ArticleSummaryResponseMapper $articleSummaryResponseMapper,
    ) {
    }

    public function toResponse(ArticlesResult $result): ArticlesResponse
    {
        return new ArticlesResponse(
            articles: $result->articles->map($this->articleSummaryResponseMapper->toResponse(...)),
            articlesCount: $result->articlesCount,
        );
    }
}
