<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Persistence\Pg\Repository;

use App\Module\User\Domain\Model\Exception\UsernameOrEmailTakenException;
use App\Module\User\Domain\Model\NewUser;
use App\Module\User\Domain\Model\User;
use App\Module\User\Domain\Model\UserChanges;
use App\Module\User\Domain\Model\UserCredentials;
use App\Module\User\Domain\Repository\UserRepositoryInterface;
use App\Module\User\Infrastructure\Persistence\Pg\Mapper\UserCredentialsMapper;
use App\Module\User\Infrastructure\Persistence\Pg\Mapper\UserMapper;
use App\Shared\Infrastructure\Persistence\Pg\PgConnection;
use App\Shared\Infrastructure\Persistence\Pg\PgQueryFailedException;
use PgSql\Result;
use UnexpectedValueException;

final class PgUserRepository implements UserRepositoryInterface
{
    private const string INSERT = <<<'SQL'
        INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
        RETURNING id, username, email, bio, image
        SQL;

    private const string BY_ID = 'SELECT id, username, email, bio, image FROM users WHERE id = $1';

    private const string CREDENTIALS_BY_EMAIL = 'SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1';

    private const string UPDATE = <<<'SQL'
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                         password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
         WHERE id = $1
        RETURNING id, username, email, bio, image
        SQL;

    public function __construct(
        private readonly PgConnection $connection,
        private readonly UserMapper $userMapper,
        private readonly UserCredentialsMapper $credentialsMapper,
    ) {
    }

    public function add(NewUser $user): User
    {
        $row = pg_fetch_assoc($this->writeUnique(self::INSERT, [$user->username, $user->email, $user->passwordHash]));

        if ($row === false) {
            throw new UnexpectedValueException('The insert returned no row.');
        }

        return $this->userMapper->toDomain($row);
    }

    public function findById(int $id): ?User
    {
        $row = pg_fetch_assoc($this->connection->read(self::BY_ID, [$id]));

        return $row === false ? null : $this->userMapper->toDomain($row);
    }

    public function findCredentialsByEmail(string $email): ?UserCredentials
    {
        $row = pg_fetch_assoc($this->connection->read(self::CREDENTIALS_BY_EMAIL, [$email]));

        return $row === false ? null : $this->credentialsMapper->toDomain($row);
    }

    public function update(int $id, UserChanges $changes): ?User
    {
        $row = pg_fetch_assoc($this->writeUnique(self::UPDATE, [
            $id,
            $changes->email,
            $changes->username,
            $changes->passwordHash,
            $changes->bio,
            $changes->image,
        ]));

        return $row === false ? null : $this->userMapper->toDomain($row);
    }

    /**
     * A write that a unique index on the username or the email can refuse.
     *
     * @param list<int|string|null> $params
     */
    private function writeUnique(string $sql, array $params): Result
    {
        try {
            return $this->connection->write($sql, $params);
        } catch (PgQueryFailedException $failure) {
            throw $failure->isUniqueViolation() ? UsernameOrEmailTakenException::create() : $failure;
        }
    }
}
