<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Repository;

interface FavoriteRepositoryInterface
{
    /**
     * Favoriting an article already favorited changes nothing.
     */
    public function add(int $userId, int $articleId): void;

    /**
     * Unfavoriting an article not favorited changes nothing.
     */
    public function remove(int $userId, int $articleId): void;
}
