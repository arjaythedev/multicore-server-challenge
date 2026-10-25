<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Interface\Http\Response\ArticleEnvelopeResponse;

final class ArticleEnvelopeResponseMapper
{
    public function __construct(
        private readonly ArticleResponseMapper $articleResponseMapper,
    ) {
    }

    public function toResponse(ArticleResult $article): ArticleEnvelopeResponse
    {
        return new ArticleEnvelopeResponse(article: $this->articleResponseMapper->toResponse($article));
    }
}
