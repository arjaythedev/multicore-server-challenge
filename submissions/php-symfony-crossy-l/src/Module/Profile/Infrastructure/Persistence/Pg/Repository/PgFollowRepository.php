<?php

declare(strict_types=1);

namespace App\Module\Profile\Infrastructure\Persistence\Pg\Repository;

use App\Module\Profile\Domain\Repository\FollowRepositoryInterface;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

final class PgFollowRepository implements FollowRepositoryInterface
{
    private const string INSERT = 'INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING';

    private const string DELETE = 'DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2';

    public function __construct(
        private readonly PgConnection $connection,
    ) {
    }

    public function add(int $followerId, int $followeeId): void
    {
        $this->connection->write(self::INSERT, [$followerId, $followeeId]);
    }

    public function remove(int $followerId, int $followeeId): void
    {
        $this->connection->write(self::DELETE, [$followerId, $followeeId]);
    }
}
