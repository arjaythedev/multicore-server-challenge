<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticlesResultMapper;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Domain\Model\ArticleFilter;
use App\Module\Article\Domain\Repository\ArticlePageRepositoryInterface;

class ListArticles
{
    public function __construct(
        private readonly ArticlePageRepositoryInterface $articlePageRepository,
        private readonly ArticlesResultMapper $articlesResultMapper,
    ) {
    }

    public function __invoke(ArticleFilter $filter, int $viewerId, int $limit, int $offset): ArticlesResult
    {
        return $this->articlesResultMapper->toResult(
            $this->articlePageRepository->findPage($filter, $viewerId, $limit, $offset),
        );
    }
}
