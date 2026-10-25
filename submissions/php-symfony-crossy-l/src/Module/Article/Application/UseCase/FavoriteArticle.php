<?php

declare(strict_types=1);

namespace App\Module\Article\Application\UseCase;

use App\Module\Article\Application\Mapper\ArticleResultMapper;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Domain\Repository\ArticleRepositoryInterface;
use App\Module\Article\Domain\Repository\FavoriteRepositoryInterface;
use App\Shared\Domain\Model\Exception\NotFoundException;

class FavoriteArticle
{
    public function __construct(
        private readonly ArticleRepositoryInterface $articleRepository,
        private readonly FavoriteRepositoryInterface $favoriteRepository,
        private readonly ArticleResultMapper $articleResultMapper,
    ) {
    }

    public function __invoke(int $userId, string $slug): ArticleResult
    {
        $id = $this->articleRepository->findIdBySlug($slug)
            ?? throw NotFoundException::withMessage('article not found');

        $this->favoriteRepository->add($userId, $id);

        $article = $this->articleRepository->findById($id, $userId)
            ?? throw NotFoundException::withMessage('article not found');

        return $this->articleResultMapper->toResult($article);
    }
}
