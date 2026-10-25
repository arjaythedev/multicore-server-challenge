<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Port;

use App\Module\Article\Application\Result\ArticleResult;
use App\Shared\Domain\Model\Exception\ForbiddenException;
use App\Shared\Domain\Model\Exception\NotFoundException;

/**
 * Every write returns the article as its writer now sees it, except a delete.
 */
interface ArticleWriteServiceInterface
{
    /**
     * @param list<string> $tagList
     */
    public function createArticle(int $authorId, string $title, string $description, string $body, array $tagList): ArticleResult;

    /**
     * Changes the fields that are not null and leaves the rest.
     *
     * @throws NotFoundException
     * @throws ForbiddenException when the user is not the author
     */
    public function updateArticle(int $userId, string $slug, ?string $title, ?string $description, ?string $body): ArticleResult;

    /**
     * @throws NotFoundException
     * @throws ForbiddenException when the user is not the author
     */
    public function deleteArticle(int $userId, string $slug): void;

    /**
     * @throws NotFoundException
     */
    public function favoriteArticle(int $userId, string $slug): ArticleResult;

    /**
     * @throws NotFoundException
     */
    public function unfavoriteArticle(int $userId, string $slug): ArticleResult;
}
