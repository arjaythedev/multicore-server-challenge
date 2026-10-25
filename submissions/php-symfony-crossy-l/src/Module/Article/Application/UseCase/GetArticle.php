<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticleResultMapper;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class GetArticle
{
    public function __construct(
        private readonly ArticleRepositoryInterface $articleRepository,
        private readonly ArticleResultMapper $articleResultMapper,
    ) {
    }

    public function __invoke(string $slug, int $viewerId): ArticleResult
    {
        $article = $this->articleRepository->findBySlug($slug, $viewerId)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->articleResultMapper->toResult($article);
    }
}
