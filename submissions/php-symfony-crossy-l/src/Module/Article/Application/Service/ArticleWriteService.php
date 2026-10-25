<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Service;

use App\Module\Article\Application\Port\ArticleWriteServiceInterface;
use App\Module\Article\Application\Result\ArticleResult;
use App\Module\Article\Application\UseCase\CreateArticle;
use App\Module\Article\Application\UseCase\DeleteArticle;
use App\Module\Article\Application\UseCase\FavoriteArticle;
use App\Module\Article\Application\UseCase\UnfavoriteArticle;
use App\Module\Article\Application\UseCase\UpdateArticle;

class ArticleWriteService implements ArticleWriteServiceInterface
{
    public function __construct(
        private readonly CreateArticle $createArticle,
        private readonly UpdateArticle $updateArticle,
        private readonly DeleteArticle $deleteArticle,
        private readonly FavoriteArticle $favoriteArticle,
        private readonly UnfavoriteArticle $unfavoriteArticle,
    ) {
    }

    public function createArticle(int $authorId, string $title, string $description, string $body, array $tagList): ArticleResult
    {
        return ($this->createArticle)($authorId, $title, $description, $body, $tagList);
    }

    public function updateArticle(int $userId, string $slug, ?string $title, ?string $description, ?string $body): ArticleResult
    {
        return ($this->updateArticle)($userId, $slug, $title, $description, $body);
    }

    public function deleteArticle(int $userId, string $slug): void
    {
        ($this->deleteArticle)($userId, $slug);
    }

    public function favoriteArticle(int $userId, string $slug): ArticleResult
    {
        return ($this->favoriteArticle)($userId, $slug);
    }

    public function unfavoriteArticle(int $userId, string $slug): ArticleResult
    {
        return ($this->unfavoriteArticle)($userId, $slug);
    }
}
