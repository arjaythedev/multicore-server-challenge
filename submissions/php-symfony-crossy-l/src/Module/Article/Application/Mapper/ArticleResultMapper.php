<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Mapper;

use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Domain\View\ArticleView;
use App\Shared\Application\Mapper\ProfileResultMapper;

final class ArticleResultMapper
{
    public function __construct(
        private readonly ProfileResultMapper $profileResultMapper,
    ) {
    }

    public function toResult(ArticleView $article): ArticleResult
    {
        return new ArticleResult(
            slug: $article->slug,
            title: $article->title,
            description: $article->description,
            body: $article->body,
            tagList: $article->tagList,
            createdAt: $article->createdAt,
            updatedAt: $article->updatedAt,
            favorited: $article->favorited,
            favoritesCount: $article->favoritesCount,
            author: $this->profileResultMapper->toResult($article->author),
        );
    }
}
