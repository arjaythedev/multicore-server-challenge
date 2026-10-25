<?php

declare(strict_types=1);

namespace App\Module\Article\Infrastructure\Persistence\Pg\Repository;

use App\Module\Article\Domain\Repository\FavoriteRepositoryInterface;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

final class PgFavoriteRepository implements FavoriteRepositoryInterface
{
    private const string INSERT = 'INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING';

    private const string DELETE = 'DELETE FROM favorites WHERE user_id = $1 AND article_id = $2';

    public function __construct(
        private readonly PgConnection $connection,
    ) {
    }

    public function add(int $userId, int $articleId): void
    {
        $this->connection->write(self::INSERT, [$userId, $articleId]);
    }

    public function remove(int $userId, int $articleId): void
    {
        $this->connection->write(self::DELETE, [$userId, $articleId]);
    }
}
