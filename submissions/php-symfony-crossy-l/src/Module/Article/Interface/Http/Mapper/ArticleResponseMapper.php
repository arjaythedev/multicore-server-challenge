<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Interface\Http\Response\ArticleResponse;
use App\Shared\Interface\Http\Mapper\ProfileResponseMapper;

final class ArticleResponseMapper
{
    public function __construct(
        private readonly ProfileResponseMapper $profileResponseMapper,
    ) {
    }

    public function toResponse(ArticleResult $article): ArticleResponse
    {
        return new ArticleResponse(
            slug: $article->slug,
            title: $article->title,
            description: $article->description,
            body: $article->body,
            tagList: $article->tagList,
            createdAt: $article->createdAt->toIso8601(),
            updatedAt: $article->updatedAt->toIso8601(),
            favorited: $article->favorited,
            favoritesCount: $article->favoritesCount,
            author: $this->profileResponseMapper->toResponse($article->author),
        );
    }
}
