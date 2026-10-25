<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Query\GetArticle;

use App\Module\Article\Application\Port\ArticleReadServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Application\Policy\NoAuthRequired;

#[NoAuthRequired(reason: 'Articles are public; a signed-in viewer also sees whether they favorited it and follow its author.')]
final class GetArticleQueryHandler
{
    public function __construct(
        private readonly ArticleReadServiceInterface $readService,
    ) {
    }

    public function handle(GetArticleQuery $query): ArticleResult
    {
        return $this->readService->getArticle($query->slug, $query->caller->getViewerId());
    }
}
