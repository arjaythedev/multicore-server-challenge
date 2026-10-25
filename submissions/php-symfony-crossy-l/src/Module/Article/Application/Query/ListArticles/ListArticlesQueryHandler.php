<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\ListArticles;

use App\Module\Article\Application\Port\ArticleReadServiceInterface;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Shared\Application\Policy\NoAuthRequired;

#[NoAuthRequired(reason: 'Article lists are public; a signed-in viewer also sees what they favorited and follow.')]
final class ListArticlesQueryHandler
{
    public function __construct(
        private readonly ArticleReadServiceInterface $readService,
    ) {
    }

    public function handle(ListArticlesQuery $query): ArticlesResult
    {
        return $this->readService->listArticles($query->filter, $query->caller->getViewerId(), $query->limit, $query->offset);
    }
}
