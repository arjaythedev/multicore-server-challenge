<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticlesResultMapper;
use App\Module\Article\Application\Result\ArticlesResult;
use App\Module\Article\Domain\Repository\ArticlePageRepositoryInterface;

class GetFeed
{
    public function __construct(
        private readonly ArticlePageRepositoryInterface $articlePageRepository,
        private readonly ArticlesResultMapper $articlesResultMapper,
    ) {
    }

    public function __invoke(int $viewerId, int $limit, int $offset): ArticlesResult
    {
        return $this->articlesResultMapper->toResult($this->articlePageRepository->findFeedPage($viewerId, $limit, $offset));
    }
}
