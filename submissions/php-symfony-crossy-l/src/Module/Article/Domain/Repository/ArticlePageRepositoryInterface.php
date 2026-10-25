<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Repository;

use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Domain\View\ArticlePageView;

/**
 * Pages of articles, newest first, each with how many articles the list holds, counted up to 1,000.
 *
 * Viewer 0, the anonymous one, has favorited nothing and follows nobody. A tag or username that does
 * not exist names an empty list.
 */
interface ArticlePageRepositoryInterface
{
    public function findPage(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlePageView;

    /**
     * Articles by the authors the viewer follows.
     */
    public function findFeedPage(int $viewerId, int $limit, int $offset): ArticlePageView;
}
