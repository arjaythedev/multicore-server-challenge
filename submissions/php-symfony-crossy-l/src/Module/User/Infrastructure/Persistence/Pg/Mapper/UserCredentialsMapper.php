<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Persistence\Pg\Mapper;

use App\Module\User\Domain\Model\UserCredentials;

final class UserCredentialsMapper
{
    public function __construct(
        private readonly UserMapper $userMapper,
    ) {
    }

    /**
     * @param array<array-key, string|null> $row a user's columns and password_hash
     */
    public function toDomain(array $row): UserCredentials
    {
        return new UserCredentials(user: $this->userMapper->toDomain($row), passwordHash: (string) $row['password_hash']);
    }
}
