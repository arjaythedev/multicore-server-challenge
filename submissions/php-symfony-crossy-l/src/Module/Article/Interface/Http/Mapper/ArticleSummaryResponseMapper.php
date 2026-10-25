<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Result\ArticleSummaryResult;
use App\Module\Article\Interface\Http\Response\ArticleSummaryResponse;
use App\Shared\Interface\Http\Mapper\ProfileResponseMapper;

final class ArticleSummaryResponseMapper
{
    public function __construct(
        private readonly ProfileResponseMapper $profileResponseMapper,
    ) {
    }

    public function toResponse(ArticleSummaryResult $article): ArticleSummaryResponse
    {
        return new ArticleSummaryResponse(
            slug: $article->slug,
            title: $article->title,
            description: $article->description,
            tagList: $article->tagList,
            createdAt: $article->createdAt->toIso8601(),
            updatedAt: $article->updatedAt->toIso8601(),
            favorited: $article->favorited,
            favoritesCount: $article->favoritesCount,
            author: $this->profileResponseMapper->toResponse($article->author),
        );
    }
}
