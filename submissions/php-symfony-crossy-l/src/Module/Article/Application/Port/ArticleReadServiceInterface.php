<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Port;

use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Domain\Model\ArticleFilter;
use App\Shared\Domain\Model\Exception\NotFoundException;

/**
 * Viewer 0, the anonymous one, has favorited nothing and follows nobody.
 */
interface ArticleReadServiceInterface
{
    public function listArticles(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlesResult;

    /**
     * Articles by the authors the viewer follows.
     */
    public function getFeed(int $viewerId, int $limit, int $offset): ArticlesResult;

    /**
     * @throws NotFoundException
     */
    public function getArticle(string $slug, int $viewerId): ArticleResult;
}
