<?php

declare(strict_types=1);

namespace App\Module\User\Infrastructure\Persistence\Pg\Mapper;

use App\Module\User\Domain\Model\User;

final class UserMapper
{
    /**
     * @param array<array-key, string|null> $row
     */
    public function toDomain(array $row): User
    {
        return new User(
            id: (int) $row['id'],
            username: (string) $row['username'],
            email: (string) $row['email'],
            bio: $row['bio'],
            image: $row['image'],
        );
    }
}
