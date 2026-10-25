<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Service;

use App\Module\Article\Application\Port\ArticleReadServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Application\UseCase\GetArticle;
use App\Module\Article\Application\UseCase\GetFeed;
use App\Module\Article\Application\UseCase\ListArticles;
use App\Module\Article\Domain\Model\ArticleFilter;

class ArticleReadService implements ArticleReadServiceInterface
{
    public function __construct(
        private readonly ListArticles $listArticles,
        private readonly GetFeed $getFeed,
        private readonly GetArticle $getArticle,
    ) {
    }

    public function listArticles(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlesResult
    {
        return ($this->listArticles)($filter, $viewerId, $limit, $offset);
    }

    public function getFeed(int $viewerId, int $limit, int $offset): ArticlesResult
    {
        return ($this->getFeed)($viewerId, $limit, $offset);
    }

    public function getArticle(string $slug, int $viewerId): ArticleResult
    {
        return ($this->getArticle)($slug, $viewerId);
    }
}
