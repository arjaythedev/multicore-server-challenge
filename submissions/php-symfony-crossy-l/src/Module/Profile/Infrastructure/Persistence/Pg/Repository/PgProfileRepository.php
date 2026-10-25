<?php

declare(strict_types=1);

namespace App\Module\Profile\Infrastructure\Persistence\Pg\Repository;

use App\Module\Profile\Domain\Model\ProfileUser;
use App\Module\Profile\Domain\Repository\ProfileRepositoryInterface;
use App\Module\Profile\Infrastructure\Persistence\Pg\Mapper\ProfileUserMapper;
use App\Shared\Domain\View\ProfileView;
use App\Shared\Infrastructure\Persistence\Pg\Batch\BatchedRead;
use App\Shared\Infrastructure\Persistence\Pg\Mapper\ProfileViewMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;

final class PgProfileRepository implements ProfileRepositoryInterface
{
    private const string FOR_VIEWER = <<<'SQL'
        SELECT u.id, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = $2
        SQL;

    private const string USER_BY_USERNAME = 'SELECT id, username, bio, image FROM users WHERE username = $1';

    private readonly BatchedRead $forViewer;

    public function __construct(
        private readonly PgConnection $connection,
        private readonly ProfileViewMapper $profileViewMapper,
        private readonly ProfileUserMapper $userMapper,
    ) {
        $this->forViewer = new BatchedRead(self::FOR_VIEWER, ['bigint', 'text']);
    }

    public function findByUsername(string $username, int $viewerId): ?ProfileView
    {
        $rows = $this->connection->readBatched($this->forViewer, [$viewerId, $username]);

        return $rows === [] ? null : $this->profileViewMapper->toView($rows[0]);
    }

    public function findUserByUsername(string $username): ?ProfileUser
    {
        $row = pg_fetch_assoc($this->connection->read(self::USER_BY_USERNAME, [$username]));

        return $row === false ? null : $this->userMapper->toDomain($row);
    }
}
