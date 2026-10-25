<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Mapper;

use App\Module\Article\Application\Result\ArticleSummaryResult;
use App\Module\Article\Application\Result\ArticleSummaryResultList;
use App\Module\Article\Domain\View\ArticleSummaryView;
use App\Module\Article\Domain\View\ArticleSummaryViewList;
use App\Shared\Application\Mapper\ProfileResultMapper;

final class ArticleSummaryResultMapper
{
    public function __construct(
        private readonly ProfileResultMapper $profileResultMapper,
    ) {
    }

    public function toResult(ArticleSummaryView $article): ArticleSummaryResult
    {
        return new ArticleSummaryResult(
            slug: $article->slug,
            title: $article->title,
            description: $article->description,
            tagList: $article->tagList,
            createdAt: $article->createdAt,
            updatedAt: $article->updatedAt,
            favorited: $article->favorited,
            favoritesCount: $article->favoritesCount,
            author: $this->profileResultMapper->toResult($article->author),
        );
    }

    public function toResultList(ArticleSummaryViewList $articles): ArticleSummaryResultList
    {
        return ArticleSummaryResultList::fromArray($articles->map($this->toResult(...)));
    }
}
